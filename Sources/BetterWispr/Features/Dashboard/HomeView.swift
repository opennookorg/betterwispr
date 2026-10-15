import AppKit
import BetterWisprCore
import SwiftUI

struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                DictationPanel(model: model)

                if !model.partialTranscript.isEmpty && !model.isBusy && !model.settings.saveHistory {
                    latestDictation.transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Usage") {
                        if !model.history.isEmpty { PageLink(title: "Insights") { model.selectedPage = .insights } }
                    }
                    UsageStats(history: model.history)
                    if !model.settings.saveHistory && !model.history.isEmpty {
                        Text("History is off, so new dictations are not counted.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Recent") {
                        if !model.history.isEmpty { PageLink(title: "View all \(model.history.count.formatted())") { model.selectedPage = .history } }
                    }
                    recent
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Setup")
                    SetupTiles(model: model)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .animation(.ui, value: model.history.first?.id)
            .animation(.ui, value: model.isBusy)
        }
    }

    private var latestDictation: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Latest dictation") {
                Button("Copy", systemImage: "doc.on.doc", action: model.copyLatestTranscript)
                    .buttonStyle(.borderless)
            }
            Card {
                Text(model.partialTranscript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("History is off. Copy these words before starting another dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var recent: some View {
        if model.history.isEmpty {
            Card(padding: 24) {
                VStack(spacing: 8) {
                    Image(systemName: model.settings.saveHistory ? "waveform" : "clock.badge.xmark")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(model.settings.saveHistory ? "Nothing here yet" : "History is off")
                        .font(.headline)
                    if model.settings.saveHistory {
                        HStack(spacing: 4) {
                            Text(model.settings.dictationMode == .hold ? "Hold" : "Press")
                            KeyCap(shortcut: model.settings.shortcut)
                            Text("in any app and your words will show up here.")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Turn on Save dictation history to find and reuse what you said.")
                            .foregroundStyle(.secondary)
                        PageLink(title: "Open Settings") { model.selectedPage = .settings }
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
        } else {
            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(Array(model.history.prefix(5).enumerated()), id: \.element.id) { index, transcript in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        RecentRow(transcript: transcript, onCopy: { model.copyTranscript(transcript) }) {
                            model.selectedPage = .history
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }
}

private struct DictationPanel: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { model.phase == .recording }
    private var working: Bool { model.phase == .preparing || model.phase == .transcribing }
    private var modelMissing: Bool { !model.isModelInstalled(model.selectedModel) }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(headline)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .contentTransition(.opacity)
                detail
                    .transition(.opacity)
                    .id(detailID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(24)
        .frame(minHeight: 120)
        .background {
            ZStack {
                Rectangle().fill(.cardFill)
                RadialGradient(
                    colors: [(recording ? Color.red : .accentColor).opacity(recording ? 0.22 : 0.12), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 420
                )
            }
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(recording ? Color.red.opacity(0.35) : .cardStroke))
        .animation(.ui, value: model.phase)
        .animation(.ui, value: model.microphoneGranted)
    }

    private var headline: String {
        switch model.phase {
        case .recording: "Listening…"
        case .preparing: "Getting ready…"
        case .transcribing: "Transcribing…"
        case .idle, .failed, .unpasted, .cancelled, .completed: greeting
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var detailID: String {
        if recording { return "recording" }
        if working { return "working" }
        if !model.microphoneGranted { return "microphone" }
        return modelMissing ? "model" : "idle"
    }

    @ViewBuilder private var detail: some View {
        if recording {
            HStack(spacing: 12) {
                Waveform(mode: .listening(model.voiceLevels), animated: !reduceMotion, color: .red, count: 24)
                    .scaleEffect(y: 1.6)
                    .accessibilityHidden(true)
                Text(durationLabel(model.recordingDuration))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        } else if working {
            HStack(spacing: 12) {
                Waveform(mode: .processing, animated: !reduceMotion, color: .secondary, count: 24)
                    .accessibilityHidden(true)
                Text("Your words will appear where you were typing.")
                    .foregroundStyle(.secondary)
            }
        } else if !model.microphoneGranted {
            Text("BetterWispr needs your microphone to hear you.")
                .foregroundStyle(.secondary)
        } else if modelMissing {
            Text("Download \(model.selectedModel.name) once, then dictate offline.")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 5) {
                Text(model.settings.dictationMode == .hold ? "Hold" : "Press")
                KeyCap(shortcut: model.settings.shortcut)
                Text("in any app and start talking.")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                Button("Cancel", action: model.cancelRecording)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if recording {
                ProminentButton(title: "Finish", symbol: "stop.fill", tint: .red, action: model.toggleRecording)
            } else if working {
                ProgressView().controlSize(.small).padding(.horizontal, 12)
            } else if !model.microphoneGranted {
                ProminentButton(title: "Allow Microphone", symbol: "mic.fill", tint: .accentColor, action: model.requestMicrophone)
            } else if modelMissing {
                ProminentButton(title: "Get Model", symbol: "arrow.down.circle.fill", tint: .accentColor) { model.selectedPage = .models }
            } else {
                ProminentButton(title: "Start dictating", symbol: "mic.fill", tint: .accentColor, action: model.toggleRecording)
            }
        }
        .fixedSize()
    }
}

private struct ProminentButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(tint.gradient, in: .capsule)
                .brightness(hovering ? 0.06 : 0)
                .shadow(color: tint.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 10 : 6, y: 2)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
    }
}

private struct UsageStats: View {
    let history: [Transcript]

    var body: some View {
        let insights = UsageInsights(history)
        let tiles = [
            StatTile(label: "Words dictated", value: insights.current.words.formatted(), unit: nil),
            StatTile(label: "Speaking time", value: speakingTime, unit: nil),
            StatTile(label: "Average pace", value: insights.current.wordsPerMinute.formatted(), unit: "wpm"),
            StatTile(label: "Current streak", value: insights.currentStreak.formatted(), unit: insights.currentStreak == 1 ? "day" : "days"),
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(tiles, id: \.label) { $0.frame(minWidth: 128, idealWidth: 128) } }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
    }

    private var speakingTime: String {
        let seconds = history.reduce(0) { $0 + $1.duration }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let unit: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.3)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RecentRow: View {
    let transcript: Transcript
    let onCopy: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var copied = false
    @State private var app: (name: String, icon: NSImage)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let app {
                    Image(nsImage: app.icon).resizable()
                } else {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 5, style: .continuous))
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    if let app { Text(app.name); Text("·") }
                    Text(transcript.createdAt, format: .relative(presentation: .named))
                    Text("·")
                    Text(durationLabel(transcript.duration)).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Button {
                onCopy()
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? Color.green : .secondary)
            .opacity(hovering || copied ? 1 : 0)
            .help("Copy dictation")
            .accessibilityLabel("Copy dictation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.045) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
        .animation(.ui, value: copied)
        .contextMenu {
            Button("Copy", action: onCopy)
            Button("Show in History", action: onOpen)
        }
        .task(id: transcript.appBundleID) {
            guard let id = transcript.appBundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            app = (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                   NSWorkspace.shared.icon(forFile: url.path))
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct SetupTiles: View {
    let model: AppModel

    var body: some View {
        let speech = model.selectedModel
        let installed = model.isModelInstalled(speech)
        let onOlderParakeet = ["parakeet-v3", "parakeet-v2"].contains(speech.id)
        let tiles = [
            SetupTile(
                symbol: "cpu", title: "Speech model", value: speech.name,
                detail: speech.connection.map { "Sends audio to \($0.endpoint)" } ?? (installed ? (onOlderParakeet ? "Try Parakeet Ultra" : "Runs on this Mac") : "Not downloaded yet"),
                ready: installed
            ) { model.selectedPage = .models },
            SetupTile(
                symbol: "mic", title: "Microphone", value: microphoneName,
                detail: model.microphoneGranted ? (model.settings.microphone == nil ? "Follows Sound settings" : "Chosen in Settings") : "Access needed",
                ready: model.microphoneGranted
            ) { model.microphoneGranted ? (model.selectedPage = .settings) : model.requestMicrophone() },
            SetupTile(
                symbol: "doc.on.clipboard", title: "Delivery",
                value: model.settings.autoPaste && model.accessibilityGranted ? "Pastes into apps" : "Copies to clipboard",
                detail: model.accessibilityGranted ? "Accessibility allowed" : "Allow Accessibility to paste",
                ready: model.accessibilityGranted
            ) { model.accessibilityGranted ? (model.selectedPage = .settings) : model.requestAccessibility() },
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(tiles, id: \.title) { $0.frame(minWidth: 168, idealWidth: 168) } }
            VStack(spacing: 12) { ForEach(tiles, id: \.title) { $0 } }
        }
    }

    private var microphoneName: String {
        if let chosen = model.settings.microphone { return chosen.name }
        return model.automaticMicrophone?.name ?? "Automatic"
    }
}

private struct SetupTile: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let ready: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).frame(width: 16, height: 16)
                    Text(title)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .opacity(hovering ? 1 : 0)
                        .offset(x: hovering ? 0 : -4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(ready ? Color.green : .orange)
                        .frame(width: 6, height: 6)
                    Text(detail)
                        .foregroundStyle(ready ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(.cardFill), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cardStroke))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint(ready ? "Opens settings" : "Fixes this setup step")
    }
}
