import Foundation

/// The user's own edits of formatted dictations, kept per kind of app as style references.
public struct StyleExamples: Codable, Equatable, Sendable {
    public static let perCategory = 8
    public static let maximumLength = 600
    public static let inPrompt = 3

    public private(set) var texts: [AppCategory: [String]] = [:]

    public init() {}

    public var count: Int { texts.values.reduce(0) { $0 + $1.count } }

    /// Keeps `text` as the newest example for `category`, replacing `previous` when it is the newest, so later edits of one dictation keep one example.
    public mutating func record(_ text: String, for category: AppCategory, replacing previous: String? = nil) {
        guard let text = Self.kept(text) else { return }
        var examples = texts[category] ?? []
        if let previous = previous.flatMap(Self.kept), examples.last == previous { examples.removeLast() }
        examples.removeAll { $0 == text }
        examples.append(text)
        texts[category] = Array(examples.suffix(Self.perCategory))
    }

    /// The newest examples for `category`, newest first.
    public func recent(for category: AppCategory) -> [String] {
        Array(texts[category, default: []].suffix(Self.inPrompt).reversed())
    }

    private static func kept(_ text: String) -> String? {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct StyleExampleStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    private struct File: Codable {
        var version: Int
        var examples: StyleExamples
    }

    /// Returns no examples when nothing was saved yet; throws for a file it can't read so the caller leaves it alone.
    public func load() throws -> StyleExamples {
        guard FileManager.default.fileExists(atPath: url.path) else { return StyleExamples() }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw StoreError.unsupportedVersion(file.version) }
        return file.examples
    }

    public func save(_ examples: StyleExamples) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: 1, examples: examples)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
