import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import BetterWisprCore
import Carbon.HIToolbox
import Observation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

enum RecordingPhase: Equatable {
    case idle, preparing, recording, transcribing
    case cancelled, completed(String)
    case failed(DictationFailure)
    case unpasted(String)

    var isBusy: Bool { self == .preparing || self == .recording || self == .transcribing }
    var holdsMicrophone: Bool { self == .preparing || self == .recording }
}

struct DictationFailure: Equatable {
    var title: String
    var message: String
    var needsAccessibility = false
    var symbol: String {
        if needsAccessibility { return "lock.shield" }
        if self == .noSpeech { return "waveform.slash" }
        return "exclamationmark.triangle"
    }

    static func releasedEarly(_ shortcut: DictationShortcut) -> DictationFailure {
        DictationFailure(title: "Keep holding \(shortcut.displayName).", message: "Wait for the bars to move, then speak and release.")
    }
    static let noSpeech = DictationFailure(title: "No speech heard.", message: "Move closer to your microphone and try again.")
    static let pasteBlocked = DictationFailure(title: "Copied, not pasted.", message: "Allow Accessibility so text lands at your cursor. Press ⌘V for now.", needsAccessibility: true)
}

/// Owns temporary audio through transcription and the short cancellation undo window.
@MainActor
final class DictationRecording {
    let audio: RecordedAudio
    let model: SpeechModel
    let settings: AppSettings
    let vocabulary: [VocabularyEntry]
    let target: NSRunningApplication?
    let mode: WritingMode?
    let context: Task<DictationContext, Never>?

    init(audio: RecordedAudio, model: SpeechModel, settings: AppSettings, vocabulary: [VocabularyEntry],
         target: NSRunningApplication?, mode: WritingMode? = nil, context: Task<DictationContext, Never>? = nil) {
        self.audio = audio
        self.model = model
        self.settings = settings
        self.vocabulary = vocabulary
        self.target = target
        self.mode = mode
        self.context = context
    }

    deinit {
        context?.cancel()
        try? FileManager.default.removeItem(at: audio.url)
    }
}

struct ModelInstallation: Equatable {
    let id: String
    let token = UUID()
    var progress = 0.0
    var failure: String?

    var progressLabel: String {
        progress < 0.9 ? "Downloading… \(Int(progress / 0.9 * 100))%" : "Setting up on this Mac…"
    }
}

@MainActor @Observable
final class AppModel {
    static let onboardingVersion = 1
    static let phraseBoosterID = "phrase-booster"
    static let speakerDetectionID = "speaker-detection"
    static let builtInModelID = "built-in-model"
    static let unpastedCardSeconds = 5.0
    static let cancellationSeconds = 5.0

    var selectedPage: AppPage = .overview
    var phase: RecordingPhase = .idle {
        didSet {
            cardDismissal?.cancel()
            cardDeadline = nil
            if phase.isBusy != oldValue.isBusy {
                onBusyChange?(phase.isBusy)
                scheduleIdleUnload()
            }
            switch (oldValue.holdsMicrophone, phase.holdsMicrophone) {
            case (false, true) where settings.pauseMediaWhileDictating: mediaPauser.pause()
            case (true, false): mediaPauser.resume()
            default: break
            }
            onPresentationChange?()
        }
    }
    private(set) var cardDeadline: Date?
    private(set) var cardDuration = 0.0
    private var cancelledRecording: DictationRecording?
    var canUndoCancellation: Bool { phase == .cancelled && cancelledRecording != nil }
    var statusMessage = ""
    var partialTranscript = ""
    /// Preview only; the pasted text always comes from the batch recognition.
    var liveTranscript = LiveTranscript()
    var voiceLevels = VoiceLevels()
    var isHeldSession = false
    var recordingDuration: TimeInterval = 0
    var history: [Transcript] = []
    var vocabulary: [VocabularyEntry] = []
    var settings = AppSettings()
    var notesCLICatalogs: [NotesCLI: NotesCLICatalog] = [:]
    var notesCatalogErrors: [NotesCLI: String] = [:]
    var loadingNotesCatalogs: Set<NotesCLI> = []
    var models: [SpeechModel] { SpeechModel.catalog + settings.speechConnections.map(\.speechModel) }
    @ObservationIgnored lazy var updater = AppUpdater()
    let meetings: MeetingModel
    let transcriptions: TranscriptionModel
    let meetingDetector: MeetingDetector
    var installation: ModelInstallation?
    var phraseBoosterInstalled = false
    var speakerDetectionInstalled = false
    var speakerDetectionQueued = false
    var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    var accessibilityGranted = AXIsProcessTrusted()
    var calendarGranted = CalendarEvents.isAuthorized
    var calendarAccounts: [CalendarAccount] = []
    @ObservationIgnored let calendarEvents = CalendarEvents()
    var microphones: [AudioInputDevice] = []
    var automaticMicrophone: AudioInputDevice?
    var onPresentationChange: (() -> Void)?
    var onBusyChange: ((Bool) -> Void)?
    var onShowDashboard: (() -> Void)?
    var onShowNotetaker: ((UUID) -> Void)?

    @ObservationIgnored let mediaPauser: MediaPauser
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let startsServices: Bool
    @ObservationIgnored private let correctionWatcher = CorrectionWatcher()
    @ObservationIgnored private let globalShortcut = GlobalShortcut()
    @ObservationIgnored private let cancelShortcut = GlobalShortcut(id: 2)
    @ObservationIgnored private let customCancelShortcut = GlobalShortcut(id: 3)
    @ObservationIgnored private var microphoneObserver: AudioInputObserver?
    @ObservationIgnored private var shortcutWarning: String?
    @ObservationIgnored private var provider: (any SpeechProvider)?
    @ObservationIgnored private var preparedModelID: String?
    @ObservationIgnored private var loading: (id: String, task: Task<Void, any Error>)?
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var warmUp: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var live: LiveTranscriber?
    @ObservationIgnored private var cardDismissal: Task<Void, Never>?
    @ObservationIgnored private var shortcutPressedAt: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var targetApplication: NSRunningApplication?
    @ObservationIgnored private var writingMode: WritingMode?
    @ObservationIgnored private var dictationContext: Task<DictationContext, Never>?
    @ObservationIgnored private var activeRecording: DictationRecording?
    @ObservationIgnored private var feedbackSound: NSSound?
    @ObservationIgnored private var storageIsReadable = true
    @ObservationIgnored private var installedModelIDs: Set<String> = []
    var modelRevision = 0

