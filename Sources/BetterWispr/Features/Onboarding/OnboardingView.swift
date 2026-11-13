import AppKit
import BetterWisprCore
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, model, practice

    var title: String {
        switch self {
        case .welcome: L10n.tr("Talk instead of type")
        case .permissions: L10n.tr("Two quick permissions")
        case .model: L10n.tr("Get the speech model")
        case .practice: L10n.tr("Try it now")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: L10n.tr("Speak in any app and your words appear where your cursor is.")
        case .permissions: L10n.tr("BetterWispr needs your microphone to hear you. Accessibility lets it paste text for you.")
        case .model: L10n.tr("Choose a speech model. Downloaded models run offline.")
        case .practice: L10n.tr("Say a sentence and watch it turn into text.")
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
    @State private var appleSpeechAvailable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        _step = State(initialValue: OnboardingStep(rawValue: model.settings.onboardingStep) ?? .welcome)
    }

    private var speechChoices: [SpeechModel] {
        Self.speechChoices(from: model.models, appleSpeechAvailable: appleSpeechAvailable)
    }
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
        VStack(spacing: step == .model ? 18 : 28) {
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
            Label(model.settings.dictationMode == .hold
                ? L10n.tr("Hold %@ to start dictating", shortcut)
                : L10n.tr("Press %@ to start dictating", shortcut), systemImage: "keyboard")
            Label(L10n.tr("Built-in models keep your audio on this Mac"), systemImage: "lock.fill")
            Label(L10n.tr("Add names and terms in Vocabulary"), systemImage: "character.book.closed")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .labelStyle(OnboardingLabelStyle())
    }

    private var permissions: some View {
        Form {
            PermissionRow(title: L10n.tr("Microphone"), detail: L10n.tr("Required to dictate."), granted: model.microphoneGranted, action: model.requestMicrophone)
            PermissionRow(title: L10n.tr("Paste into apps"), detail: L10n.tr("Optional. Without it, text is copied to your clipboard."), granted: model.accessibilityGranted, action: model.requestAccessibility)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .frame(height: 150)
    }

    private var modelChoice: some View {
        Form {
            ForEach(speechChoices) { speechModel in
                speechModelRow(speechModel)
            }
            speakerDetectionRow
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: 236)
        .onAppear { appleSpeechAvailable = model.appleSpeechAvailable }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appleSpeechAvailable = model.appleSpeechAvailable
        }
    }

    static func speechChoices(from models: [SpeechModel], appleSpeechAvailable: Bool) -> [SpeechModel] {
        (["parakeet-ultra"] + (appleSpeechAvailable ? ["apple"] : []))
            .compactMap { id in models.first { $0.id == id } }
    }

    static func canContinue(from step: OnboardingStep, selected: SpeechModel, appleSpeechAvailable: Bool) -> Bool {
        step != .model || !selected.isUnavailable(appleSpeechAvailable: appleSpeechAvailable)
    }

    @ViewBuilder private func speechModelRow(_ speechModel: SpeechModel) -> some View {
        let selected = model.selectedModel.id == speechModel.id
        let installation = model.installation?.id == speechModel.id ? model.installation : nil
        let installed = model.isModelInstalled(speechModel)
        LabeledContent {
            if let installation, installation.failure == nil {
                HStack {
                    ProgressView(value: installation.progress).frame(width: 120)
                    Button(L10n.tr("Cancel"), action: model.cancelInstallation)
                }
            } else if installed && selected {
                ready
            } else if installed {
                Button(L10n.tr("Use")) { model.selectModel(speechModel) }
                    .disabled(model.isBusy)
            } else {
                Button(installation == nil ? L10n.tr("Download %@", String(speechModel.localizedSizeLabel)) : L10n.tr("Retry")) {
                    model.installModel(speechModel)
                }
                .disabled(model.isInstalling)
            }
        } label: {
            HStack(spacing: 6) {
                Text(speechModel.localizedName)
                if speechModel.id == "parakeet-ultra" { Text(L10n.tr("Recommended")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(modelDetail(for: speechModel, installation: installation))
        }
    }

    @ViewBuilder private var speakerDetectionRow: some View {
        let installation = model.installation?.id == AppModel.speakerDetectionID ? model.installation : nil
        LabeledContent {
            if model.speakerDetectionInstalled {
                ready
            } else if let installation, installation.failure == nil {
                HStack {
                    ProgressView(value: installation.progress).frame(width: 120)
                    Button(L10n.tr("Cancel"), action: model.cancelInstallation)
                }
            } else if model.speakerDetectionQueued {
                Button(L10n.tr("Cancel")) { model.speakerDetectionQueued = false }
            } else {
                Button(installation == nil ? L10n.tr("Download") : L10n.tr("Retry"), action: model.installSpeakerDetection)
            }
        } label: {
            Text(L10n.tr("Speaker detection"))
            Text(speakerDetectionDetail(installation))
        }
    }

    private func speakerDetectionDetail(_ installation: ModelInstallation?) -> String {
        if let installation, !model.speakerDetectionInstalled {
            return installation.failure.map { L10n.tr("Download stopped: %@", String($0)) } ?? installation.progressLabel
        }
        if model.speakerDetectionQueued { return L10n.tr("Downloads when the speech model is ready.") }
        return L10n.tr("Optional. Tells the voices in your meetings apart, on this Mac.")
    }

    private var ready: some View {
        Label {
            Text(L10n.tr("Ready"))
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .foregroundStyle(.secondary)
    }

    private func modelDetail(for speechModel: SpeechModel, installation: ModelInstallation?) -> String {
        if let installation {
            return installation.failure.map { L10n.tr("Download stopped: %@", String($0)) } ?? installation.progressLabel
        }
        if speechModel.id == "apple" { return L10n.tr("Uses macOS on-device speech recognition. No download.") }
        let selected = model.selectedModel
        return Self.selectedModelNote(selected: selected, isInstalled: model.isModelInstalled(selected), choices: speechChoices) ?? speechModel.localizedDetail
    }

    static func selectedModelNote(selected: SpeechModel, isInstalled: Bool, choices: [SpeechModel]) -> String? {
        guard !choices.contains(where: { $0.id == selected.id }) else { return nil }
        if selected.engine == .apple { return L10n.tr("Apple on-device speech isn’t available for your language on this Mac. Pick a model here to continue.") }
        return isInstalled ? L10n.tr("You’re using %@. Parakeet Ultra is recommended.", String(selected.localizedName)) : nil
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
        if model.settings.dictationMode == .hold { return L10n.tr("Hold %@, say something, then let go.", String(shortcut)) }
        return L10n.tr("Press %@, say something, then press it again.", String(shortcut))
    }

    private var bottomBar: some View {
        HStack {
            if step == .welcome {
                Button(L10n.tr("Skip"), action: model.finishOnboarding)
            } else {
                Button(L10n.tr("Back")) { go(to: OnboardingStep(rawValue: step.rawValue - 1)) }
            }
            Spacer()
            if step == .practice {
                Button(L10n.tr("Done"), action: model.finishOnboarding)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.tr("Continue")) { go(to: OnboardingStep(rawValue: step.rawValue + 1)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.canContinue(from: step, selected: model.selectedModel, appleSpeechAvailable: appleSpeechAvailable))
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
        .accessibilityLabel(L10n.tr("Step %@ of %@", String(step.rawValue + 1), String(OnboardingStep.allCases.count)))
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
