import Foundation
@preconcurrency import WhisperKit

public enum SpeechEngine: String, Codable, Sendable {
    case apple, whisperKit, parakeet, api, codex
}

public enum SpeechProcessingLocation: Sendable {
    case onDevice, configuredEndpoint, chatGPT

    public var isOnDevice: Bool { self == .onDevice }

    public var disclosure: String {
        switch self {
        case .onDevice: "On-device transcription"
        case .configuredEndpoint: "Audio sent to your selected endpoint"
        case .chatGPT: "Audio sent to ChatGPT"
        }
    }
}

public struct SpeechModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let sizeLabel: String
    public let engine: SpeechEngine
    public let modelName: String
    public let tokenizerName: String?
    public let connection: SpeechConnection?
    /// Language codes the model recognizes; nil when its coverage is not a known fixed list.
    public let languages: [String]?

    public var processingLocation: SpeechProcessingLocation {
        switch engine {
        case .apple, .whisperKit, .parakeet: .onDevice
        case .api: .configuredEndpoint
        case .codex: .chatGPT
        }
    }

    public var requiresModelDownload: Bool {
        switch engine {
        case .whisperKit, .parakeet: true
        case .apple, .api, .codex: false
        }
    }

    public var supportsSyntheticWarmUp: Bool {
        switch engine {
        case .whisperKit, .parakeet: true
        case .apple, .api, .codex: false
        }
    }

    public var requiresPreparationBeforeRecording: Bool { engine == .apple || !processingLocation.isOnDevice }

    public static let codex = SpeechModel(
        id: "codex", name: "Codex · Subscription",
        detail: "Transcribes with your Codex subscription through an unofficial ChatGPT endpoint. Requires internet access.",
        sizeLabel: "ChatGPT subscription", engine: .codex, modelName: "codex")

    /// Supported languages as sorted display names in the user's locale.
    public var languageNames: [String]? {
        languages?.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.sorted()
    }

    /// The bare code an engine receives for a saved language; Locale would rename Whisper's "jw", "no" and "tl".
    public static func engineLanguage(_ identifier: String?) -> String? {
        identifier.flatMap { $0 == "auto" ? nil : $0.split(whereSeparator: { "-_".contains($0) }).first?.lowercased() }
    }

    public init(id: String, name: String, detail: String, sizeLabel: String, engine: SpeechEngine,
                modelName: String, tokenizerName: String? = nil, connection: SpeechConnection? = nil, languages: [String]? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.sizeLabel = sizeLabel
        self.engine = engine
        self.modelName = modelName
        self.tokenizerName = tokenizerName
        self.connection = connection
        self.languages = languages
    }

    private static let parakeetV3Languages = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
    private static let whisperLargeV3Languages = Set(Constants.languages.values).sorted()
    private static let whisperLanguagesBeforeLargeV3 = whisperLargeV3Languages.filter { $0 != "yue" }

    public static let catalog: [SpeechModel] = [
        .init(id: "apple", name: "Apple on-device", detail: "Uses an available macOS language pack. No cloud fallback.",
              sizeLabel: "System managed", engine: .apple, modelName: "apple"),
        .init(id: "parakeet-ultra", name: "Parakeet Ultra", detail: "Parakeet TDT v3 further trained by Moondream for fewer mistakes, with punctuation, the same 25 European languages and the same speed.",
              sizeLabel: "~730 MB", engine: .parakeet, modelName: "parakeet-ultra", languages: parakeetV3Languages),
        .init(id: "parakeet-v3", name: "Parakeet TDT v3", detail: "NVIDIA's multilingual model for 25 European languages, with punctuation. Fast on the Neural Engine.",
              sizeLabel: "~580 MB", engine: .parakeet, modelName: "parakeet-tdt-0.6b-v3", languages: parakeetV3Languages),
        .init(id: "parakeet-v2", name: "Parakeet TDT v2", detail: "NVIDIA's English-only model, tuned for English accuracy, with punctuation.",
              sizeLabel: "~560 MB", engine: .parakeet, modelName: "parakeet-tdt-0.6b-v2", languages: ["en"]),
        .init(id: "parakeet-110m", name: "Parakeet TDT-CTC 110M", detail: "A small English-only model for Macs with less memory to spare.",
              sizeLabel: "~330 MB", engine: .parakeet, modelName: "parakeet-tdt-ctc-110m", languages: ["en"]),
        .init(id: "parakeet-ja", name: "Parakeet Japanese", detail: "NVIDIA's Parakeet model for Japanese speech.",
              sizeLabel: "~720 MB", engine: .parakeet, modelName: "parakeet-ja", languages: ["ja"]),
        .init(id: "whisper-turbo", name: "Whisper Large v3 Turbo", detail: "Broadest language coverage, including languages Parakeet does not support.",
              sizeLabel: "~1.6 GB", engine: .whisperKit, modelName: "openai_whisper-large-v3-v20240930_turbo", tokenizerName: "openai/whisper-large-v3", languages: whisperLargeV3Languages),
        .init(id: "whisper-turbo-compressed", name: "Whisper Large v3 Turbo (compressed)", detail: "The languages of Whisper Large v3 Turbo in a compressed build that takes less disk space.",
              sizeLabel: "~650 MB", engine: .whisperKit, modelName: "openai_whisper-large-v3-v20240930_turbo_632MB", tokenizerName: "openai/whisper-large-v3", languages: whisperLargeV3Languages),
        .init(id: "whisper-small", name: "Whisper Small", detail: "A lighter multilingual Whisper model with a smaller download.",
              sizeLabel: "~490 MB", engine: .whisperKit, modelName: "openai_whisper-small", tokenizerName: "openai/whisper-small", languages: whisperLanguagesBeforeLargeV3)
    ]
}

