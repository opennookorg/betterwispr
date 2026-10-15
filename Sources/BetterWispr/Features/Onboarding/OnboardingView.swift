import BetterWisprCore
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, model, practice

    var title: String {
        switch self {
        case .welcome: "Talk instead of type"
        case .permissions: "Two quick permissions"
        case .model: "Get the speech model"
        case .practice: "Try it now"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "Speak in any app and your words appear where your cursor is."
        case .permissions: "BetterWispr needs your microphone to hear you. Accessibility lets it paste text for you."
        case .model: "Download the recommended model once and dictate offline."
        case .practice: "Say a sentence and watch it turn into text."
        }
    }

    var symbol: String? {
        switch self {
        case .welcome: nil
        case .permissions: "hand.raised.fill"
        case .model: "cpu.fill"
        case .practice: "mic.fill"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: .accentColor
        case .permissions: .blue
        case .model: .purple
        case .practice: .red
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step: OnboardingStep
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        _step = State(initialValue: OnboardingStep(rawValue: model.settings.onboardingStep) ?? .welcome)
    }

    private var recommended: SpeechModel? { model.models.first { $0.id == "parakeet-ultra" } }
    private var installation: ModelInstallation? { model.installation?.id == recommended?.id ? model.installation : nil }
    private var shortcut: String { model.settings.shortcut.displayName }

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(step)
                .transition(pageTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .modifier(ThemedPage())
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private var page: some View {
        VStack(spacing: 28) {
            hero.frame(height: 96)
            VStack(spacing: 10) {
                Text(step.title)
                    .font(.largeTitle.bold())
                Text(step.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 40)
    }

    @ViewBuilder private var hero: some View {
        if let symbol = step.symbol {
            SymbolTile(symbol: symbol, color: step.tint, size: 88)
        } else {
            HStack(spacing: 28) {
                BrandMark(size: 88)
                Waveform(mode: .listening(VoiceLevels(values: [0.8])), animated: false, color: step.tint)
                    .scaleEffect(4)
                    .frame(width: 72, height: 56)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .model: modelChoice
        case .practice: practice
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(model.settings.dictationMode == .hold ? "Hold" : "Press") \(shortcut) to start dictating", systemImage: "keyboard")
            Label("Built-in models keep your audio on this Mac", systemImage: "lock.fill")
            Label("Add names and terms in Vocabulary", systemImage: "character.book.closed")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .labelStyle(OnboardingLabelStyle())
    }

    private var permissions: some View {
        Form {
            PermissionRow(title: "Microphone", detail: "Required to dictate.", granted: model.microphoneGranted, action: model.requestMicrophone)
            PermissionRow(title: "Paste into apps", detail: "Optional. Without it, text is copied to your clipboard.", granted: model.accessibilityGranted, action: model.requestAccessibility)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: 150)
    }

    private var modelChoice: some View {
        Form {
            modelRow
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: 100)
    }

    @ViewBuilder private var modelRow: some View {
        let selected = model.selectedModel
        LabeledContent {
            if let installation, installation.failure == nil {
                HStack {
                    ProgressView(value: installation.progress).frame(width: 120)
                    Button("Cancel", action: model.cancelInstallation)
                }
            } else if let recommended, selected.id != recommended.id || !model.isModelInstalled(recommended) {
                if model.isModelInstalled(recommended) {
                    Button("Use \(recommended.name)") { model.selectModel(recommended) }
                        .disabled(model.isBusy)
                } else {
                    Button(installation == nil ? "Download \(recommended.sizeLabel)" : "Retry") {
                        model.installModel(recommended)
                    }
                    .disabled(model.isInstalling)
                }
            } else {
                Label {
                    Text("Ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            }
        } label: {
            Text(recommended?.name ?? selected.name)
            Text(modelDetail)
        }
    }

    private var modelDetail: String {
        if let installation {
            return installation.failure.map { "Download stopped: \($0)" } ?? installation.progressLabel
        }
        if let recommended, model.selectedModel.id != recommended.id, model.isModelInstalled(model.selectedModel) {
            return "You’re using \(model.selectedModel.name). \(recommended.name) is recommended."
        }
        return recommended?.detail ?? "Ready to use offline."
    }

    private var practice: some View {
        VStack(spacing: 16) {
            Waveform(mode: waveformMode, animated: !reduceMotion, color: .accentColor)
                .scaleEffect(2.5)
                .frame(width: 44, height: 36)
                .accessibilityHidden(true)
            Text(practiceText)
                .font(model.partialTranscript.isEmpty ? .body : .title3)
                .foregroundStyle(model.partialTranscript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var waveformMode: Waveform.Mode {
        switch model.phase {
        case .recording: .listening(model.voiceLevels)
        case .transcribing: .processing
        default: .waiting
        }
    }

    private var practiceText: String {
        if !model.partialTranscript.isEmpty { return model.partialTranscript }
        if model.isBusy { return model.statusMessage }
        if model.settings.dictationMode == .hold { return "Hold \(shortcut), say something, then let go." }
        return "Press \(shortcut), say something, then press it again."
    }

    private var bottomBar: some View {
        HStack {
            if step == .welcome {
                Button("Skip", action: model.finishOnboarding)
            } else {
                Button("Back") { go(to: OnboardingStep(rawValue: step.rawValue - 1)) }
            }
            Spacer()
            if step == .practice {
                Button("Done", action: model.finishOnboarding)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(to: OnboardingStep(rawValue: step.rawValue + 1)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .overlay { progressDots }
        .controlSize(.large)
        .padding(20)
    }

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == step ? 20 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private func go(to target: OnboardingStep?) {
        guard let target else { return }
        forward = target.rawValue > step.rawValue
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45)) { step = target }
        model.settings.onboardingStep = target.rawValue
        model.saveSettings()
    }
}

private struct OnboardingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            configuration.title
        }
    }
}
