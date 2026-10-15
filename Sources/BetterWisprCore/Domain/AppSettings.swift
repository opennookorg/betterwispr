import Foundation

public enum DictationMode: String, Codable, CaseIterable, Sendable {
    case hold, toggle
}

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system, light, cream, dark
}

/// A moment in a dictation that can play a sound.
public enum DictationSound: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case started, finished, cancelled, attention

    public var defaultSoundName: String {
        switch self {
        case .started: "Tink"
        case .finished: "Purr"
        case .cancelled: "Bottle"
        case .attention: "Basso"
        }
    }
}

/// Minutes a loaded speech model may sit unused before the app releases it.
public enum ModelIdleUnload: Int, Codable, CaseIterable, Sendable {
    case never = 0, fiveMinutes = 5, fifteenMinutes = 15, oneHour = 60

    public var delay: Duration? { self == .never ? nil : .seconds(rawValue * 60) }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedModelID: String = "apple"
    public var speechConnections: [SpeechConnection] = []
    public var notesConnections: [SpeechConnection] = []
    public var notesConnectionID: UUID?
    public var notesCLI: NotesCLI?
    public var claudeNotesModel: String = ""
    public var codexNotesModel: String = ""
    public var language: String = "auto"
    /// Nil keeps Chinese in the script the speech model wrote.
    public var chineseScript: ChineseScript?
    /// Languages automatic detection chooses from with a Whisper model; empty allows every language.
    public var dictationLanguages: Set<String> = []
    public var autoPaste: Bool = true
    public var copyToClipboard: Bool = false
    public var saveHistory: Bool = true
    public var showCapsule: Bool = true
    /// Shows Parakeet's provisional words in the capsule while recording.
    public var showLiveText: Bool = true
    public var hideCapsuleWhileDictating: Bool = false
    public var soundEffects: Bool = true
    /// macOS system sound names picked per cue; missing cues use `DictationSound.defaultSoundName`.
    public var sounds: [DictationSound: String] = [:]
    /// Pauses Music and Spotify while the microphone is open, then resumes only what it paused.
    public var pauseMediaWhileDictating: Bool = false
    /// Offers the notetaker when a known call app or web meeting starts recording.
    public var detectMeetings: Bool = true
    /// Names a meeting note after the Calendar event under way when recording starts and lists its invitees.
    public var useCalendar: Bool = false
    /// Calendars, by EventKit calendar identifier, that meeting notes ignore.
    public var excludedCalendarIDs: Set<String> = []
    /// Lets AI apps read saved meetings through `BetterWispr --mcp`.
    public var mcpServer: Bool = false
    public var theme: AppTheme = .dark
    public var launchAtLogin: Bool = false
    public var showInDock: Bool = false
    public var silenceThreshold: Float = 0.002
    public var dictationMode: DictationMode = .hold
    public var unloadModelWhenIdle: ModelIdleUnload = .never
    public var shortcut: DictationShortcut = .optionSpace
    /// Optional extra shortcut that cancels a dictation without pasting it; Escape always cancels.
    public var cancelShortcut: DictationShortcut?
    public var learnCorrections: Bool = true
    public var cleanup: CleanupLevel = .light
    /// Sends selected text, clipboard text and the focused window's text to the notes model during Medium cleanup.
    public var useScreenContext: Bool = false
    /// Reads window text from pixels when the app exposes too little through Accessibility; needs Screen Recording.
    public var recognizeScreenText: Bool = false
    /// Missing contexts use `.formal`, which leaves the transcript as recognized.
    public var styles: [StyleContext: StyleTone] = [:]
    /// Checked in order; see `[WritingMode].match`.
    public var modes: [WritingMode] = []
    /// Nil uses Automatic: the macOS default input, or the built-in mic instead of a Bluetooth headset while the lid is open.
    public var microphone: AudioInputDevice?
    /// The user closed the meeting card that offers the speaker detection download.
    public var dismissedSpeakerDetectionOffer: Bool = false
    public var notesModel: String?
    /// Nil asks questions with the notes model.
    public var askSelection: NotesModelSelection?
    public var notesBuiltIn: Bool = false
    /// The newest onboarding the user finished or skipped; 0 shows it again.
    public var completedOnboardingVersion: Int = 0
    /// The onboarding page to resume after quitting midway.
    public var onboardingStep: Int = 0

    public var notesSelection: NotesModelSelection {
        get {
            if let notesCLI { return .cli(notesCLI) }
            if let notesConnectionID { return .connection(notesConnectionID) }
            return notesModel.map(NotesModelSelection.ollama) ?? (notesBuiltIn ? .builtIn : .apple)
        }
        set {
            notesConnectionID = nil
            notesModel = nil
            notesCLI = nil
            notesBuiltIn = false
            switch newValue {
            case .apple: break
            case .builtIn: notesBuiltIn = true
            case .ollama(let name): notesModel = name
            case .connection(let id): notesConnectionID = id
            case .cli(let cli): notesCLI = cli
            }
        }
    }

    public var askSettings: AppSettings {
        var settings = self
        if let askSelection { settings.notesSelection = askSelection }
        return settings
    }

    public mutating func deselectNotesConnection(_ id: UUID) {
        if notesConnectionID == id { notesSelection = .apple }
        if askSelection == .connection(id) { askSelection = nil }
    }