    var selectedModel: SpeechModel { models.first { $0.id == settings.selectedModelID } ?? models[0] }
    var isBusy: Bool { phase.isBusy }
    var isInstalling: Bool { installation != nil && installation?.failure == nil }
    var needsOnboarding: Bool { storageIsReadable && settings.completedOnboardingVersion < Self.onboardingVersion }
    var failure: DictationFailure? { if case .failed(let failure) = phase { failure } else { nil } }
    var unpasted: String? { if case .unpasted(let text) = phase { text } else { nil } }
    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }
    var totalDuration: TimeInterval { history.reduce(0) { $0 + $1.duration } }

    /// Connected microphones, plus the saved one while it is unplugged so pickers can still show it.
    var microphoneChoices: [AudioInputDevice] {
        guard let saved = settings.microphone, !microphones.contains(where: { $0.id == saved.id }) else { return microphones }
        return microphones + [saved]
    }

    init(store: LocalStore = LocalStore(), startsServices: Bool = true, mediaPauser: MediaPauser = MediaPauser()) {
        self.store = store
        self.mediaPauser = mediaPauser
        self.startsServices = startsServices
        meetings = MeetingModel(store: startsServices ? nil : MeetingStore(directory: store.directory.appendingPathComponent("Meetings")))
        transcriptions = TranscriptionModel(store: startsServices ? nil : MeetingStore(directory: store.directory.appendingPathComponent("Transcriptions")))
        meetingDetector = MeetingDetector(meetings: meetings)
        do {
            let state = try store.load()
            settings = state.settings
            history = state.history
            vocabulary = state.vocabulary
        } catch {
            storageIsReadable = false
            statusMessage = "Could not read your saved workspace. It has been left untouched: \(error.localizedDescription)"
        }
        guard startsServices else { return }
        applyAppearance()
        migrateLegacyOnboarding()
        if !models.contains(where: { $0.id == settings.selectedModelID }) { settings.selectedModelID = "apple" }
        settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        meetings.notesSettings = settings
        meetings.remembersVoices = settings.rememberVoices
        for cli in Set([settings.notesCLI, settings.askSettings.notesCLI].compactMap { $0 }) { Task { await refreshNotesCLIModels(cli) } }
        refreshModels()
        refreshCalendars()
        recorder.onLevel = { [weak self] levels in self?.voiceLevels = levels }
        recorder.onError = { [weak self] error in
            guard let self, self.phase == .recording else { return }
            self.discardRecording()
            self.fail(DictationFailure(title: "Couldn’t continue recording.", message: error.localizedDescription))
        }
        refreshMicrophones()
        microphoneObserver = AudioInputObserver { [weak self] in self?.refreshMicrophones() }
        meetingDetector.isEnabled = settings.detectMeetings
        globalShortcut.onPress = { [weak self] in self?.shortcutPressed() }
        globalShortcut.onRelease = { [weak self] in self?.shortcutReleased() }
        cancelShortcut.onPress = { [weak self] in self?.cancelRecording() }
        customCancelShortcut.onPress = { [weak self] in self?.cancelRecording() }
        onBusyChange = { [weak self] busy in self?.armCancelShortcut(busy) }
        warmUpSelectedModel()
        let warmUpAfterWake: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warmUpSelectedModel(after: .seconds(3), reloading: self.settings.unloadModelWhenIdle == .never)
            }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: warmUpAfterWake)
        _ = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: warmUpAfterWake)
    }

    func shortcutPressed() {
        guard shortcutPressedAt == nil || !isBusy else { return }
        guard settings.dictationMode == .hold, !isBusy else { toggleRecording(); return }
        shortcutPressedAt = Date()
        startRecording(held: true)
    }

    func shortcutReleased() {
        guard let pressedAt = shortcutPressedAt else { return }
        shortcutPressedAt = nil
        guard phase == .preparing || phase == .recording else { return }
        if Date().timeIntervalSince(pressedAt) < 0.3 {
            isHeldSession = false
            if phase == .recording { statusMessage = "Listening. Press \(settings.shortcut.displayName) or click ✓ to finish." }
        }
        else if phase == .preparing { abandon(.releasedEarly(settings.shortcut)) }
        else { finishRecording() }
    }

    func registerShortcut() {
        do {
            try globalShortcut.register(settings.shortcut)
            if statusMessage == shortcutWarning { statusMessage = "" }
        } catch {
            statusMessage = "\(error.localizedDescription) Use the menu bar or Record button to dictate, or choose another shortcut in Settings."
            shortcutWarning = statusMessage
        }
    }

    func suspendShortcut() { globalShortcut.unregister() }

    private func armCancelShortcut(_ busy: Bool) {
        if busy {
            cancelShortcut.register(keyCode: UInt32(kVK_Escape), modifiers: settings.shortcut.cancelModifiers)
            if let custom = settings.cancelShortcut { try? customCancelShortcut.register(custom) }
        } else {
            cancelShortcut.unregister()
            customCancelShortcut.unregister()
        }
    }

    func changeShortcut(_ shortcut: DictationShortcut) {
        guard !isBusy else { return }
        if shortcut == settings.cancelShortcut {
            registerShortcut()
            ToastWindow.shared.show(Toast(failure: "Couldn’t use \(shortcut.displayName)", ShortcutError.alreadyAssigned(shortcut)))
            return
        }
        do {
            try globalShortcut.register(shortcut)
        } catch {
            registerShortcut()
            ToastWindow.shared.show(Toast(failure: "Couldn’t use \(shortcut.displayName)", error))
            return
        }
        if statusMessage == shortcutWarning { statusMessage = "" }
        settings.shortcut = shortcut
        saveSettings()
    }

    func changeCancelShortcut(_ shortcut: DictationShortcut?) {
        guard !isBusy else { return }
        if let shortcut {
            do {
                if shortcut.isModifierOnly { throw ShortcutError.cancelNeedsKey }
                if shortcut == settings.shortcut { throw ShortcutError.alreadyAssigned(shortcut) }
                try customCancelShortcut.register(shortcut)
                customCancelShortcut.unregister()
            } catch {
                ToastWindow.shared.show(Toast(failure: "Couldn’t use \(shortcut.displayName)", error))
                return
            }
        }
        settings.cancelShortcut = shortcut
        saveSettings()
    }

    func toggleRecording() {
        if phase == .recording { finishRecording(); return }
        startRecording(held: false)
    }

    private func startRecording(held: Bool) {
        guard !isBusy else { return }
        cancelledRecording = nil
        feedbackSound?.stop()
        correctionWatcher.stop()
        guard isModelInstalled(selectedModel) else {
            selectedPage = .models
            fail(DictationFailure(title: "Download a model first.", message: "Download \(selectedModel.name) in Models before recording."))
            return
        }
        targetApplication = NSWorkspace.shared.frontmostApplication
        let modes = settings.modes
        let website = modes.needsWebsite ? targetApplication.flatMap(WebsiteReader.read) : nil
        writingMode = modes.match(app: targetApplication?.bundleIdentifier)?.mode
        dictationContext?.cancel()
        dictationContext = website == nil ? captureContext(for: settings.applying(writingMode)) : nil
        isHeldSession = held
        let token = UUID()
        generation = token
        phase = .preparing
        statusMessage = "Starting microphone…"
        partialTranscript = ""
        liveTranscript = LiveTranscript()
        recordingDuration = 0
        let model = selectedModel
        let live = model.engine == .parakeet && settings.showLiveText ? LiveTranscriber() : nil
        live?.onUpdate = { [weak self] transcript in
            guard let self, self.generation == token else { return }
            self.liveTranscript = transcript
        }
        live?.beginBuffering()
        self.live = live
        var onSamples: (@Sendable ([Float]) -> Void)?
        if let live { onSamples = { samples in Task { @MainActor in live.append(samples) } } }
        operation = Task { [weak self, onSamples] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try model.connection?.validateLanguage(self.settings.language)
                if model.engine == .apple {
                    try AppleSpeechProvider.checkAvailability(language: self.settings.language == "auto" ? nil : self.settings.language)
                }
                if model.engine == .apple || model.engine == .api { try await self.prepare(model) }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.recorder.silenceThreshold = self.settings.silenceThreshold
                self.recorder.microphone = self.settings.microphone
                self.statusMessage = "Starting microphone…"
                try await self.recorder.start(onSamples: onSamples)
                let url = await website?.value
                try Task.checkCancellation()
                guard self.generation == token else { return }
                if let url, let app = self.targetApplication {
                    self.writingMode = modes.match(url: url, app: app.bundleIdentifier)?.mode
                    self.dictationContext = self.captureContext(for: self.settings.applying(self.writingMode))
                }
                self.microphoneGranted = true
                self.phase = .recording
                self.playFeedback(.started)
                let shortcut = self.settings.shortcut.displayName
                self.statusMessage = self.isHeldSession ? "Listening. Release \(shortcut) to finish." : "Listening. Press \(shortcut) or click ✓ to finish."
                self.warmUpSelectedModel()
                self.warmUpNotesModel(token: token)
                self.startLivePreview(live, model: model, token: token)
                let started = Date()
                self.ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.recordingDuration = Date().timeIntervalSince(started)
                        // Keep dictation bounded; a new recording can start immediately afterwards.
                        if self.recordingDuration >= AudioRecorder.maximumDuration { self.finishRecording(); return }
                    }
                }
            } catch {
                guard self.generation == token else { return }
                self.recorder.cancel()
                self.endLivePreview()
                self.dictationContext.take()?.cancel()
                self.fail(DictationFailure(title: "Couldn’t start dictation.", message: error.localizedDescription))
            }
        }
    }

    /// Runs preview passes once the warm-up load has finished; it never starts a load itself.
    private func startLivePreview(_ live: LiveTranscriber?, model: SpeechModel, token: UUID) {
        guard let live else { return }
        let language = settings.language == "auto" ? nil : settings.language
        Task { @MainActor [weak self] in
            if let loading = self?.loading, loading.id == model.id { _ = try? await loading.task.value }
            guard let self, self.generation == token, self.preparedModelID == model.id,
                  let parakeet = self.provider as? ParakeetProvider else { return }
            live.start { try await parakeet.liveTranscribe($0, language: language) }
        }
    }

    private func endLivePreview() {
        live?.cancel()
        live = nil
        liveTranscript = LiveTranscript()
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        ticker?.cancel()
        ticker = nil
        voiceLevels = VoiceLevels()
        let token = generation
        let model = selectedModel
        let settings = settings
        let entries = vocabulary
        let target = targetApplication
        let mode = writingMode
        let context = dictationContext.take()
        let live = live
        phase = .transcribing
        statusMessage = "Finishing recording…"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.recorder.finish()
                await live?.stop()
                if self.live === live { self.live = nil }
                guard self.generation == token, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: audio.url)
                    return
                }
                self.recordingDuration = audio.duration
                guard audio.hasSpeech else {
                    try? FileManager.default.removeItem(at: audio.url)
                    self.fail(.noSpeech)
                    return
                }
                self.playFeedback(.finished)
                self.transcribe(DictationRecording(audio: audio, model: model, settings: settings,
                                                  vocabulary: entries, target: target, mode: mode, context: context))
            } catch {
                guard self.generation == token else { return }
                self.recorder.cancel()
                self.endLivePreview()
                self.fail(DictationFailure(title: "Couldn’t finish recording.", message: error.localizedDescription))
            }
        }
    }

    func transcribe(_ recording: DictationRecording) {
        let token = generation
        activeRecording = recording
        let audio = recording.audio
        let model = recording.model
        let language = recording.settings.language == "auto" ? nil : recording.settings.language
        let entries = recording.vocabulary
        let hints = VocabularyProcessor.hints(entries)
        let context = recording.context
        let spellsScreenNames = self.spellsScreenNames(with: model, language: recording.settings.language)
        let appBundleID = recording.target?.bundleIdentifier
        phase = .transcribing
        statusMessage = model.engine == .api ? "Transcribing with \(model.name)…" : "Transcribing on your Mac…"
        operation = Task { [weak self] in
            defer {
                if self?.generation == token { self?.activeRecording = nil }
            }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let screenTerms = spellsScreenNames ? await context?.value(within: .milliseconds(300), cancellingOnTimeout: false)?.spellingTerms() ?? [] : []
                try await self.prepare(model, language: recording.settings.language)
                try Task.checkCancellation()
                guard self.generation == token, let provider = self.provider else { return }
                (provider as? WhisperKitProvider)?.detectionLanguages = recording.settings.dictationLanguages
                let recognitionStarted = ContinuousClock.now
                let raw = try await provider.transcribe(audioURL: audio.url, language: language, vocabulary: hints, screenTerms: screenTerms)
                Logger(subsystem: "org.betterwispr.app", category: "DictationTiming").notice("Recognition completed: elapsed=\(String(describing: recognitionStarted.duration(to: .now)), privacy: .public) empty=\(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let recognized = recording.settings.chineseScript?.convert(raw, language: language) ?? raw
                let lightlyCleaned = TranscriptCleaner.clean(recognized, language: language)
                let trigger = recording.settings.modes.match(transcript: lightlyCleaned)
                let mode = trigger?.mode ?? recording.mode
                let writingSettings = recording.settings.applying(mode)
                let cleanup = writingSettings.cleanup
                let tone = writingSettings.tone(for: AppCategory(bundleID: appBundleID).style)
                let base = cleanup == .none ? recognized.trimmingCharacters(in: .whitespacesAndNewlines) : lightlyCleaned
                let cleaned = trigger.flatMap { [$0.mode].match(transcript: base)?.transcript } ?? base
                let sharesContext = recording.settings.sharesContext(startedIn: recording.mode, trigger: trigger?.mode)
                if !sharesContext { context?.cancel() }
                let heard = VocabularyProcessor.correctedCommands(entries, in: cleaned)
                var spoken = language == nil || language?.hasPrefix("en") == true ? VoiceCommands.apply(heard.text) : heard.text
                let english = TranscriptCleaner.isEnglish(spoken, language: language)
                if english, let email = EmailDictation.compose(spoken) {
                    spoken = email
                } else if english, cleanup == .medium, MeetingNotesGenerator.availability(settings: writingSettings) == .available {
                    self.statusMessage = "Editing with \(writingSettings.notesModelName)…"
                    let polished = await TranscriptPolisher.polish(spoken, settings: writingSettings, vocabulary: hints,
                                                                   context: sharesContext ? await context?.value(within: .seconds(1)) : nil,
                                                                   instructions: mode?.instructions ?? "")
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    spoken = StyleFormatter.apply(tone, to: polished ?? spoken)
                } else if english {
                    spoken = StyleFormatter.apply(tone, to: spoken)
                }
                let (text, fixes) = VocabularyProcessor.corrected(entries, in: spoken)
                guard !text.isEmpty else { self.fail(.noSpeech); return }
                self.partialTranscript = text
                let transcript = Transcript(text: text, rawText: raw, duration: audio.duration,
                                            modelName: model.name, language: language ?? "auto",
                                            appBundleID: appBundleID, vocabularyFixes: fixes + heard.fixes + provider.vocabularyFixes)
                var persistenceWarning: String?
                if writingSettings.saveHistory {
                    self.history.insert(transcript, at: 0)
                    do { try self.persist() } catch { persistenceWarning = error.localizedDescription }
                }
                let integration: (any TextOutputIntegration)? = writingSettings.autoPaste
                    ? FocusedAppIntegration(keepsCopy: writingSettings.copyToClipboard)
                    : writingSettings.copyToClipboard ? ClipboardIntegration() : nil
                self.activeRecording = nil
                let result = try await integration?.deliver(text, to: recording.target)
                guard self.generation == token else { return }
                if result == .copiedForManualPaste && !AXIsProcessTrusted() { self.fail(.pasteBlocked) }
                else if result == .copiedForManualPaste {
                    self.statusMessage = ""
                    self.present(.unpasted(text), for: Self.unpastedCardSeconds)
                    self.playFeedback(.attention)
                } else {
                    self.statusMessage = ""
                    switch result {
                    case .pasted:
                        self.phase = .idle
                        if writingSettings.learnCorrections, let app = recording.target {
                            self.correctionWatcher.watch(text, in: app) { [weak self] in self?.learn(from: $0, to: $1) }
                        }
                    case .copied: self.present(.completed("Copied to clipboard"), for: 1.6)
                    case nil: self.present(.completed("Transcript ready"), for: 1.6)
                    case .copiedForManualPaste: break
                    }
                }
                if let persistenceWarning { self.statusMessage = "History could not be saved: \(persistenceWarning)" }
            } catch {
                guard self.generation == token else { return }
                self.fail(DictationFailure(title: "Couldn’t transcribe.", message: error.localizedDescription))
            }
        }
    }

    func cancelRecording() {
        guard isBusy else { return }
        let recoverable: DictationRecording?
        if phase == .recording, let audio = try? recorder.stop() {
            let recording = DictationRecording(audio: audio, model: selectedModel, settings: settings, vocabulary: vocabulary,
                                              target: targetApplication, mode: writingMode, context: dictationContext.take())
            recoverable = audio.hasSpeech ? recording : nil
        } else {
            recoverable = activeRecording
        }
        discardRecording()
        cancelledRecording = recoverable
        present(.cancelled, for: Self.cancellationSeconds)
        playFeedback(.cancelled)
    }

    func undoCancellation() {
        guard canUndoCancellation, let recording = cancelledRecording else { return }
        cancelledRecording = nil
        generation = UUID()
        isHeldSession = false
        transcribe(recording)
    }

    /// Immediate cleanup for failures and quitting; only user cancellation offers Undo.
    func discardRecording() {
        generation = UUID()
        shortcutPressedAt = nil
        correctionWatcher.stop()
        dictationContext.take()?.cancel()
        operation?.cancel()
        operation = nil
        ticker?.cancel()
        ticker = nil
        warmUp?.cancel()
        provider?.cancel()
        recorder.cancel()
        endLivePreview()
        activeRecording = nil
        cancelledRecording = nil
        feedbackSound?.stop()
        // A cancelled preparation may leave a partially loaded provider; load cleanly next time.
        if loading == nil, phase == .transcribing || preparedModelID == nil {
            provider = nil
            preparedModelID = nil
        }
        voiceLevels = VoiceLevels()
        partialTranscript = ""
        phase = .idle
        statusMessage = "Cancelled."
    }

    private func prepare(_ model: SpeechModel, language: String? = nil) async throws {
        let language = language ?? settings.language
        try model.connection?.validateLanguage(language)
        if model.engine == .apple {
            try AppleSpeechProvider.checkAvailability(language: language == "auto" ? nil : language)
        }
        let token = generation
        if preparedModelID != model.id || provider == nil { try await load(model).value }
        warmUp?.cancel()
        await warmUp?.value
        try Task.checkCancellation()
        guard generation == token, let provider else { throw CancellationError() }
        observe(provider, token: token)
    }

    /// Loads an installed model once, sharing the in-flight load so a cancelled dictation never discards it.
    @discardableResult
    private func load(_ model: SpeechModel) -> Task<Void, any Error> {
        if let loading, loading.id == model.id { return loading.task }
        let next = model.makeProvider()
        preparedModelID = nil
        provider = next
        let task = Task { [weak self] in
            defer { if self?.provider === next { self?.loading = nil } }
            try await next.prepare(model: model, download: false)
            guard let self, self.provider === next else { throw CancellationError() }
            self.preparedModelID = model.id
            self.scheduleIdleUnload()
        }
        loading = (model.id, task)
        return task
    }

    var isSpeechModelLoaded: Bool { provider != nil }

    /// Releases the speech model once it sits unused for the idle period chosen in Settings; the next dictation loads it again.
    func scheduleIdleUnload(after delay: Duration? = nil) {
        idleUnload?.cancel()
        guard let idle = settings.unloadModelWhenIdle.delay, !isBusy else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: delay ?? idle)
            guard let self, !Task.isCancelled, !self.isBusy, self.loading == nil else { return }
            self.warmUp?.cancel()
            self.provider?.cancel()
            self.provider = nil
            self.preparedModelID = nil
        }
    }

    /// Loads the selected local model, unless idle with `reloading` off, and when idle transcribes a second of quiet noise and discards the text.
    private func warmUpSelectedModel(after delay: Duration = .zero, reloading: Bool = true) {
        let model = selectedModel
        guard model.engine != .apple, model.engine != .api, isModelInstalled(model) else { return }
        guard !isBusy else {
            if preparedModelID != model.id { load(model) }
            return
        }
        warmUp?.cancel()
        warmUp = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.selectedModel.id == model.id else { return }
            if self.preparedModelID != model.id {
                guard reloading else { return }
                try? await self.load(model).value
            }
            guard !Task.isCancelled, !self.isBusy, self.preparedModelID == model.id, let provider = self.provider,
                  let clip = try? WarmUpClip.url() else { return }
            let started = ContinuousClock.now
            let finished = (try? await provider.transcribe(audioURL: clip, language: nil, vocabulary: [])) != nil
            Logger(subsystem: "org.betterwispr.app", category: "DictationTiming").notice("Warm-up \(finished ? "completed" : "stopped", privacy: .public): model=\(model.id, privacy: .public) elapsed=\(String(describing: started.duration(to: .now)), privacy: .public)")
        }
    }

    /// Loads the dictation editing model while the user speaks, unless the recording ends within 450 ms.
    private func warmUpNotesModel(token: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.generation == token, self.phase == .recording else { return }
            let settings = self.settings.applying(self.writingMode)
            guard settings.cleanup == .medium, settings.language == "auto" || settings.language.hasPrefix("en"),
                  MeetingNotesGenerator.availability(settings: settings) == .available else { return }
            await MeetingNotesGenerator.warmUp(settings: settings)
        }
    }

    /// Starts reading screen context when Parakeet with the phrase booster can spell names from it or Medium cleanup can show it, with the clipboard, to an available notes model.
    private func captureContext(for settings: AppSettings) -> Task<DictationContext, Never>? {
        guard settings.useScreenContext else { return nil }
        let showsNotesModel = settings.cleanup == .medium && MeetingNotesGenerator.availability(settings: settings) == .available
        guard showsNotesModel || spellsScreenNames(with: selectedModel, language: settings.language) else { return nil }
        return targetApplication.map { DictationContext.capture(from: $0, recognizingScreen: settings.recognizeScreenText, readingClipboard: showsNotesModel) }
    }

    private func spellsScreenNames(with model: SpeechModel, language: String) -> Bool {
        phraseBoosterInstalled && model.engine == .parakeet && model.languages?.contains("en") == true
            && (language == "auto" || language.hasPrefix("en"))
    }

    private func observe(_ provider: any SpeechProvider, token: UUID) {
        provider.onPartialTranscript = { [weak self] text in
            guard let self, self.generation == token, self.phase == .transcribing else { return }
            self.partialTranscript = text
        }
    }

    /// Downloads a local model beside dictation, then switches to it unless the user chose another model meanwhile.
    func installModel(_ model: SpeechModel) {
        guard !isInstalling, model.engine == .parakeet || model.engine == .whisperKit else { return }
        let installer = model.makeProvider()
        let selection = settings.selectedModelID
        install(id: model.id, name: model.name) { report in
            installer.onProgress = report
            try await installer.prepare(model: model, download: true)
        } completion: { [weak self] in
            guard let self else { return }
            installer.onProgress = nil
            let boosterNote = model.engine == .parakeet && !self.phraseBoosterInstalled
                ? " The phrase booster didn’t download. Get it in Vocabulary." : ""
            if self.settings.selectedModelID == selection, !self.isBusy {
                self.selectModel(model, prepared: installer)
                self.statusMessage = "\(model.name) is ready for offline dictation.\(boosterNote)"
            } else {
                self.statusMessage = "\(model.name) is installed. Choose Use in Models to switch to it.\(boosterNote)"
            }
        }
    }

    func installPhraseBooster() {
        guard !isInstalling else { return }
        install(id: Self.phraseBoosterID, name: "the phrase booster") { report in
            try await ParakeetProvider.installPhraseBooster { fraction in Task { @MainActor in report(fraction * 0.9) } }
        } completion: { [weak self] in
            self?.statusMessage = "Parakeet now uses your vocabulary to spell names and terms."
        }
    }

    func installSpeakerDetection() {
        guard !isInstalling else {
            speakerDetectionQueued = installation?.id != Self.speakerDetectionID
            return
        }
        speakerDetectionQueued = false
        install(id: Self.speakerDetectionID, name: "speaker detection") { report in
            try await SpeakerDetection.install { fraction in Task { @MainActor in report(fraction * 0.9) } }
        } completion: { [weak self] in
            self?.statusMessage = "New meetings will tell the speakers on the call apart."
        }
    }

    func installBuiltInModel() {
        guard !isInstalling else { return }
        let selection = settings.notesSelection
        install(id: Self.builtInModelID, name: BuiltInModel.displayName) { report in
            try await BuiltInModel.install { fraction in Task { @MainActor in report(fraction * 0.9) } }
        } completion: { [weak self] in
            guard let self else { return }
            if self.settings.notesSelection == selection, self.meetings.runs.isEmpty {
                self.selectNotesModel(.builtIn)
                self.statusMessage = "\(BuiltInModel.displayName) now writes meeting notes on this Mac."
            } else {
                self.statusMessage = "\(BuiltInModel.displayName) is installed. Choose it as the notes provider in Models."
            }
        }
    }

    func removeBuiltInModel() {
        guard !isInstalling, canEditConnections else { return }
        Task {
            do { try await BuiltInModel.remove() }
            catch { statusMessage = "Couldn’t remove \(BuiltInModel.displayName): \(error.localizedDescription)" }
            refreshModels()
        }
    }

    func cancelInstallation() {
        installTask?.cancel()
        installation = nil
        speakerDetectionQueued = false
        statusMessage = "Download cancelled."
    }

    private func install(
        id: String, name: String,
        _ work: @escaping @MainActor (_ report: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        let next = ModelInstallation(id: id)
        installation = next
        statusMessage = "Downloading \(name)…"
        let report: @MainActor @Sendable (Double) -> Void = { [weak self] progress in
            guard let self, let current = self.installation, current.token == next.token else { return }
            self.installation?.progress = max(current.progress, min(1, progress))
        }
        let previous = installTask
        installTask = Task { [weak self] in
            await previous?.value
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading \(name)")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try Task.checkCancellation()
                try await work(report)
                guard let self, self.installation?.token == next.token else { return }
                self.installation = nil
                self.installTask = nil
                self.refreshModels()
                completion()
                if self.speakerDetectionQueued { self.installSpeakerDetection() }
            } catch {
                guard let self, self.installation?.token == next.token else { return }
                self.installTask = nil
                self.speakerDetectionQueued = false
                self.refreshModels()
                self.installation?.failure = error.localizedDescription
                self.statusMessage = "Couldn’t download \(name): \(error.localizedDescription)"
            }
        }
    }

    func selectModel(_ model: SpeechModel, prepared: (any SpeechProvider)? = nil) {
        guard !isBusy else { return }
        settings.selectedModelID = model.id
        provider?.cancel()
        loading?.task.cancel()
        provider = prepared
        preparedModelID = prepared == nil ? nil : model.id
        loading = nil
        saveSettings()
        warmUpSelectedModel()
        scheduleIdleUnload()
    }

    func isModelInstalled(_ model: SpeechModel) -> Bool {
        _ = modelRevision
        return model.engine == .apple || model.engine == .api || installedModelIDs.contains(model.id)
    }

    var canEditConnections: Bool { !isBusy && meetings.runs.isEmpty && transcriptions.job == nil }

    func saveConnection(_ connection: SpeechConnection, key: String?, forNotes: Bool = false) throws {
        guard canEditConnections else { throw SpeechError.busy }
        _ = try connection.validatedURL()
        let keys = forNotes ? SpeechAPIKeyStore.notes : SpeechAPIKeyStore()
        let previousKey = try keys.read(for: connection)
        let newKey = key ?? previousKey ?? ""
        try connection.validateAPIKey(newKey)
        let previous = settings
        var connections = forNotes ? settings.notesConnections : settings.speechConnections
        let oldConnection = connections.first { $0.id == connection.id }
        try keys.save(newKey, for: connection)
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        if forNotes { settings.notesConnections = connections } else { settings.speechConnections = connections }
        if forNotes, let oldConnection, oldConnection.keychainAccount != connection.keychainAccount { settings.deselectNotesConnection(connection.id) }
        if !forNotes, let oldConnection, oldConnection.keychainAccount != connection.keychainAccount,
           settings.selectedModelID == connection.speechModel.id {
            settings.selectedModelID = "apple"
        }
        do { try persist() }
        catch {
            settings = previous
            try keys.save(previousKey ?? "", for: connection)
            throw error
        }
        meetings.notesSettings = settings
        if !forNotes, previous.selectedModelID == connection.speechModel.id {
            provider?.cancel()
            loading?.task.cancel()
            provider = nil
            preparedModelID = nil
            loading = nil
        }
        if let oldConnection, oldConnection.keychainAccount != connection.keychainAccount {
            do { try keys.save("", for: oldConnection) }
            catch { statusMessage = "Connection saved, but its previous Keychain entry could not be removed: \(error.localizedDescription)" }
        }
    }

    func deleteConnection(_ connection: SpeechConnection, forNotes: Bool = false) throws {
        guard canEditConnections else { throw SpeechError.busy }
        let keys = forNotes ? SpeechAPIKeyStore.notes : SpeechAPIKeyStore()
        let previousKey = try keys.read(for: connection)
        let previous = settings
        try keys.save("", for: connection)
        if forNotes {
            settings.notesConnections.removeAll { $0.id == connection.id }
            settings.deselectNotesConnection(connection.id)
        } else {
            settings.speechConnections.removeAll { $0.id == connection.id }
            if settings.selectedModelID == connection.speechModel.id { settings.selectedModelID = "apple" }
        }
        do { try persist() }
        catch {
            settings = previous
            try keys.save(previousKey ?? "", for: connection)
            throw error
        }
        meetings.notesSettings = settings
        if !forNotes {
            provider?.cancel()
            loading?.task.cancel()
            provider = nil
            preparedModelID = nil
            loading = nil
            warmUpSelectedModel()
        }
    }

    private func refreshModels() {
        installedModelIDs = Set(models.filter { WhisperKitProvider.isInstalled($0) || ParakeetProvider.isInstalled($0) }.map(\.id))
        phraseBoosterInstalled = ParakeetProvider.isPhraseBoosterInstalled()
        speakerDetectionInstalled = SpeakerDetection.isInstalled()
        meetings.builtInModelInstalled = BuiltInModel.isInstalled()
        modelRevision += 1
    }

    func copyTranscript(_ transcript: Transcript) {
        copyText(transcript.text)
    }

    func copyLatestTranscript() { copyText(partialTranscript) }

    func copyText(_ text: String) {
        Task {
            do { ToastWindow.shared.show(Toast(try await ClipboardIntegration().deliver(text, to: nil))) }
            catch { ToastWindow.shared.show(Toast(failure: "Couldn’t copy", error)) }
        }
    }

    func deleteTranscript(_ transcript: Transcript) {
        let previous = history
        history.removeAll { $0.id == transcript.id }
        do {
            try persist()
            ToastWindow.shared.show(Toast(title: "Deleted", message: "The dictation was removed from history.", systemImage: "trash"))
        } catch {
            history = previous
            ToastWindow.shared.show(Toast(failure: "Couldn’t delete dictation", error))
        }
    }

    func updateTranscript(_ transcript: Transcript, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != transcript.text, let index = history.firstIndex(where: { $0.id == transcript.id }) else { return }
        let previous = history
        history[index].text = text
        do { try persist() } catch {
            history = previous
            ToastWindow.shared.show(Toast(failure: "Couldn’t save edit", error))
            return
        }
        if settings.learnCorrections { learn(from: transcript.text, to: text) }
    }

    func restoreOriginal(_ transcript: Transcript) {
        let original = transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, let index = history.firstIndex(where: { $0.id == transcript.id }), history[index].text != original else { return }
        let previous = history
        history[index].text = original
        do { try persist() } catch {
            history = previous
            ToastWindow.shared.show(Toast(failure: "Couldn’t restore the original", error))
        }
    }

    private func learn(from original: String, to edited: String) {
        let candidates = CorrectionLearner.corrections(from: original, to: edited)
        guard !candidates.isEmpty else { return }
        let settings = settings
        Task { [weak self] in
            let reviewed = await CorrectionReviewer.review(candidates, from: original, to: edited, settings: settings)
            self?.learn(reviewed ?? candidates.map { .replacementAndVocabulary(heard: $0.heard, corrected: $0.corrected) })
        }
    }

    private func learn(_ decisions: [CorrectionDecision]) {
        guard settings.learnCorrections else { return }
        let added = CorrectionDecision.entries(for: decisions, in: vocabulary)
        guard !added.isEmpty else { return }
        let previous = vocabulary
        vocabulary += added
        do {
            try persist()
            let ids = Set(added.map(\.id))
            ToastWindow.shared.show(Toast(title: "Learned \(added.map { "“\($0.replacement.isEmpty ? $0.phrase : $0.replacement)”" }.joined(separator: ", "))",
                                          message: "BetterWispr will spell it this way next time. Manage it in Vocabulary.",
                                          systemImage: "sparkles",
                                          action: Toast.Action(title: "Undo") { [weak self] in
                                              guard let self else { return }
                                              let learned = vocabulary
                                              vocabulary.removeAll { ids.contains($0.id) }
                                              do { try persist() } catch {
                                                  vocabulary = learned
                                                  ToastWindow.shared.show(Toast(failure: "Couldn’t undo", error))
                                              }
                                          }))
        } catch {
            vocabulary = previous
        }
    }

    func addVocabulary(phrase: String, replacement: String) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 100, replacement.count <= 100 else {
            statusMessage = "Use a phrase and spelling of at most 100 characters."; return
        }
        guard vocabulary.count < 200 else { statusMessage = "Keep your vocabulary to 200 entries for focused hints."; return }
        guard !vocabulary.contains(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) else {
            statusMessage = "That phrase is already in your vocabulary."; return
        }
        vocabulary.append(VocabularyEntry(phrase: phrase, replacement: replacement))
        saveSettings()
    }

    func deleteVocabulary(_ entry: VocabularyEntry) {
        let previous = vocabulary
        vocabulary.removeAll { $0.id == entry.id }
        do {
            try persist()
            ToastWindow.shared.show(Toast(title: "Deleted", message: "“\(entry.phrase)” was removed from your vocabulary.", systemImage: "trash"))
        } catch {
            vocabulary = previous
            ToastWindow.shared.show(Toast(failure: "Couldn’t delete word", error))
        }
    }

    func finishOnboarding() {
        settings.completedOnboardingVersion = Self.onboardingVersion
        settings.onboardingStep = 0
        saveSettings()
    }

    func showOnboarding() {
        settings.completedOnboardingVersion = 0
        settings.onboardingStep = 0
        saveSettings()
    }

    /// Moves 0.1.0's UserDefaults flag into the workspace, honouring it only while that workspace still exists.
    private func migrateLegacyOnboarding() {
        let key = "onboardingCompleted"
        let defaults = UserDefaults.standard
        guard storageIsReadable, defaults.object(forKey: key) != nil else { return }
        if defaults.bool(forKey: key), settings.completedOnboardingVersion == 0,
           FileManager.default.fileExists(atPath: store.stateURL.path) {
            settings.completedOnboardingVersion = Self.onboardingVersion
            guard (try? persist()) != nil else { return }
        }
        defaults.removeObject(forKey: key)
    }

    func saveSettings() {
        if startsServices { applyDockVisibility() }
        do {
            let registered = SMAppService.mainApp.status == .enabled
            if settings.launchAtLogin != registered {
                if settings.launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            try persist()
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            statusMessage = "Could not save settings: \(error.localizedDescription)"
        }
        applyAppearance()
        if startsServices { meetingDetector.isEnabled = settings.detectMeetings }
        meetings.remembersVoices = settings.rememberVoices
        onPresentationChange?()
    }

    func applyDockVisibility() {
        let application = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        guard application.activationPolicy() != policy else { return }
        if !application.setActivationPolicy(policy) {
            settings.showInDock = application.activationPolicy() == .regular
            statusMessage = "Could not change Dock visibility. Try restarting BetterWispr."
        }
    }

    private func applyAppearance() {
        NSApplication.shared.appearance = switch settings.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func persist() throws {
        guard storageIsReadable else {
            throw NSError(domain: "BetterWispr", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The existing workspace could not be read, so it will not be overwritten. Back it up in \(store.directory.path) and restart."])
        }
        var state = SavedState()
        state.settings = settings
        state.history = history
        state.vocabulary = vocabulary
        try store.save(state)
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BetterWispr-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history).write(to: url, options: .atomic)
            statusMessage = "History exported."
        } catch { statusMessage = "Export failed: \(error.localizedDescription)" }
    }

    func requestMicrophone() {
        Task {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
            if !microphoneGranted {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Turning the integration on asks for Calendar access; a denial turns it back off and opens Privacy settings.
    func useCalendar(_ isOn: Bool) {
        settings.useCalendar = isOn
        saveSettings()
        guard isOn else { return }
        Task {
            calendarGranted = await calendarEvents.requestAccess()
            guard calendarGranted else {
                settings.useCalendar = false
                saveSettings()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                return
            }
            calendarAccounts = await calendarEvents.accounts()
        }
    }

    func refreshPermissions() {
        refreshCalendars()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let previouslyGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        if previouslyGranted != accessibilityGranted, settings.shortcut.isModifierOnly, !isBusy { registerShortcut() }
    }

    private func refreshCalendars() {
        calendarGranted = CalendarEvents.isAuthorized
        guard settings.useCalendar, calendarGranted else { calendarAccounts = []; return }
        Task { calendarAccounts = await calendarEvents.accounts() }
    }

    func selectMicrophone(_ choice: AudioInputDevice?) {
        settings.microphone = choice
        recorder.microphone = choice
        saveSettings()
        meetings.useMicrophone(choice)
    }

    func selectNotesModel(_ selection: NotesModelSelection) {
        guard meetings.runs.isEmpty else { return }
        settings.notesSelection = selection
        saveNotesSettings()
        if case .cli(let cli) = selection { Task { await refreshNotesCLIModels(cli) } }
    }

    func selectAskModel(_ selection: NotesModelSelection?) {
        settings.askSelection = selection
        saveNotesSettings()
        if case .cli(let cli) = selection { Task { await refreshNotesCLIModels(cli) } }
    }

    func refreshNotesCLIModels(_ cli: NotesCLI) async {
        guard loadingNotesCatalogs.insert(cli).inserted else { return }
        defer { loadingNotesCatalogs.remove(cli) }
        notesCatalogErrors[cli] = nil
        do {
            let catalog = try await NotesCLICatalog.load(cli)
            try Task.checkCancellation()
            notesCLICatalogs[cli] = catalog
            if settings.cliModel(cli).isEmpty, let defaultID = catalog.defaultID, meetings.runs.isEmpty {
                settings.setCLIModel(defaultID, for: cli)
                saveNotesSettings()
            }
        } catch {
            if !Task.isCancelled { notesCatalogErrors[cli] = error.localizedDescription }
        }
    }

    func saveNotesSettings() {
        meetings.notesSettings = settings
        saveSettings()
    }

    private func refreshMicrophones() {
        microphones = AudioInputs.available()
        automaticMicrophone = AudioInputs.systemDefault()
    }

    func dismissCard() {
        guard !isBusy else { return }
        cancelledRecording = nil
        phase = .idle
    }

    private func abandon(_ failure: DictationFailure) {
        discardRecording()
        fail(failure)
    }

    private func fail(_ failure: DictationFailure) {
        statusMessage = failure.message
        present(.failed(failure), for: 6)
        playFeedback(.attention)
    }

    private func playFeedback(_ cue: DictationSound) {
        feedbackSound?.stop()
        guard settings.soundEffects, meetings.capturingID == nil, let sound = cue.sound else { return }
        sound.volume = 0.6
        sound.play()
        feedbackSound = sound
    }

    /// Shows a capsule card that closes itself unless another phase replaced it first.
    private func present(_ card: RecordingPhase, for seconds: Double) {
        phase = card
        cardDuration = seconds
        cardDeadline = Date().addingTimeInterval(seconds)
        let dismissal = ContinuousClock.now.advanced(by: .seconds(seconds))
        cardDismissal = Task { [weak self] in
            try? await Task.sleep(until: dismissal, tolerance: .zero, clock: .continuous)
            guard !Task.isCancelled, let self, self.phase == card else { return }
            self.dismissCard()
        }
    }
}
