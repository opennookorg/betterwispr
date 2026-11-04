import Foundation

/// A dictation whose audio was recorded but couldn't be transcribed, kept so it can be transcribed again.
public struct FailedDictation: Identifiable, Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public var id: URL { url }
}

/// Keeps the audio of dictations that failed to transcribe, readable only by this macOS user.
/// It holds at most `limit` recordings and none older than `maximumAge`; the oldest go first.
public struct FailedDictationStore: Sendable {
    public static let limit = 20
    public static let maximumAge: TimeInterval = 7 * 24 * 3600

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory
            .appendingPathComponent("BetterWispr/Failed Dictations", isDirectory: true)
    }

    /// Copies the recording in and returns where it was kept, then removes the oldest beyond the limits.
    @discardableResult
    public func keep(_ audio: URL, now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = audio.pathExtension.isEmpty ? "wav" : audio.pathExtension
        var url = directory.appendingPathComponent("Dictation \(formatter.string(from: now)).\(ext)")
        var suffix = 2
        while manager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("Dictation \(formatter.string(from: now)) \(suffix).\(ext)")
            suffix += 1
        }
        try manager.copyItem(at: audio, to: url)
        try manager.setAttributes([.posixPermissions: 0o600, .creationDate: now, .modificationDate: now], ofItemAtPath: url.path)
        prune(now: now)
        return url
    }

    /// The kept recordings, newest first.
    public func list() -> [FailedDictation] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            // Named under `directory` as given, so it matches what `keep` returned even through /var → /private/var.
            return FailedDictation(url: directory.appendingPathComponent(url.lastPathComponent),
                                   createdAt: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func remove(_ url: URL) {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func prune(now: Date = Date()) {
        for (index, item) in list().enumerated()
        where index >= Self.limit || now.timeIntervalSince(item.createdAt) > Self.maximumAge {
            try? FileManager.default.removeItem(at: item.url)
        }
    }
}
