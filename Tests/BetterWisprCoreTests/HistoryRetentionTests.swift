import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@Test @MainActor func changingHistoryRetentionDeletesAndSavesOlderDictations() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    let old = Transcript(createdAt: .now.addingTimeInterval(-5 * 86_400), text: "old", rawText: "old", duration: 1, modelName: "test", language: "en")
    let recent = Transcript(text: "recent", rawText: "recent", duration: 1, modelName: "test", language: "en")
    model.history = [recent, old]
    #expect(model.historyRemoved(by: .threeDays) == 1)
    model.setHistoryRetention(.threeDays)
    #expect(model.history == [recent])
    let saved = try store.load()
    #expect(saved.history == [recent])
    #expect(saved.settings.historyRetention == .threeDays)
}

private func dictation(_ text: String, daysOld: Double = 0) -> Transcript {
    Transcript(createdAt: .now.addingTimeInterval(-daysOld * 86_400), text: text, rawText: text, duration: 1, modelName: "test", language: "en")
}

private func date(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

@Test @MainActor func aFailedSaveKeepsTheNewDictationAndDeletesNothingUntilTheNextSave() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LocalStore(directory: folder)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }
    let model = AppModel(store: store, startsServices: false)
    let old = dictation("old", daysOld: 5)
    model.history = [old]
    model.settings.historyRetention = .threeDays
    var state = SavedState()
    state.settings = model.settings
    state.history = [old]
    try store.save(state)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)

    let unsaved = dictation("unsaved")
    #expect(throws: (any Error).self) { try model.addToHistory(unsaved) }
    #expect(model.history == [unsaved, old])
    #expect(try store.load().history == [old])

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let next = dictation("next")
    try model.addToHistory(next)
    #expect(model.history == [next, unsaved])
    #expect(try store.load().history == [next, unsaved])
}

@Test @MainActor func anUnreadableWorkspaceIsNeverOverwrittenOrPruned() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let corrupt = Data("{\"version\":1,\"history\":[".utf8)
    try corrupt.write(to: store.stateURL)
    let model = AppModel(store: store, startsServices: false)

    let dictated = dictation("said while unreadable")
    #expect(throws: (any Error).self) { try model.addToHistory(dictated) }
    #expect(model.history == [dictated])
    model.setHistoryRetention(.threeDays)
    #expect(model.settings.historyRetention == .forever)
    #expect(try Data(contentsOf: store.stateURL) == corrupt)
}

@Test func retentionCutoffsFollowTheCalendarAndKeepTheExactBoundary() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = .gmt
    let september = try date("2026-09-01T12:00:00Z")
    func kept(_ retention: HistoryRetention, _ created: Date, now: Date, in calendar: Calendar) -> Bool {
        let transcript = Transcript(createdAt: created, text: "t", rawText: "t", duration: 1, modelName: "test", language: "en")
        return !retention.kept([transcript], now: now, calendar: calendar).isEmpty
    }

    #expect(kept(.threeMonths, try date("2026-06-01T12:00:00Z"), now: september, in: utc))
    #expect(!kept(.threeMonths, try date("2026-06-01T11:59:59Z"), now: september, in: utc))
    #expect(kept(.threeDays, try date("2026-08-29T12:00:00Z"), now: september, in: utc))
    #expect(!kept(.threeDays, try date("2026-08-29T11:59:59Z"), now: september, in: utc))
    #expect(kept(.twoWeeks, try date("2026-08-18T12:00:00Z"), now: september, in: utc))
    #expect(!kept(.twoWeeks, try date("2026-08-18T11:59:59Z"), now: september, in: utc))

    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let afterClocksGoBack = try date("2026-11-02T17:00:00Z")
    #expect(kept(.threeDays, try date("2026-10-30T16:30:00Z"), now: afterClocksGoBack, in: newYork))
}
