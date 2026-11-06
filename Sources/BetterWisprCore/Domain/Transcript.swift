import Foundation

public struct Transcript: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var rawText: String
    public var duration: TimeInterval
    public var modelName: String
    public var language: String
    /// The app that received the dictation; nil for dictations saved before 0.1.1.
    public var appBundleID: String?
    public var vocabularyFixes: Int?

    public init(id: UUID = UUID(), createdAt: Date = .now, text: String, rawText: String,
                duration: TimeInterval, modelName: String, language: String,
                appBundleID: String? = nil, vocabularyFixes: Int? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.duration = duration
        self.modelName = modelName
        self.language = language
        self.appBundleID = appBundleID
        self.vocabularyFixes = vocabularyFixes
    }

    public var wordCount: Int { TranscriptPolisher.withoutListMarkers(text).split(whereSeparator: \.isWhitespace).count }
}

public struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var phrase: String
    public var replacement: String
    /// True when the entry came from a correction the user made, not typed in Vocabulary.
    public var learned: Bool

    public init(id: UUID = UUID(), phrase: String, replacement: String, learned: Bool = false) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.learned = learned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        phrase = try container.decode(String.self, forKey: .phrase)
        replacement = try container.decode(String.self, forKey: .replacement)
        learned = try container.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }
}