@MainActor
public protocol SpeechProvider: AnyObject {
    var onProgress: (@MainActor @Sendable (Double) -> Void)? { get set }
    var onPartialTranscript: (@MainActor @Sendable (String) -> Void)? { get set }
    /// Local providers may download only with `download: true`. External providers only validate here;
    /// explicit selection authorizes network use during transcription, never during preparation.
    func prepare(model: SpeechModel, download: Bool) async throws
    func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String
    /// Also takes names read from the screen, which a provider may use only to respell words that look misspelled, and ignores by default.
    func transcribe(audioURL: URL, language: String?, vocabulary: [String], screenTerms: [String]) async throws -> String
    /// Vocabulary terms the provider itself corrected during the last transcription.
    var vocabularyFixes: Int { get }
    func cancel()
}

extension SpeechProvider {
    public var vocabularyFixes: Int { 0 }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String], screenTerms: [String]) async throws -> String {
        try await transcribe(audioURL: audioURL, language: language, vocabulary: vocabulary)
    }
}

extension SpeechModel {
    @MainActor public func makeProvider() -> any SpeechProvider {
        switch engine {
        case .apple: AppleSpeechProvider()
        case .whisperKit: WhisperKitProvider()
        case .parakeet: ParakeetProvider()
        case .api: APISpeechProvider()
        case .codex: CodexSpeechProvider()
        }
    }
}

public enum SpeechError: LocalizedError, Sendable {
    case modelNotInstalled(String)
    case invalidModel
    case notPrepared
    case busy
    case permissionDenied
    case onDeviceUnavailable(String)
    case timedOut
    case emptyAudio
    case audioUnavailable
    case downloadFailed

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "Download \(name) in Models first. Transcription never downloads files."
        case .invalidModel: "This speech provider cannot load the selected model."
        case .notPrepared: "Prepare a speech model before starting dictation."
        case .busy: "A speech operation is already running."
        case .permissionDenied: "Allow Speech Recognition for BetterWispr in System Settings → Privacy & Security."
        case .onDeviceUnavailable(let locale): "Apple on-device recognition is unavailable for \(locale). Download a model in Models for offline dictation."
        case .timedOut: "On-device speech recognition timed out. Try a shorter recording or a Whisper model."
        case .emptyAudio: "The recording contains no audio."
        case .audioUnavailable: "Select an existing local audio file."
        case .downloadFailed: "Hugging Face didn’t send the model files. Check your internet connection and try again."
        }
    }
}
