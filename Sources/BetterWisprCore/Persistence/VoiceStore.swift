import Foundation

public struct KnownVoice: Codable, Equatable, Sendable {
    public var name: String
    public var meetingID: UUID
    public var participant: Int
    public var embedding: [Float]

    public init(name: String, meetingID: UUID, participant: Int, embedding: [Float]) {
        self.name = name
        self.meetingID = meetingID
        self.participant = participant
        self.embedding = embedding
    }
}

public struct VoiceStore: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appendingPathComponent("BetterWispr/Voices.json")
    }

    private struct File: Codable {
        var version: Int
        var voices: [KnownVoice]
    }

    public func load() throws -> [KnownVoice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version == 1 else { throw StoreError.unsupportedVersion(file.version) }
        return file.voices
    }

    private func save(_ voices: [KnownVoice]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try JSONEncoder().encode(File(version: 1, voices: voices)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Replaces the voices remembered from one meeting and removes rejected ones, writing only on a change and never over a file that can't be read.
    public func replaceVoices(from meeting: UUID, with voices: [KnownVoice], removing rejected: [KnownVoice] = []) throws {
        let known = try load()
        guard known.filter({ $0.meetingID == meeting }) != voices || known.contains(where: rejected.contains) else { return }
        try save(known.filter { $0.meetingID != meeting && !rejected.contains($0) } + voices)
    }

    /// Deletes every remembered voice, including a file that couldn't be read.
    public func forget() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
