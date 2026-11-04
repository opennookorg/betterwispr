import Foundation
import Testing
@testable import BetterWisprCore

private func temporaryStore() -> FailedDictationStore {
    FailedDictationStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("Failed Dictations"))
}

private func recording(_ bytes: String = "RIFF") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try Data(bytes.utf8).write(to: url)
    return url
}

@Test func failedDictationIsCopiedPrivatelyAndSurvivesTheOriginal() throws {
    let store = temporaryStore()
    let original = try recording("audio")
    let kept = try store.keep(original)
    try FileManager.default.removeItem(at: original)

    #expect(try Data(contentsOf: kept) == Data("audio".utf8))
    #expect(kept.pathExtension == "wav")
    let file = try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int
    let folder = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
    #expect(file == 0o600)
    #expect(folder == 0o700)
    #expect(store.list().map(\.url) == [kept])
}

@Test func failedDictationsKeepTheNewestTwentyWithinAWeek() throws {
    let store = temporaryStore()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var kept: [URL] = []
    for minute in 0..<(FailedDictationStore.limit + 3) {
        kept.append(try store.keep(try recording(), now: start.addingTimeInterval(TimeInterval(minute * 60))))
    }
    let list = store.list()
    #expect(list.count == FailedDictationStore.limit)
    #expect(list.first?.url == kept.last)
    #expect(!list.contains { $0.url == kept[0] })

    store.prune(now: start.addingTimeInterval(FailedDictationStore.maximumAge + 4.5 * 60))
    #expect(store.list().count == FailedDictationStore.limit - 2)
}

@Test func failedDictationsWithTheSameTimeGetDistinctNames() throws {
    let store = temporaryStore()
    let now = Date()
    let first = try store.keep(try recording(), now: now)
    let second = try store.keep(try recording(), now: now)
    #expect(first != second)
    #expect(store.list().count == 2)
}

@Test func removingOnlyDeletesKeptRecordings() throws {
    let store = temporaryStore()
    let kept = try store.keep(try recording())
    let outside = try recording()
    store.remove(outside)
    #expect(FileManager.default.fileExists(atPath: outside.path))
    store.remove(kept)
    #expect(store.list().isEmpty)
}
