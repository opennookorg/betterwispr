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

private let day: TimeInterval = 86_400

private func observing(_ times: [Date], clock: inout RetentionClock, newest: Date? = nil) -> [Bool] {
    times.map { clock.observe($0, newestDictation: newest) }
}

private let start = Date(timeIntervalSince1970: 1_000_000_000)

@Test func aClockJumpIsNotTrustedUntilItHasHeldForADay() {
    var clock = RetentionClock()
    let jumped = start.addingTimeInterval(366 * day)
    let trust = observing([start, start.addingTimeInterval(day), jumped, jumped.addingTimeInterval(day - 1), jumped.addingTimeInterval(day)], clock: &clock)
    #expect(trust == [true, true, false, false, true])
    #expect(clock.jumpSeen == nil)
}

@Test func aClockThatReturnsSoonIsTrustedAndForgetsTheJump() {
    var clock = RetentionClock()
    let back = start.addingTimeInterval(3_600)
    let trust = observing([start, start.addingTimeInterval(366 * day), back], clock: &clock)
    #expect(trust == [true, false, true])
    #expect(clock.lastSeen == back)
    #expect(clock.jumpSeen == nil)
}

@Test func aClockThatReturnsLateStartsTheHoldAgainFromTheRealDate() {
    var clock = RetentionClock()
    let late = start.addingTimeInterval(5 * day)
    let trust = observing([start, start.addingTimeInterval(366 * day), late, late.addingTimeInterval(day - 1), late.addingTimeInterval(day)], clock: &clock)
    #expect(trust == [true, false, false, false, true])
}

@Test func aClockSetBackIsTrustedAndReplacesAFutureLastSeen() {
    var clock = RetentionClock()
    let earlier = start.addingTimeInterval(-30 * day)
    #expect(observing([start, earlier], clock: &clock) == [true, true])
    #expect(clock.lastSeen == earlier)
}

@Test func theNewestDictationAnchorsAClockThatWasNeverSeen() {
    var fresh = RetentionClock()
    #expect(observing([start.addingTimeInterval(3_600)], clock: &fresh, newest: start) == [true])
    var jumped = RetentionClock()
    #expect(observing([start.addingTimeInterval(2 * day)], clock: &jumped, newest: start) == [false])
}

@Test func anUntrustedClockKeepsAgeLimitsFromDeletingButNotTheCountLimit() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    let history = (0..<120).map { index in
        Transcript(createdAt: now.addingTimeInterval(-Double(index) * day), text: "\(index)", rawText: "\(index)",
                   duration: 1, modelName: "test", language: "en")
    }
    #expect(HistoryRetention.threeDays.kept(history, now: now, clockIsTrusted: false).count == 120)
    #expect(HistoryRetention.threeMonths.kept(history, now: now, clockIsTrusted: false).count == 120)
    #expect(HistoryRetention.latest100.kept(history, now: now, clockIsTrusted: false).count == 100)
}

@MainActor
private func modelWith(_ history: [Transcript], retention: HistoryRetention, saveHistory: Bool = true, lastSeenDaysAgo: Double? = nil) throws -> (AppModel, LocalStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = LocalStore(directory: folder)
    var state = SavedState()
    state.history = history
    state.settings.historyRetention = retention
    state.settings.saveHistory = saveHistory
    if let lastSeenDaysAgo { state.settings.historyClock.lastSeen = .now.addingTimeInterval(-lastSeenDaysAgo * day) }
    try store.save(state)
    return (AppModel(store: store, startsServices: false), store, folder)
}

@Test @MainActor func launchDeletesExpiredDictationsAndSavesTheResult() throws {
    let recent = dictation("recent"), old = dictation("old", daysOld: 5)
    let (model, store, folder) = try modelWith([recent, old], retention: .threeDays)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(model.history == [recent, old])
    model.pruneHistoryAtLaunch()
    #expect(model.history == [recent])
    #expect(try store.load().history == [recent])
}