    public init() {}

    public func tone(for context: StyleContext) -> StyleTone { styles[context] ?? .formal }

    public func soundName(for cue: DictationSound) -> String { sounds[cue] ?? cue.defaultSoundName }

    public func cliModel(_ cli: NotesCLI) -> String { cli == .claudeCode ? claudeNotesModel : codexNotesModel }

    public mutating func setCLIModel(_ model: String, for cli: NotesCLI) {
        if cli == .claudeCode { claudeNotesModel = model } else { codexNotesModel = model }
    }

    public var notesModelName: String {
        switch notesSelection {
        case .apple: "Apple Intelligence"
        case .builtIn: "Built-in · \(BuiltInModel.displayName)"
        case .ollama(let name): "Ollama · \(name)"
        case .connection(let id): notesConnections.first { $0.id == id }.map { "\($0.name) · \($0.modelID)" } ?? "Missing notes connection"
        case .cli(let cli): "\(cli.name) · \(cliModel(cli).isEmpty ? "Choose a model" : cliModel(cli))"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelID = try container.decode(String.self, forKey: .selectedModelID)
        speechConnections = try container.decodeIfPresent([SpeechConnection].self, forKey: .speechConnections) ?? []
        notesConnections = try container.decodeIfPresent([SpeechConnection].self, forKey: .notesConnections) ?? []
        notesConnectionID = try container.decodeIfPresent(UUID.self, forKey: .notesConnectionID)
        notesCLI = try container.decodeIfPresent(NotesCLI.self, forKey: .notesCLI)
        claudeNotesModel = try container.decodeIfPresent(String.self, forKey: .claudeNotesModel) ?? ""
        codexNotesModel = try container.decodeIfPresent(String.self, forKey: .codexNotesModel) ?? ""
        language = try container.decode(String.self, forKey: .language)
        chineseScript = try container.decodeIfPresent(ChineseScript.self, forKey: .chineseScript)
        dictationLanguages = try container.decodeIfPresent(Set<String>.self, forKey: .dictationLanguages) ?? []
        autoPaste = try container.decode(Bool.self, forKey: .autoPaste)
        copyToClipboard = try container.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? false
        saveHistory = try container.decode(Bool.self, forKey: .saveHistory)
        showCapsule = try container.decode(Bool.self, forKey: .showCapsule)
        showLiveText = try container.decodeIfPresent(Bool.self, forKey: .showLiveText) ?? true
        hideCapsuleWhileDictating = try container.decodeIfPresent(Bool.self, forKey: .hideCapsuleWhileDictating) ?? false
        soundEffects = try container.decodeIfPresent(Bool.self, forKey: .soundEffects) ?? true
        sounds = try container.decodeIfPresent([DictationSound: String].self, forKey: .sounds) ?? [:]
        pauseMediaWhileDictating = try container.decodeIfPresent(Bool.self, forKey: .pauseMediaWhileDictating) ?? false
        detectMeetings = try container.decodeIfPresent(Bool.self, forKey: .detectMeetings) ?? true
        useCalendar = try container.decodeIfPresent(Bool.self, forKey: .useCalendar) ?? false
        excludedCalendarIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedCalendarIDs) ?? []
        mcpServer = try container.decodeIfPresent(Bool.self, forKey: .mcpServer) ?? false
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .dark
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        silenceThreshold = try container.decode(Float.self, forKey: .silenceThreshold)
        dictationMode = try container.decodeIfPresent(DictationMode.self, forKey: .dictationMode) ?? .hold
        unloadModelWhenIdle = try container.decodeIfPresent(ModelIdleUnload.self, forKey: .unloadModelWhenIdle) ?? .never
        shortcut = try container.decodeIfPresent(DictationShortcut.self, forKey: .shortcut) ?? .optionSpace
        cancelShortcut = try container.decodeIfPresent(DictationShortcut.self, forKey: .cancelShortcut)
        microphone = try container.decodeIfPresent(AudioInputDevice.self, forKey: .microphone)
        dismissedSpeakerDetectionOffer = try container.decodeIfPresent(Bool.self, forKey: .dismissedSpeakerDetectionOffer) ?? false
        learnCorrections = try container.decodeIfPresent(Bool.self, forKey: .learnCorrections) ?? true
        cleanup = try container.decodeIfPresent(CleanupLevel.self, forKey: .cleanup) ?? .light
        useScreenContext = try container.decodeIfPresent(Bool.self, forKey: .useScreenContext) ?? false
        recognizeScreenText = try container.decodeIfPresent(Bool.self, forKey: .recognizeScreenText) ?? false
        styles = try container.decodeIfPresent([StyleContext: StyleTone].self, forKey: .styles) ?? [:]
        modes = try container.decodeIfPresent([WritingMode].self, forKey: .modes) ?? []
        notesModel = try container.decodeIfPresent(String.self, forKey: .notesModel)
        askSelection = try? container.decodeIfPresent(NotesModelSelection.self, forKey: .askSelection)
        notesBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .notesBuiltIn) ?? false
        completedOnboardingVersion = try container.decodeIfPresent(Int.self, forKey: .completedOnboardingVersion) ?? 0
        onboardingStep = try container.decodeIfPresent(Int.self, forKey: .onboardingStep) ?? 0
    }
}
