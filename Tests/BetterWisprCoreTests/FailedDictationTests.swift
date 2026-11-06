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

    init() throws {
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
        recording = DictationRecording(audio: RecordedAudio(url: audio, duration: 1, hasSpeech: true), model: model.selectedModel,
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
