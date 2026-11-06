import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

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

@MainActor
private final class FailingDictation {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let audio: URL
    let model: AppModel
    let store: FailedDictationStore
    var recording: DictationRecording?

    init(duration: TimeInterval = 1) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        audio = folder.appendingPathComponent("betterwispr-test.caf")
        try Data("synthetic audio".utf8).write(to: audio)
        model = AppModel(store: LocalStore(directory: folder), startsServices: false)
        store = FailedDictationStore(directory: folder.appendingPathComponent("Failed Dictations", isDirectory: true))
        let connection = SpeechConnection(api: .smallest)
        model.settings.soundEffects = false
        model.settings.autoPaste = false
        model.settings.copyToClipboard = false
        model.settings.speechConnections = [connection]
        model.settings.selectedModelID = connection.speechModel.id
        recording = DictationRecording(audio: RecordedAudio(url: audio, duration: duration, hasSpeech: true), model: model.selectedModel,
                                       settings: model.settings, vocabulary: [], target: nil)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var hasTemporaryAudio: Bool { FileManager.default.fileExists(atPath: audio.path) }

    func start() throws {
        model.transcribe(try #require(recording))
        recording = nil
    }

    func failToTranscribe() async throws {
        try start()
        try await settle { self.model.failure != nil }
        #expect(model.failure != nil)
    }

    func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@Test @MainActor func failedDictationKeepsOneCopyAcrossRetriesAndSurvivesDismissal() async throws {
    let dictation = try FailingDictation()
    try await dictation.failToTranscribe()
    #expect(dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.count == 1)
    #expect(dictation.hasTemporaryAudio)

    dictation.model.retryFailure()
    try await dictation.settle { dictation.model.canRetryFailure }
    #expect(dictation.model.canRetryFailure)
    #expect(dictation.store.list().count == 1)

    dictation.model.dismissCard()
    try await dictation.settle { !dictation.hasTemporaryAudio }
    #expect(!dictation.hasTemporaryAudio)
    #expect(dictation.store.list().count == 1)
}

@Test @MainActor func deletingAFailedDictationRemovesItsAudioAndItsRetry() async throws {
    let dictation = try FailingDictation()
    try await dictation.failToTranscribe()
    dictation.model.deleteFailedDictation(try #require(dictation.model.failedDictations.first))

    #expect(!dictation.model.canRetryFailure)
    #expect(dictation.store.list().isEmpty && dictation.model.failedDictations.isEmpty)
    try await dictation.settle { !dictation.hasTemporaryAudio }
    #expect(!dictation.hasTemporaryAudio)
}

@Test @MainActor func failedDictationIsOnlyHeldInMemoryWhileHistoryIsOff() async throws {
    let dictation = try FailingDictation()
    dictation.model.settings.saveHistory = false
    try await dictation.failToTranscribe()

    #expect(dictation.model.canRetryFailure && dictation.hasTemporaryAudio)
    #expect(dictation.store.list().isEmpty)

    dictation.model.keepDictationForQuit()
    dictation.model.discardRecording()
    try await dictation.settle { !dictation.hasTemporaryAudio }
    #expect(!dictation.hasTemporaryAudio)
    #expect(dictation.store.list().isEmpty)
}

@Test @MainActor func quittingKeepsATranscribingDictationUnlessHistoryIsOff() async throws {
    let kept = try FailingDictation()
    try kept.start()
    kept.model.keepDictationForQuit()
    kept.model.discardRecording()
    #expect(kept.store.list().count == 1)
    try await kept.settle { !kept.hasTemporaryAudio }
    #expect(!kept.hasTemporaryAudio)

    let off = try FailingDictation()
    off.model.settings.saveHistory = false
    try off.start()
    off.model.keepDictationForQuit()
    off.model.discardRecording()
    #expect(off.store.list().isEmpty)
}

@Test @MainActor func quittingDuringTheUndoWindowDoesNotKeepACancelledDictation() async throws {
    let dictation = try FailingDictation()
    try dictation.start()
    dictation.model.cancelRecording()
    #expect(dictation.model.canUndoCancellation)

    dictation.model.keepDictationForQuit()
    dictation.model.discardRecording()
    #expect(dictation.store.list().isEmpty)
    try await dictation.settle { !dictation.hasTemporaryAudio }
    #expect(!dictation.hasTemporaryAudio)
}

private func sparseFile(at url: URL, bytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: bytes)
    try handle.close()
}

private func seed(_ store: FailedDictationStore, _ name: String, bytes: UInt64 = 4, age: TimeInterval = 0, now: Date = Date()) throws -> URL {
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let url = store.directory.appendingPathComponent(name)
    try sparseFile(at: url, bytes: bytes)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
}

private func sparseRecording(bytes: UInt64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
    try sparseFile(at: url, bytes: bytes)
    return url
}

private let megabyte: UInt64 = 1_000_000

@Test func byteCapEvictsTheOldestFirst() throws {
    let store = temporaryStore()
    let now = Date()
    let oldest = try seed(store, "oldest.caf", bytes: 400 * megabyte, age: 300, now: now)
    let older = try seed(store, "older.caf", bytes: 400 * megabyte, age: 200, now: now)
    let newer = try seed(store, "newer.caf", bytes: 400 * megabyte, age: 100, now: now)

    store.prune(now: now)

    #expect(store.list().map(\.url) == [newer, older])
    #expect(!FileManager.default.fileExists(atPath: oldest.path))
}

@Test func byteCapDeletesEverythingOlderOnceItIsExceeded() throws {
    let store = temporaryStore()
    let now = Date()
    let tiny = try seed(store, "tiny.caf", age: 300, now: now)
    _ = try seed(store, "large.caf", bytes: 700 * megabyte, age: 200, now: now)
    let newest = try seed(store, "newest.caf", bytes: 700 * megabyte, age: 100, now: now)

    store.prune(now: now)

    #expect(store.list().map(\.url) == [newest])
    #expect(!FileManager.default.fileExists(atPath: tiny.path))
}

@Test func aClipLargerThanTheByteCapIsKeptAndOutlivesLaterPrunes() throws {
    let store = temporaryStore()
    let now = Date()
    let older = try seed(store, "older.caf", age: 100, now: now)
    let source = try sparseRecording(bytes: 1_500 * megabyte)
    defer { try? FileManager.default.removeItem(at: source) }

    let kept = try store.keep(source, now: now)

    #expect(store.list().map(\.url) == [kept])
    #expect(store.list().first?.bytes == Int64(1_500 * megabyte))
    #expect(!FileManager.default.fileExists(atPath: older.path))

    store.prune(now: now)
    #expect(store.list().map(\.url) == [kept])
}

@Test func theClipThatJustFailedIsNeverEvictedEvenWhenTheClockMovedBack() throws {
    let store = temporaryStore()
    let now = Date()
    let later = try seed(store, "later.caf", bytes: 700 * megabyte, age: -3600, now: now)
    let source = try sparseRecording(bytes: 700 * megabyte)
    defer { try? FileManager.default.removeItem(at: source) }

    let kept = try store.keep(source, now: now)

    #expect(store.list().map(\.url) == [kept])
    #expect(!FileManager.default.fileExists(atPath: later.path))
}

@Test func theFolderIsExcludedFromBackups() throws {
    let kept = temporaryStore()
    try kept.keep(try recording())
    let keptValues = try URL(fileURLWithPath: kept.directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(keptValues.isExcludedFromBackup == true)

    let seeded = temporaryStore()
    _ = try seed(seeded, "seeded.caf")
    let before = try URL(fileURLWithPath: seeded.directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(before.isExcludedFromBackup != true)
    seeded.prune()
    let after = try URL(fileURLWithPath: seeded.directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(after.isExcludedFromBackup == true)
}

@Test func removeAllLeavesSubfoldersAndOutsideFilesAlone() throws {
    let store = temporaryStore()
    let kept = try seed(store, "kept.caf")
    let subfolder = store.directory.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    let nested = subfolder.appendingPathComponent("nested.caf")
    try Data("nested".utf8).write(to: nested)
    let outside = try recording()
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("link.wav"), withDestinationURL: outside)

    store.removeAll()

    #expect(!FileManager.default.fileExists(atPath: kept.path))
    #expect(FileManager.default.fileExists(atPath: nested.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test @MainActor func turningSaveHistoryOffDeletesKeptAudioButKeepsTryAgain() async throws {
    let dictation = try FailingDictation()
    try await dictation.failToTranscribe()
    #expect(dictation.store.list().count == 1)
    let workspace = dictation.folder.appendingPathComponent("outside.caf")
    try Data("outside".utf8).write(to: workspace)

    dictation.model.settings.saveHistory = false
    dictation.model.saveSettings()

    #expect(dictation.store.list().isEmpty && dictation.model.failedDictations.isEmpty)
    #expect(FileManager.default.fileExists(atPath: workspace.path))
    #expect(dictation.model.canRetryFailure && dictation.hasTemporaryAudio)

    dictation.model.settings.saveHistory = true
    dictation.model.retryFailure()
    dictation.model.keepDictationForQuit()
    dictation.model.discardRecording()
    #expect(dictation.store.list().count == 1)
}

@Test @MainActor func keptAudioIsDeletedAtLaunchWhenSaveHistoryIsOff() throws {
    let dictation = try FailingDictation()
    dictation.model.settings.saveHistory = false
    dictation.model.saveSettings()
    _ = try seed(dictation.store, "left over.caf")

    let relaunched = AppModel(store: LocalStore(directory: dictation.folder), startsServices: false)

    #expect(relaunched.failedDictations.isEmpty)
    #expect(dictation.store.list().isEmpty)
}

@Test @MainActor func anUnreadableWorkspaceDeletesNoKeptAudio() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = FailedDictationStore(directory: folder.appendingPathComponent("Failed Dictations", isDirectory: true))
    let clip = try seed(store, "clip.caf")
    try Data("not json".utf8).write(to: folder.appendingPathComponent("workspace.json"))

    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)

    #expect(model.failedDictations.map(\.url) == [clip])
}

@Test @MainActor func keptAudioFollowsAShorterKeepHistoryOnceTheClockIsTrusted() throws {
    let dictation = try FailingDictation()
    let day: TimeInterval = 86_400
    let fourDays = try seed(dictation.store, "four days.caf", age: 4 * day)
    let oneDay = try seed(dictation.store, "one day.caf", age: day)

    dictation.model.settings.historyClock.lastSeen = Date().addingTimeInterval(-10 * day)
    dictation.model.setHistoryRetention(.threeDays)
    #expect(dictation.store.list().count == 2)

    dictation.model.settings.historyClock = RetentionClock()
    dictation.model.settings.historyRetention = .forever
    dictation.model.setHistoryRetention(.threeDays)
    #expect(dictation.model.failedDictations.map(\.url) == [oneDay])
    #expect(!FileManager.default.fileExists(atPath: fourDays.path))
}

@Test func keepHistoryWithoutAnAgeLimitLeavesKeptAudioToTheWeekLimit() throws {
    let store = temporaryStore()
    let now = Date()
    let day: TimeInterval = 86_400
    let sixDays = try seed(store, "six days.caf", age: 6 * day, now: now)
    _ = try seed(store, "eight days.caf", age: 8 * day, now: now)

    #expect(HistoryRetention.forever.cutoff(now: now) == nil)
    #expect(HistoryRetention.latest100.cutoff(now: now) == nil)
    store.prune(now: now, notBefore: HistoryRetention.latest100.cutoff(now: now))

    #expect(store.list().map(\.url) == [sixDays])
}

@Test func recordingActionsNameWhereAudioIsSent() throws {
    let onDevice = (title: "Transcribe", help: "Stays here")
    let local = try #require(SpeechModel.catalog.first { $0.processingLocation.isOnDevice })
    #expect(local.audioDestination == nil)
    #expect(local.recordingAction(onDevice: onDevice).title == "Transcribe")
    #expect(local.recordingAction(onDevice: onDevice).help == "Stays here")

    var connection = SpeechConnection(api: .smallest)
    connection.name = "Work speech"
    connection.endpoint = "https://speech.example.test/v1"
    let api = connection.speechModel.recordingAction(onDevice: onDevice)
    #expect(api.title == "Send to Work speech")
    #expect(api.help == "Sends this recording to https://speech.example.test/v1")

    #expect(SpeechModel.codex.recordingAction(onDevice: onDevice).title == "Send to ChatGPT")
}

@Test @MainActor func aLateRetryResultChangesNothingAfterTheSessionMovedOn() async throws {
    let dictation = try FailingDictation()
    try await dictation.failToTranscribe()
    let kept = try #require(dictation.model.failedDictations.first)

    dictation.model.retryFailure()
    #expect(dictation.model.phase == .transcribing)
    dictation.model.cancelRecording()
    #expect(dictation.model.canUndoCancellation)
    try await Task.sleep(for: .milliseconds(200))

    #expect(dictation.model.failure == nil)
    #expect(!dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations == [kept])
    dictation.model.discardRecording()
}

private let longDictation = DictationLimits.confirmationDuration + 60

@Test @MainActor func aLongRecordingAsksBeforeItLeavesTheMacAndNoKeepsIt() async throws {
    let dictation = try FailingDictation(duration: longDictation)
    let selected = dictation.model.selectedModel
    try dictation.start()
    #expect(dictation.model.phase == .asking(.send(duration: longDictation, model: selected)))
    #expect(dictation.model.phase.armsCancelShortcut)
    #expect(dictation.model.cardDeadline == nil)
    #expect(dictation.model.failedDictations.isEmpty)

    dictation.model.answerQuestion(false)
    #expect(dictation.model.failure?.title == "Not sent.")
    #expect(dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.count == 1)
    #expect(dictation.hasTemporaryAudio)
    #expect(dictation.model.selectedModel == selected)

    dictation.model.retryFailure()
    #expect(dictation.model.phase == .transcribing)
    try await dictation.settle { dictation.model.failure != nil }
    #expect(dictation.model.failure != nil)
    #expect(dictation.model.failedDictations.count == 1)
    dictation.model.discardRecording()
}

@Test @MainActor func approvingAnUploadTranscribesWithoutAskingAgain() async throws {
    let dictation = try FailingDictation(duration: longDictation)
    try dictation.start()
    dictation.model.answerQuestion(true)
    #expect(dictation.model.phase == .transcribing)
    try await dictation.settle { dictation.model.failure != nil }
    #expect(dictation.model.failure != nil)
    #expect(dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.count == 1)
    dictation.model.discardRecording()
}

@Test @MainActor func dismissingOrDiscardingAnUploadQuestionStillKeepsTheAudio() throws {
    let dismissed = try FailingDictation(duration: longDictation)
    try dismissed.start()
    dismissed.model.dismissCard()
    #expect(dismissed.model.failure?.title == "Not sent.")
    #expect(dismissed.model.failedDictations.count == 1)

    let discarded = try FailingDictation(duration: longDictation)
    try discarded.start()
    discarded.model.discardRecording()
    #expect(discarded.model.phase == .idle)
    #expect(discarded.store.list().count == 1)
    #expect(!discarded.hasTemporaryAudio)
}

@Test @MainActor func quittingWhileAnUploadQuestionIsOpenKeepsExactlyOneCopy() throws {
    let dictation = try FailingDictation(duration: longDictation)
    try dictation.start()
    dictation.model.keepDictationForQuit()
    dictation.model.discardRecording()
    #expect(dictation.store.list().count == 1)

    let privateDictation = try FailingDictation(duration: longDictation)
    privateDictation.model.settings.saveHistory = false
    try privateDictation.start()
    privateDictation.model.keepDictationForQuit()
    privateDictation.model.discardRecording()
    #expect(privateDictation.store.list().isEmpty)
    #expect(!privateDictation.hasTemporaryAudio)
}

@Test @MainActor func shortUploadsAndLongOnDeviceRecordingsDoNotAsk() throws {
    let short = try FailingDictation()
    try short.start()
    #expect(short.model.phase == .transcribing)
    short.model.discardRecording()

    let local = try FailingDictation(duration: longDictation)
    let recording = try #require(local.recording)
    recording.model = try #require(SpeechModel.catalog.first { $0.processingLocation.isOnDevice })
    try local.start()
    #expect(local.model.phase == .transcribing)
    local.model.discardRecording()
}

@MainActor private final class Copies { var count = 0 }

@Test @MainActor func aLongDictationAsksBeforePastingAndNoLeavesItCopied() async throws {
    let dictation = try FailingDictation(duration: longDictation)
    let model = dictation.model
    let copies = Copies()

    let approved = Task { await model.confirmPaste(duration: longDictation, app: "Notes") { copies.count += 1 } }
    try await dictation.settle { model.phase.isAsking }
    #expect(model.phase == .asking(.paste(duration: longDictation, app: "Notes")))
    model.answerQuestion(true)
    #expect(await approved.value)
    #expect(copies.count == 0)
    model.phase = .transcribing

    let refused = Task { await model.confirmPaste(duration: longDictation, app: nil) { copies.count += 1 } }
    try await dictation.settle { model.phase.isAsking }
    model.dismissCard()
    #expect(await !refused.value)
    #expect(copies.count == 1)
    model.phase = .transcribing

    let discarded = Task { await model.confirmPaste(duration: longDictation, app: nil) { copies.count += 1 } }
    try await dictation.settle { model.phase.isAsking }
    model.discardRecording()
    #expect(await !discarded.value)
    #expect(copies.count == 2)
    #expect(model.phase == .idle)
}

@Test func questionsSayWhatWillHappen() throws {
    let connection = SpeechConnection(api: .smallest)
    let send = DictationQuestion.send(duration: 3 * 3600 + 12 * 60, model: connection.speechModel)
    #expect(send.title.contains("3h 12m"))
    #expect(send.approval.hasPrefix("Send to "))
    #expect(send.refusal == "Don’t send")
    let paste = DictationQuestion.paste(duration: 12 * 60, app: nil)
    #expect(paste.title == "Paste this 12m dictation into the focused app?")
    #expect(paste.approval == "Paste")
    #expect(paste.refusal == "Copy instead")
}

@Test @MainActor func anInterruptedRecordingWithSpeechReachesTheKeptAudioPath() throws {
    let dictation = try FailingDictation()
    let audio = RecordedAudio(url: dictation.audio, duration: 40, hasSpeech: true)
    let interruption = RecordingInterruption(audio: audio, cause: AudioRecordingError.inputStalled)
    dictation.model.recordingInterrupted(by: interruption, title: "Couldn’t continue recording.")
    #expect(dictation.model.failure?.title == "Couldn’t continue recording.")
    #expect(dictation.model.failure?.message.hasSuffix("You can try this same recording again.") == true)
    #expect(dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.count == 1)
    #expect(dictation.hasTemporaryAudio)
    dictation.model.discardRecording()
}

@Test @MainActor func anInterruptedRecordingWithoutSpeechIsDeleted() throws {
    let dictation = try FailingDictation()
    dictation.recording = nil
    let copy = dictation.folder.appendingPathComponent("betterwispr-silent.caf")
    try Data("silence".utf8).write(to: copy)
    let audio = RecordedAudio(url: copy, duration: 40, hasSpeech: false)
    dictation.model.recordingInterrupted(by: RecordingInterruption(audio: audio, cause: AudioRecordingError.inputStalled), title: "Couldn’t continue recording.")
    #expect(!dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: copy.path))
    #expect(dictation.model.failure != nil)
}

@Test @MainActor func aPlainCaptureErrorStaysAPlainFailure() throws {
    let dictation = try FailingDictation()
    dictation.model.recordingInterrupted(by: AudioRecordingError.inputStalled, title: "Couldn’t finish recording.")
    #expect(dictation.model.failure?.title == "Couldn’t finish recording.")
    #expect(!dictation.model.canRetryFailure)
    #expect(dictation.model.failedDictations.isEmpty)
}

@Test @MainActor func theHardStopFinishesTheRecordingInsteadOfDroppingIt() async throws {
    let dictation = try FailingDictation()
    dictation.model.phase = .recording
    dictation.model.recordingReachedLimit()
    #expect(dictation.model.phase == .transcribing)
    dictation.model.recordingReachedLimit()
    #expect(dictation.model.phase == .transcribing)
    try await dictation.settle { dictation.model.phase != .transcribing }
    #expect(dictation.model.failure?.title == "Couldn’t finish recording.")
}

@Test @MainActor func remindersNeverInterruptAndFireOncePerHour() throws {
    let dictation = try FailingDictation()
    dictation.model.phase = .recording
    dictation.model.advanceRecording(to: 3599)
    #expect(dictation.model.remindedHour == 0)
    dictation.model.advanceRecording(to: 3 * 3600 + 5)
    #expect(dictation.model.remindedHour == 3)
    dictation.model.advanceRecording(to: 3 * 3600 + 6)
    #expect(dictation.model.remindedHour == 3)
    #expect(dictation.model.recordingDuration == 3 * 3600 + 6)
    #expect(dictation.model.phase == .recording)
    #expect(dictation.model.cardDeadline == nil)
    dictation.model.phase = .idle
}
