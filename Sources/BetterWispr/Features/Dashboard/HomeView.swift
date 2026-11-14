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
                    SectionHeader(title: L10n.tr("Usage")) {
                        if !model.history.isEmpty { PageLink(title: L10n.tr("Insights")) { model.selectedPage = .insights } }
                    }
                    UsageStats(history: model.history)
                    if !model.settings.saveHistory && !model.history.isEmpty {
                        Text(L10n.tr("History is off, so new dictations are not counted."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: L10n.tr("Recent")) {
                        if !model.history.isEmpty { PageLink(title: L10n.tr("View all %@", String(model.history.count.formatted()))) { model.selectedPage = .history } }
                    }
                    recent
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(L10n.tr("Setup"))
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
            SectionHeader(title: L10n.tr("Latest dictation")) {
                Button(L10n.tr("Copy"), systemImage: "doc.on.doc", action: model.copyLatestTranscript)
                    .buttonStyle(.borderless)
            }
            Card {
                Text(model.partialTranscript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.tr("History is off. Copy these words before starting another dictation."))
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
                    Text(model.settings.saveHistory ? L10n.tr("Nothing here yet") : L10n.tr("History is off"))
                        .font(.headline)
                    if model.settings.saveHistory {
                        ShortcutSentence(
                            format: model.settings.dictationMode != .toggle
                                ? L10n.tr("Hold %@ in any app and your words will show up here.")
                                : L10n.tr("Press %@ in any app and your words will show up here."),
                            shortcut: model.settings.shortcut)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("Turn on Save dictation history to find and reuse what you said."))
                            .foregroundStyle(.secondary)
                        PageLink(title: L10n.tr("Open Settings")) { model.selectedPage = .settings }
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
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.cardFill)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(recording ? Color.red.opacity(0.35) : .cardStroke))
        .animation(.ui, value: model.phase)
        .animation(.ui, value: model.microphoneGranted)
    }

    private var headline: String {
        switch model.phase {
        case .recording: L10n.tr("Listening…")
        case .preparing: L10n.tr("Getting ready…")
        case .transcribing: L10n.tr("Transcribing…")
        case .idle, .failed, .unpasted, .translationFailed, .cancelled, .completed, .sending, .asking: greeting
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: L10n.tr("Good morning")
        case 12..<17: L10n.tr("Good afternoon")
        default: L10n.tr("Good evening")
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
                Text(L10n.tr("Your words will appear where you were typing."))
                    .foregroundStyle(.secondary)
            }
        } else if !model.microphoneGranted {
            Text(L10n.tr("BetterWispr needs your microphone to hear you."))
                .foregroundStyle(.secondary)
        } else if modelMissing {
            Text(L10n.tr("Download %@ once, then dictate offline.", String(model.selectedModel.localizedName)))
                .foregroundStyle(.secondary)
        } else {
            ShortcutSentence(
                format: model.settings.dictationMode != .toggle
                    ? L10n.tr("Hold %@ in any app and start talking.")
                    : L10n.tr("Press %@ in any app and start talking."),
                shortcut: model.settings.shortcut, spacing: 5)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                Button(L10n.tr("Cancel"), action: model.cancelRecording)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if recording {
                ProminentButton(title: L10n.tr("Finish"), symbol: "stop.fill", tint: .red, action: model.toggleRecording)
            } else if working {
                ProgressView().controlSize(.small).padding(.horizontal, 12)
            } else if !model.microphoneGranted {
                ProminentButton(title: L10n.tr("Allow Microphone"), symbol: "mic.fill", tint: .accentColor, action: model.requestMicrophone)
            } else if modelMissing {
                ProminentButton(title: L10n.tr("Get Model"), symbol: "arrow.down.circle.fill", tint: .accentColor) { model.selectedPage = .models }
            } else {
                ProminentButton(title: L10n.tr("Start dictating"), symbol: "mic.fill", tint: .accentColor, action: model.toggleRecording)
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
            StatTile(label: L10n.tr("Words dictated"), value: insights.current.words.formatted(), unit: nil),
            StatTile(label: L10n.tr("Speaking time"), value: speakingTime, unit: nil),
            StatTile(label: L10n.tr("Average pace"), value: insights.current.wordsPerMinute.formatted(), unit: L10n.tr("wpm")),
            StatTile(label: L10n.tr("Current streak"), value: insights.currentStreak.formatted(), unit: L10n.tr("Streak day unit", insights.currentStreak)),
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
            .help(L10n.tr("Copy dictation"))
            .accessibilityLabel(L10n.tr("Copy dictation"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.045) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.ui, value: hovering)
        .animation(.ui, value: copied)
        .contextMenu {
            Button(L10n.tr("Copy"), action: onCopy)
            Button(L10n.tr("Show in History"), action: onOpen)
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
    @State private var subscriptionSignedIn = false

    var body: some View {
        let speech = model.selectedModel
        let installed = model.isModelInstalled(speech)
        let signInMissing = speech.engine == .codex && !subscriptionSignedIn
        let onOlderParakeet = ["parakeet-v3", "parakeet-v2"].contains(speech.id)
        let speechDetail = if speech.processingLocation.isOnDevice {
            installed ? (onOlderParakeet ? L10n.tr("Try Parakeet Ultra") : L10n.tr("Runs on this Mac")) : L10n.tr("Not downloaded yet")
        } else {
            signInMissing ? L10n.tr("Sign in with codex login in Terminal") : speech.connection.map { L10n.tr("Sends audio to %@", String($0.endpoint)) } ?? speech.processingLocation.disclosure
        }
        let tiles = [
            SetupTile(
                symbol: speech.processingLocation.isOnDevice ? "cpu" : "network", title: L10n.tr("Speech model"), value: speech.localizedName,
                detail: speechDetail,
                ready: installed && !signInMissing
            ) { model.selectedPage = .models },
            SetupTile(
                symbol: "mic", title: L10n.tr("Microphone"), value: microphoneName,
                detail: model.microphoneGranted ? (model.settings.microphone == nil ? L10n.tr("Follows Sound settings") : L10n.tr("Chosen in Settings")) : L10n.tr("Access needed"),
                ready: model.microphoneGranted
            ) { model.microphoneGranted ? (model.selectedPage = .settings) : model.requestMicrophone() },
            SetupTile(
                symbol: "doc.on.clipboard", title: L10n.tr("Delivery"),
                value: model.settings.autoPaste && model.accessibilityGranted ? L10n.tr("Pastes into apps") : L10n.tr("Copies to clipboard"),
                detail: model.accessibilityGranted ? L10n.tr("Accessibility allowed") : L10n.tr("Allow Accessibility to paste"),
                ready: model.accessibilityGranted
            ) { model.accessibilityGranted ? (model.selectedPage = .settings) : model.requestAccessibility() },
        ]
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(tiles, id: \.title) { $0.frame(minWidth: 168, idealWidth: 168) } }
            VStack(spacing: 12) { ForEach(tiles, id: \.title) { $0 } }
        }
        .task(id: speech.id) { subscriptionSignedIn = CodexSpeechProvider.isSignedIn }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            subscriptionSignedIn = CodexSpeechProvider.isSignedIn
        }
    }

    private var microphoneName: String {
        if let chosen = model.settings.microphone { return chosen.name }
        return model.automaticMicrophone?.name ?? L10n.tr("Automatic")
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
        .accessibilityHint(ready ? L10n.tr("Opens settings") : L10n.tr("Fixes this setup step"))
    }
}