@Test @MainActor func aClockJumpDeletesNothingAtLaunchOrAfterADictationOrFromThePicker() throws {
    let old = dictation("old", daysOld: 400), yesterdayByTheRealClock = dictation("newest", daysOld: 366)
    let (model, store, folder) = try modelWith([yesterdayByTheRealClock, old], retention: .threeDays, lastSeenDaysAgo: 366)
    defer { try? FileManager.default.removeItem(at: folder) }

    model.pruneHistoryAtLaunch()
    #expect(model.history.count == 2)
    #expect(try store.load().settings.historyClock.jumpSeen != nil)

    let dictatedAhead = dictation("dictated while the clock was ahead")
    try model.addToHistory(dictatedAhead)
    #expect(model.history == [dictatedAhead, yesterdayByTheRealClock, old])
    #expect(try store.load().history.count == 3)

    #expect(model.historyRemoved(by: .twoWeeks) == 0)
    model.setHistoryRetention(.twoWeeks)
    #expect(try store.load().settings.historyRetention == .twoWeeks)
    #expect(try store.load().history.count == 3)
}

@Test @MainActor func aClockThatReturnsAfterAJumpKeepsTheDictationsMadeDuringIt() throws {
    let real = Date.now
    let future = real.addingTimeInterval(366 * day)
    let recent = dictation("recent")
    let stampedAhead = Transcript(createdAt: future, text: "ahead", rawText: "ahead", duration: 1, modelName: "test", language: "en")
    var clock = RetentionClock()
    #expect(observing([real.addingTimeInterval(-3_600), future], clock: &clock) == [true, false])

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    var state = SavedState()
    state.history = [stampedAhead, recent]
    state.settings.historyRetention = .threeDays
    state.settings.historyClock = clock
    try store.save(state)

    let model = AppModel(store: store, startsServices: false)
    model.pruneHistoryAtLaunch()
    #expect(model.history == [stampedAhead, recent])
    let saved = try store.load().settings.historyClock
    #expect(saved.jumpSeen == nil)
    #expect(try #require(saved.lastSeen) < future)
}

@Test @MainActor func saveHistoryOffPausesASavedLimit() throws {
    let old = dictation("old", daysOld: 5)
    let (model, store, folder) = try modelWith([old], retention: .threeDays, saveHistory: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let saved = try Data(contentsOf: store.stateURL)
    model.pruneHistoryAtLaunch()
    #expect(model.history == [old])
    #expect(try Data(contentsOf: store.stateURL) == saved)
}

@Test(arguments: [
    #"{"version":1,"history":["#,
    #"{"version":2,"history":[],"vocabulary":[],"settings":{}}"#,
])
@MainActor func launchLeavesAWorkspaceItCouldNotReadUntouched(contents: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let unreadable = Data(contents.utf8)
    try unreadable.write(to: store.stateURL)
    let model = AppModel(store: store, startsServices: false)
    model.settings.historyRetention = .threeDays
    model.history = [dictation("old", daysOld: 5)]
    model.pruneHistoryAtLaunch()
    #expect(model.history.count == 1)
    #expect(try Data(contentsOf: store.stateURL) == unreadable)
}

@Test @MainActor func aRetentionFromANewerVersionLeavesTheWorkspaceUntouched() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    var state = SavedState()
    state.history = [dictation("old", daysOld: 500)]
    state.settings.historyRetention = .threeDays
    try store.save(state)
    let newer = try #require(String(data: Data(contentsOf: store.stateURL), encoding: .utf8))
        .replacingOccurrences(of: "\"threeDays\"", with: "\"oneYear\"")
    try Data(newer.utf8).write(to: store.stateURL)
    let model = AppModel(store: store, startsServices: false)
    model.pruneHistoryAtLaunch()
    #expect(try String(data: Data(contentsOf: store.stateURL), encoding: .utf8) == newer)
}

@Test func workspaceSavedBeforeTheRetentionClockDecodes() throws {
    var settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
    settings["historyClock"] = nil
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: settings))
    #expect(decoded.historyClock == RetentionClock())
}

@Test func theLaunchToastNamesWhatWentAndTheLimit() {
    #expect(Toast(pruned: 3, by: .threeDays).title == "Deleted 3 dictations older than 3 days")
    #expect(Toast(pruned: 1, by: .twoWeeks).title == "Deleted 1 dictation older than 2 weeks")
    #expect(Toast(pruned: 2, by: .threeMonths).title == "Deleted 2 dictations older than 3 months")
    #expect(Toast(pruned: 7, by: .latest100).title == "Deleted 7 dictations beyond the latest 100")
    #expect(!Toast(pruned: 1, by: .threeDays).isError)
}
