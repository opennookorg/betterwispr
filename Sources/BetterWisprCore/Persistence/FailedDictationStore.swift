import Foundation

/// A dictation whose audio was recorded but couldn't be transcribed, kept so it can be transcribed again.
public struct FailedDictation: Identifiable, Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let bytes: Int64
    public var id: URL { url }
}

/// Keeps the audio of dictations that failed to transcribe, readable only by this macOS user.
/// It holds at most `limit` recordings, `maximumBytes` in total and none older than `maximumAge`; the oldest go first.
/// The folder is left out of backups.
public struct FailedDictationStore: Sendable {
    public static let limit = 20
    public static let maximumAge: TimeInterval = 7 * 24 * 3600
    public static let maximumBytes: Int64 = 1_000_000_000

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
        prune(now: now, sparing: url)
        return url
    }

    /// The kept recordings, newest first.
    public func list() -> [FailedDictation] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return FailedDictation(url: directory.appendingPathComponent(url.lastPathComponent),
                                   createdAt: values.contentModificationDate ?? .distantPast,
                                   bytes: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    public func remove(_ url: URL) {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every kept recording, and nothing else in or outside the folder.
    public func removeAll() {
        for item in list() { remove(item.url) }
    }

    /// Enforces the limits oldest first and marks the folder as excluded from backups; `sparing` and the newest clip survive the byte cap, and `sparing` survives everything.
    public func prune(now: Date = Date(), notBefore: Date? = nil, sparing justFailed: URL? = nil) {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let items = list()
        var total: Int64 = 0
        for (index, item) in (items.filter { $0.url == justFailed } + items.filter { $0.url != justFailed }).enumerated() {
            total += item.bytes
            guard item.url != justFailed else { continue }
            let expired = now.timeIntervalSince(item.createdAt) > Self.maximumAge || notBefore.map { item.createdAt < $0 } == true
            if index >= Self.limit || expired || (index > 0 && total > Self.maximumBytes) {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
    }
}
