import BetterWisprCore
import SwiftUI

struct CapsuleView: View {
    @Bindable var model: AppModel
    let hover: CapsuleHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool { model.phase == .recording }
    private var isMeetingCapturing: Bool { model.meetings.capturingID != nil }
    private var isNotetaking: Bool { !model.isBusy && isMeetingCapturing }
    private var isMeetingRecording: Bool { model.meetings.capturing?.phase == .recording }
    private var failure: DictationFailure? {
        model.failure ?? (model.phase != .idle ? nil : model.meetings.message.map {
            DictationFailure(title: "Notetaker needs attention", message: $0)
        })
    }
    private var meetingPrompt: DetectedMeeting? {
        model.isBusy || isMeetingCapturing ? nil : model.meetingDetector.meeting
    }
    private var showsCard: Bool {
        switch model.phase {
        case .cancelled, .completed, .unpasted, .failed: true
        default: failure != nil || meetingPrompt != nil
        }
    }
    private var surfaceRadius: CGFloat {
        if model.phase != .idle { 24 } else if failure == nil, meetingPrompt != nil { 26 } else if showsCard { 22 } else { 18 }
    }
    private var showsToolbar: Bool { !showsCard && !model.isBusy && !isMeetingCapturing && hover.isHovering }
    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.26, bounce: 0) }
    private var swap: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)) }

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if !showsCard, let target = hover.target {
                tooltip(for: target)
            }
            RecordingLimitLabel(model: model)
            if model.isBusy, !model.liveTranscript.isEmpty {
                livePreview
            }
            surface
        }
        .padding(.bottom, 16)
        .frame(width: 440, height: 240)
        .coordinateSpace(name: "capsule")
        .onPreferenceChange(CapsuleRegions.self) { hover.update(regions: $0) }
        .environment(\.colorScheme, .dark)
        .animation(spring, value: model.phase)
        .animation(spring, value: model.isHeldSession)
        .animation(spring, value: model.meetings.capturing?.phase)
        .animation(spring, value: model.liveTranscript.isEmpty)
        .animation(spring, value: failure)
        .animation(spring, value: meetingPrompt)
        .animation(spring, value: hover.isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.target)
        .onChange(of: failure) {
            guard let failure else { return }
            AccessibilityNotification.Announcement("\(failure.title) \(failure.message)").post()
        }
        .onChange(of: meetingPrompt) {
            guard let meetingPrompt else { return }
            AccessibilityNotification.Announcement("\(meetingPrompt.platform.name) meeting detected. You can start the notetaker from the capsule.").post()
        }
        .onChange(of: model.unpasted) {
            guard model.unpasted != nil else { return }
            AccessibilityNotification.Announcement("Copied, not pasted. Press Command V to paste it.").post()
        }
        .onChange(of: model.phase) {
            switch model.phase {
            case .cancelled:
                AccessibilityNotification.Announcement(model.canUndoCancellation ? "Transcript cancelled. Undo is available for five seconds." : "Transcript cancelled.").post()
            case .completed(let message): AccessibilityNotification.Announcement(message).post()
            default: break
            }
        }
    }

    private var surface: some View {
        VStack(spacing: 0) {
            if let failure {
                failureCard(failure)
                    .transition(swap)
            } else if let text = model.unpasted {
                unpastedCard(text)
                    .transition(swap)
            } else if model.phase == .cancelled {
                cancellationCard
                    .transition(swap)
            } else if case .completed(let message) = model.phase {
                completionCard(message)
                    .transition(swap)
            } else if let meetingPrompt {
                meetingCard(meetingPrompt)
                    .transition(swap)
            } else if isNotetaking {
                notetakingPill
                    .transition(swap)
            } else if model.isBusy {
                dictationPill
                    .transition(swap)
            } else if showsToolbar {
                controls
                    .transition(swap)
            } else {
                Color.clear.frame(width: 36, height: 6)
            }
        }
        .background {
            if !showsToolbar {
                CapsuleGlass(cornerRadius: surfaceRadius)
            }
        }
        .overlay(alignment: .bottom) {
            if showsCard, let deadline = model.cardDeadline {
                CapsuleCountdown(deadline: deadline, duration: model.cardDuration)
                    .padding(.horizontal, 22)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isNotetaking && isMeetingRecording && !showsCard {
                Capsule().strokeBorder(Color(red: 0, green: 0.73, blue: 0.51), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .capsuleRegion(.surface)
        .accessibilityElement(children: .contain)
    }

    private func tooltip(for target: CapsuleHover.Target) -> some View {
        HStack(spacing: 4) {
            Text(tooltipTitle(for: target))
            if target == .microphone {
                Text(model.settings.shortcut.displayName).fontWeight(.semibold)
            }
            if target == .dictation {
                Text("Esc to cancel").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { CapsuleGlass(cornerRadius: 14) }
        .allowsHitTesting(false)
        .transition(swap)
        .accessibilityElement(children: .combine)
    }

    private func tooltipTitle(for target: CapsuleHover.Target) -> String {
        switch target {
        case .microphone: "Dictate"
        case .notetaker:
            isMeetingCapturing ? "Stop notetaker" : "Start notetaker"
        case .meetingNotes: "Open meeting notes"
        case .dictation:
            switch model.phase {
            case .recording: model.isHeldSession ? "Release \(model.settings.shortcut.displayName) to finish" : "Finish dictation"
            case .transcribing: "Transcribing…"
            default: "Starting microphone…"
            }
        case .surface: ""
        }
    }

    private func failureCard(_ failure: DictationFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: model.failure == nil ? "exclamationmark.triangle" : failure.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text(failure.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: dismissFailure) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss error")
                .accessibilityLabel("Dismiss error")
            }
            Text(failure.message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(model.failure == nil ? nil : 4)
            if failure.needsAccessibility {
                Button("Allow Accessibility") {
                    model.requestAccessibility()
                    model.dismissCard()
                }
                .buttonStyle(.bordered)
            } else if model.failure != nil {
                Button("Try again", action: model.toggleRecording)
                    .buttonStyle(.bordered)
            }
            if isMeetingCapturing {
                Button("Stop notetaker", action: model.meetings.stop)
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }

    private func unpastedCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text("Copied, not pasted.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Button {
                    model.copyText(text)
                    model.dismissCard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Copy text")
                .accessibilityLabel("Copy text")
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
    }

    private var cancellationCard: some View {
        HStack(spacing: 16) {
            Text("Transcript cancelled")
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
            if model.canUndoCancellation {
                Button("Undo", action: model.undoCancellation)
                    .help("Transcribe the audio you just cancelled")
            } else {
                Button("Dismiss", action: model.dismissCard)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(CapsuleCardButtonStyle())
        .padding(.horizontal, 18)
        .frame(width: 320, height: 56)
    }

    private func completionCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.55, green: 0.9, blue: 0.7))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
        .frame(height: 48)
    }

    private func meetingCard(_ meeting: DetectedMeeting) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.28))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting detected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.84, blue: 0.47))
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(meeting.platform.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                Button {
                    model.meetingDetector.dismiss()
                    model.startNotetaker()
                } label: {
                    Text("Start notetaker")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 12)
                        .padding(.trailing, 9)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                }
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 14)
                Menu {
                    Button("Not now", action: model.meetingDetector.dismiss)
                    Button("Turn off meeting detection") {
                        model.settings.detectMeetings = false
                        model.saveSettings()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
                .accessibilityLabel("More options")
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
            Button(action: model.meetingDetector.dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.06), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss meeting prompt")
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(width: 384, height: 52)
    }

    private func dismissFailure() {
        if model.failure != nil { model.dismissCard() }
        else { model.meetings.message = nil }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            Button(action: model.toggleRecording) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 28)
                    .background(.white.opacity(hover.target == .microphone ? 0.1 : 0), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start dictation")
            .background { CapsuleGlass(cornerRadius: 14) }
            .capsuleRegion(.microphone)
            meetingButton
        }
    }

    /// Confirmed words stay bright and the provisional tail is dimmed; only the newest two lines show.
    private var livePreview: some View {
        let live = model.liveTranscript
        let separator = live.confirmed.isEmpty || live.hypothesis.isEmpty ? "" : " "
        return (Text(live.confirmed).foregroundStyle(.white.opacity(0.92))
            + Text(separator)
            + Text(live.hypothesis).foregroundStyle(.white.opacity(0.5)))
            .font(.system(size: 13))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background { CapsuleGlass(cornerRadius: 14) }
            .allowsHitTesting(false)
            .transition(swap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live preview")
            .accessibilityValue(live.confirmed + separator + live.hypothesis)
    }

    private var dictationPill: some View {
        HStack(spacing: 4) {
            if !model.isHeldSession {
                Button(action: model.cancelRecording) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.2), in: Circle())
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .help("Cancel dictation")
                .accessibilityLabel("Cancel dictation")
            }
            if model.phase == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Transcribing")
            } else {
                CapsuleWaveform(model: model, isNotetaking: isNotetaking, animated: !reduceMotion, count: model.isHeldSession ? 13 : 9)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(waveformLabel)
            }
            if !model.isHeldSession {
                Button(action: model.toggleRecording) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.black.opacity(isRecording ? 1 : 0.45))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(isRecording ? 1 : 0.25), in: Circle())
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .disabled(!isRecording)
                .help("Finish dictation")
                .accessibilityLabel("Finish dictation")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(width: model.isHeldSession ? 96 : 108, height: 28)
        .contentShape(Capsule())
        .contextMenu { Button("Cancel dictation", action: model.cancelRecording) }
        .accessibilityActions { Button("Cancel dictation", action: model.cancelRecording) }
        .capsuleRegion(.dictation)
    }

    private var notetakingPill: some View {
        HStack(spacing: 4) {
            CapsuleWaveform(model: model, isNotetaking: isNotetaking, animated: !reduceMotion, count: 13)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(waveformLabel)
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
                .background(.white.opacity(0.16), in: Circle())
                .frame(width: 24, height: 24)
                .accessibilityLabel("Stop notetaker")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.meetings.stop() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: 100, height: 26)
        .contentShape(Capsule())
        .onTapGesture { if isMeetingRecording { model.meetings.stop() } }
        .contextMenu {
            Button("Stop notetaker", action: model.meetings.stop)
        }
        .accessibilityActions {
            Button("Stop notetaker", action: model.meetings.stop)
        }
        .capsuleRegion(.notetaker)
    }

    private var meetingButton: some View {
        HStack(spacing: 0) {
            Button(action: model.startNotetaker) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(hover.target == .notetaker ? 0.12 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Start notetaker")
            .capsuleRegion(.notetaker)
            Button {
                if let id = model.meetings.activeMeetingID {
                    model.onShowNotetaker?(id)
                } else {
                    model.selectedPage = .meetings
                    model.onShowDashboard?()
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(hover.target == .meetingNotes ? 1 : 0.6))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open meeting notes")
            .capsuleRegion(.meetingNotes)
        }
        .buttonStyle(.plain)
        .background { CapsuleGlass(cornerRadius: 14) }
    }

    private var waveformLabel: String {
        if isNotetaking { return isMeetingRecording ? "Meeting audio level" : "Starting notetaker" }
        switch model.phase {
        case .recording: return "Microphone input level"
        default: return "Starting microphone"
        }
    }
}

private struct CapsuleCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Counts down the last 30 seconds before dictation finishes at the recording limit.
private struct RecordingLimitLabel: View {
    let model: AppModel

    var body: some View {
        Group {
            if let secondsLeft = model.recordingSecondsLeft {
                Text("Stops in \(Duration.seconds(secondsLeft).formatted(.time(pattern: .minuteSecond)))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background { CapsuleGlass(cornerRadius: 14) }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.recordingSecondsLeft != nil) { _, warning in
            guard warning else { return }
            AccessibilityNotification.Announcement("Dictation stops in 30 seconds.").post()
        }
    }
}

/// Reads the live audio level in its own body so each level update redraws only the bars, not the whole capsule.
private struct CapsuleWaveform: View {
    let model: AppModel
    let isNotetaking: Bool
    let animated: Bool
    let count: Int

    var body: some View {
        Waveform(mode: mode, animated: animated, count: count)
    }

    private var mode: Waveform.Mode {
        if isNotetaking {
            guard model.meetings.capturing?.phase == .recording else { return .waiting }
            return .listening(VoiceLevels(values: [max(model.meetings.levels.me, model.meetings.levels.them)]))
        }
        return model.phase == .recording ? .listening(model.voiceLevels) : .waiting
    }
}

private struct CapsuleCountdown: View {
    let deadline: Date
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            GeometryReader { geometry in
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(.white.opacity(0.9))
                    .frame(width: geometry.size.width * (reduceMotion ? 1 : max(0, min(1, deadline.timeIntervalSince(context.date) / max(duration, 0.01)))))
            }
        }
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

private struct CapsuleGlass: View {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(white: 0.09))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay { shape.fill(.black.opacity(0.45)) }
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(contrast == .increased ? 0.6 : 0.16), lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

struct Waveform: View {
    enum Mode: Equatable {
        case waiting, processing
        case listening(VoiceLevels)
    }

    let mode: Mode
    let animated: Bool
    var color: Color = .white
    var count = 5
    @State private var history = LevelHistory()

    private static let barWidth: CGFloat = 2
    private static let pitch: CGFloat = 4.5
    private static let slotDuration = 0.06
    private static let loudnessExpansion: Float = 3

    var body: some View {
        switch mode {
        case .listening(let levels) where animated:
            TimelineView(.animation) { context in
                scrolling(levels, at: context.date)
            }
        case .processing where animated:
            TimelineView(.animation) { context in
                bars(at: context.date)
            }
        default:
            bars(at: .now)
        }
    }

    /// Draws the loudest level of each recent slot as a bar, newest sliding in on the right like a recorder's trace.
    private func scrolling(_ levels: VoiceLevels, at date: Date) -> some View {
        let position = date.timeIntervalSinceReferenceDate / Self.slotDuration
        history.record(levels.value(at: date), in: Int(position), count: count + 1)
        let values = history.values
        let slide = CGFloat(1 - position.truncatingRemainder(dividingBy: 1))
        let color = color
        return Canvas { context, size in
            let fade = size.width * 0.3
            for (index, value) in values.enumerated() {
                let x = size.width - Self.barWidth + (slide - CGFloat(values.count - 1 - index)) * Self.pitch
                guard x + Self.barWidth > 0, x < size.width else { continue }
                let loudness = pow(min(1, max(0, value)), Self.loudnessExpansion)
                let height = Self.barWidth + (size.height - Self.barWidth) * CGFloat(loudness)
                let bar = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                let opacity = 0.95 * min(1, max(0, (x + Self.barWidth) / fade))
                context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .color(color.opacity(opacity)))
            }
        }
        .frame(width: CGFloat(count) * Self.pitch - (Self.pitch - Self.barWidth), height: 14)
    }

    private func bars(at date: Date) -> some View {
        HStack(spacing: Self.pitch - Self.barWidth) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(mode == .waiting ? 0.4 : 0.95))
                    .frame(width: Self.barWidth, height: 3 + 11 * height(of: index, at: date))
            }
        }
        .frame(height: 14)
    }

    private func height(of index: Int, at date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let position = Double(index)
        let middle = Double(max(2, count) - 1) / 2
        let distance = abs(position - middle) / middle
        switch mode {
        case .waiting:
            return 0
        case .listening(let levels):
            return CGFloat(levels.value(at: date)) * (1 - 0.85 * distance * distance)
        case .processing:
            return 0.12 + 0.3 * (1 + sin(time * 6 - position * 0.75)) / 2
        }
    }
}

/// Keeps the loudest level heard in each recent time slot, oldest first; recording the same slot again only raises it.
private final class LevelHistory {
    private(set) var values: [Float] = []
    private var slot = 0

    func record(_ level: Float, in slot: Int, count: Int) {
        if values.count != count || slot < self.slot {
            values = Array(repeating: 0, count: count)
            self.slot = slot
        }
        let elapsed = min(slot - self.slot, count)
        values.removeFirst(elapsed)
        values.append(contentsOf: repeatElement(level, count: elapsed))
        values[count - 1] = max(values[count - 1], level)
        self.slot = slot
    }
}
