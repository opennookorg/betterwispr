import AVFoundation
import Foundation
import Testing
@testable import BetterWispr
@testable import BetterWisprCore

@MainActor
private final class TranslationFlowSpeechProvider: SegmentedSpeechProvider {
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    var fullPassLanguages: [String?] = []
    var finalSegmentLanguages: [String?] = []
    let tail: String
    let whole: String

    init(tail: String, whole: String) {
        self.tail = tail
        self.whole = whole
    }

    func prepare(model: SpeechModel, download: Bool) async throws {}
    func cancel() {}

    func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        fullPassLanguages.append(language)
        return whole
    }

    func transcribe(samples: [Float], language: String?, vocabulary: [String], screenTerms: [String]) async throws -> (text: String, vocabularyFixes: Int) {
        finalSegmentLanguages.append(language)
        return (tail, 0)
    }
}

enum TranslationFlowCase: CaseIterable {
    case liveJoin, fullRecognition, interrupted, quitDuringApproval, cancelAndUndo
}

@Test(arguments: TranslationFlowCase.allCases) @MainActor
func completesOrRecoversTheWholeDictation(flow: TranslationFlowCase) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("test.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
    buffer.frameLength = 32_000
    let channel = try #require(buffer.floatChannelData?[0])
    channel.update(repeating: 0, count: Int(buffer.frameLength))
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    let first = "Le build est prêt."
    let last = "Je partage le lien."
    let complete = first + " " + last
    let joinSucceeds = flow != .fullRecognition
    let speech = TranslationFlowSpeechProvider(tail: joinSucceeds ? last : "Une jonction incorrecte.", whole: complete)
    var requests: [(source: String, target: String)] = []
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false, translateDictation: { source, target, _ in
        requests.append((source, target))
        if flow == .cancelAndUndo, requests.count == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return "The build is ready. I’ll share the link."
    })
    model.settings.language = "fr"
    model.settings.autoPaste = false
    model.settings.copyToClipboard = false
    model.settings.cleanup = .none
    model.settings.soundEffects = false
    model.settings.saveHistory = true
    model.settings.translationSelection = .ollama("test-model")
    let parakeet = try #require(SpeechModel.catalog.first { $0.engine == .parakeet })
    model.selectModel(parakeet, prepared: speech)
    let recording = DictationRecording(audio: RecordedAudio(url: url, duration: 2, hasSpeech: true), model: parakeet,
                                       settings: model.settings, vocabulary: [], target: nil)
    recording.translationLanguage = "en"
    recording.streamed = StreamedPieces(modelID: parakeet.id, language: "fr", pieces: [first],
                                        segmentedSamples: 16_000, receivedSamples: 32_000, wordAfterPieces: "Je",
                                        vocabularyFixes: 0, edits: [:], editSettings: model.settings)

    if flow == .interrupted {
        model.recordingInterrupted(by: RecordingInterruption(audio: recording.audio, cause: AudioRecordingError.inputStalled),
                                   title: "Capture interrupted", translationLanguage: "en")
        try #require(model.canRetryFailure)
        model.retryFailure()
    } else {
        model.transcribe(recording)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !model.phase.isAsking && model.isBusy && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.phase == .asking(.translate(destination: L10n.tr("Ollama (%@)", "test-model"))))
    #expect(requests.isEmpty)
    if flow == .quitDuringApproval {
        model.keepDictationForQuit()
        model.discardRecording()
        #expect(try store.load().history.map(\.text) == [complete])
        #expect(requests.isEmpty)
        return
    }
    model.answerQuestion(true)
    if flow == .cancelAndUndo {
        while requests.isEmpty && (model.phase.isAsking || model.isBusy) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(requests.count == 1)
        model.cancelRecording()
        #expect(model.phase == .cancelled)
        #expect(model.history.isEmpty)
        try #require(model.canUndoCancellation)
        // Cancellation unloads the provider. Reinject the stub before Undo.
        model.selectModel(parakeet, prepared: speech)
        model.undoCancellation()
        while !model.phase.isAsking && model.isBusy && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.phase.isAsking)
        model.answerQuestion(true)
    }
    while (model.phase.isAsking || model.isBusy) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(speech.finalSegmentLanguages == (flow == .interrupted ? [] : ["fr"]))
    let usedFullRecognition = !joinSucceeds || flow == .interrupted || flow == .cancelAndUndo
    #expect(speech.fullPassLanguages == (usedFullRecognition ? ["fr"] : []))
    #expect(requests.count == (flow == .cancelAndUndo ? 2 : 1))
    #expect(requests.allSatisfy { $0.source == complete && $0.target == "en" })
    #expect(model.history.count == 1)
    #expect(model.history.first?.language == "fr")
    #expect(model.history.first?.translation?.sourceText == complete)
    #expect(model.partialTranscript == "The build is ready. I’ll share the link.")
}

@Test @MainActor func choosingACapsuleLanguageRemembersItWithoutEnablingTranslation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    model.settings.language = "fr"
    model.phase = .recording
    defer { model.discardRecording() }

    #expect(model.settings.preferredTranslationLanguage == "en")
    model.chooseRecordingTranslationLanguage("es")
    #expect(model.recordingTranslationLanguage == nil)
    #expect(try store.load().settings.preferredTranslationLanguage == "es")

    model.toggleRecordingTranslation()
    #expect(model.recordingTranslationLanguage == "es")
    model.chooseRecordingTranslationLanguage("it")
    #expect(model.recordingTranslationLanguage == "it")
    model.toggleRecordingTranslation()
    #expect(model.recordingTranslationLanguage == nil)

    let restarted = AppModel(store: store, startsServices: false)
    #expect(restarted.settings.preferredTranslationLanguage == "it")
    #expect(restarted.settings.language == "fr")
    #expect(restarted.nextTranslationLanguage == nil)
    #expect(restarted.recordingTranslationLanguage == nil)
}
