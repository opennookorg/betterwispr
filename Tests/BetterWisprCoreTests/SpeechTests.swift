@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import BetterWisprCore

@MainActor
@Test(arguments: SpeechModel.catalog + [.codex])
func meetingAndDictationModelsCreateTheMatchingSessionProvider(_ model: SpeechModel) {
    let dictation = model.makeProvider()
    let meeting = model.makeProvider()
    #expect(dictation !== meeting)
    switch model.engine {
    case .apple: #expect(meeting is AppleSpeechProvider)
    case .whisperKit: #expect(meeting is WhisperKitProvider)
    case .parakeet: #expect(meeting is ParakeetProvider)
    case .cohere: #expect(meeting is CohereProvider)
    case .api: #expect(meeting is APISpeechProvider)
    case .codex: #expect(meeting is CodexSpeechProvider)
    }
}

@MainActor
@Test func offlineSpeechRejectsMissingAssets() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "betterwispr-offline-test-\(UUID().uuidString)")
    let model = try #require(SpeechModel.catalog.first { $0.id == "whisper-turbo" })
    let provider = WhisperKitProvider(modelsDirectory: directory)
    #expect(!WhisperKitProvider.isInstalled(model, modelsDirectory: directory))
    do {
        try await provider.prepare(model: model, download: false)
        Issue.record("An absent local model must not be prepared or downloaded")
    } catch SpeechError.modelNotInstalled {
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    #expect(!WhisperKitProvider.containsSignal(in: Array(repeating: 0, count: 32_000)))
    #expect(!WhisperKitProvider.containsSignal(in: [.nan, .infinity]))
    #expect(WhisperKitProvider.containsSignal(in: [0, -0.0001, 0]))
}

@Test func waveformFillsForQuietVoicesAndStaysFlatInSteadyNoise() {
    func amplitude(_ decibels: Float) -> Float { pow(10, decibels / 20) }
    var quietRoom = VoiceLevelMeter()
    let silence = (0..<40).map { _ in quietRoom.update(rms: amplitude(-60), over: 0.1) }
    let quietVoice = (0..<40).map { quietRoom.update(rms: amplitude($0 % 4 == 0 ? -56 : -45), over: 0.1) }
    let pause = (0..<20).map { _ in quietRoom.update(rms: amplitude(-60), over: 0.1) }
    #expect(silence.allSatisfy { $0 < 0.05 })
    #expect(quietVoice.max()! > 0.9)
    #expect(quietVoice.suffix(20).reduce(0, +) / 20 > 0.6)
    #expect(pause.last! < 0.05)

    var noisyRoom = VoiceLevelMeter()
    #expect((0..<200).map { _ in noisyRoom.update(rms: amplitude(-42), over: 0.1) }.allSatisfy { $0 < 0.05 })
    #expect(noisyRoom.update(rms: amplitude(-25), over: 0.1) > 0.5)

    var muted = VoiceLevelMeter()
    #expect([0, .nan, .infinity].map { muted.update(rms: $0, over: 0.1) } == [0, 0, 0])
    #expect(muted.update(rms: amplitude(-35), over: 0.1) > 0.5)
}

@Test func waveformMovesAtTheSameSpeedForAnySliceLength() {
    func amplitude(_ decibels: Float) -> Float { pow(10, decibels / 20) }
    let speech: [Float] = Array(repeating: -60, count: 10) + Array(repeating: -35, count: 3) + Array(repeating: -60, count: 4)
    var buffers = VoiceLevelMeter()
    var slices = VoiceLevelMeter()
    let buffered = speech.map { buffers.update(rms: amplitude($0), over: 0.1) }
    let sliced = speech.map { decibels in (0..<5).map { _ in slices.update(rms: amplitude(decibels), over: 0.02) }.last! }
    #expect(buffered.max()! > 0.9)
    #expect(buffered.last! < 0.05)
    #expect(zip(buffered, sliced).allSatisfy { abs($0 - $1) < 0.03 })
}

private func microphoneTone(_ seconds: Double, rate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / Float(rate)) }
    }
    return buffer
}

@Test func sharedMicrophoneDeliversOnlyActiveAudioAndDetachesRecordersIndependently() throws {
    let delivery = MicrophoneDelivery()
    let buffer = microphoneTone(0.1, rate: 24_000, channels: 1)
    let dictationURL = FileManager.default.temporaryDirectory.appending(path: "betterwispr-shared-\(UUID().uuidString).caf")
    let meetingURL = FileManager.default.temporaryDirectory.appending(path: "betterwispr-shared-\(UUID().uuidString).caf")
    defer {
        try? FileManager.default.removeItem(at: dictationURL)
        try? FileManager.default.removeItem(at: meetingURL)
    }
    let dictation = try RecordingWriter(url: dictationURL, format: buffer.format, threshold: 0.002)
    let meeting = try RecordingWriter(url: meetingURL, format: buffer.format, threshold: 0.002)
    let openerID = UUID(), dictationID = UUID(), meetingID = UUID()
    delivery.add(openerID, since: 9) { _, _ in }
    func deliver(at seconds: Double) {
        delivery.receive(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds)))
    }
    deliver(at: 9)
    delivery.add(dictationID, since: 10.03) { buffer, _ in _ = dictation.write(buffer) }
    delivery.add(meetingID, since: 10.05) { buffer, _ in _ = meeting.write(buffer) }
    deliver(at: 10)
    delivery.remove(dictationID)
    deliver(at: 10.1)
    delivery.remove(meetingID)
    deliver(at: 10.2)
    delivery.remove(openerID)
    let first = dictation.finish(), second = meeting.finish()
    #expect(first.error == nil && second.error == nil)
    #expect(abs(first.duration - 0.07) <= 1.0 / 24_000)
    #expect(abs(second.duration - 0.15) <= 1.0 / 24_000)
}

@Test(arguments: [24_000.0, 48_000.0])
func recordingKeepsItsFileFormatWhenTheMicrophoneChangesFormat(rate: Double) throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-switch-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let headset = AVAudioFormat(standardFormatWithSampleRate: rate, channels: rate == 24_000 ? 1 : 2)!
    let writer = try RecordingWriter(url: url, format: headset, threshold: 0.002)
    let inputs: [(Double, AVAudioChannelCount)] = [(24_000, 1), (48_000, 2), (24_000, 1), (48_000, 2), (44_100, 2), (16_000, 1), (8_000, 1)]
    for (rate, channels) in inputs {
        for _ in 0..<10 { #expect(!writer.write(microphoneTone(0.1, rate: rate, channels: channels)).isEmpty) }
    }
    let result = writer.finish()
    #expect(result.error == nil)
    #expect(abs(result.duration - Double(inputs.count)) < 0.05)
    #expect(result.hasSpeech)
    let file = try AVAudioFile(forReading: url)
    #expect(file.processingFormat == headset)
    #expect(abs(Double(file.length) / rate - Double(inputs.count)) < 0.05)
    let audio = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: audio)
    for second in inputs.indices {
        let middle = Int((Double(second) + 0.5) * rate)
        #expect((middle..<(middle + 100)).contains { abs(audio.floatChannelData![0][$0]) > 0.1 })
    }
    #expect(writer.write(microphoneTone(0.1, rate: rate, channels: headset.channelCount)).isEmpty)
}

@Test func meetingMicrophoneSwitchKeepsChunksAndOffsetsAcrossFormats() throws {
    var chunks: [MeetingAudioChunk] = []
    defer { for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    for (offset, rate, channels) in [(0.0, 48_000.0, 2), (1.3, 24_000.0, 1), (2.6, 44_100.0, 2)] {
        let buffer = microphoneTone(1, rate: rate, channels: AVAudioChannelCount(channels))
        let writer = try MeetingChunkWriter(speaker: .me, format: buffer.format, threshold: 0.002,
                                            policy: ChunkPolicy(), startOffset: offset)
        #expect(writer.write(buffer).rms > 0.1)
        writer.finish()
        let ready = writer.takeReady()
        chunks += ready.chunks
        #expect(ready.error == nil)
        let chunk = try #require(ready.chunks.first)
        #expect(ready.chunks.count == 1)
        #expect(chunk.speaker == .me && chunk.hasSpeech)
        #expect(chunk.start == offset && chunk.duration == 1)
        let file = try AVAudioFile(forReading: chunk.url)
        #expect(file.processingFormat == buffer.format)
        #expect(file.length == AVAudioFramePosition(rate))
        #expect(writer.takeReady().chunks.isEmpty)
    }
}

@Test func meetingChunksStartAtCaptureTimeAndSplitWhenDeliveryPauses() throws {
    let buffer = microphoneTone(1, rate: 48_000, channels: 1)
    let writer = try MeetingChunkWriter(speaker: .them, format: buffer.format, threshold: 0.002,
                                        policy: ChunkPolicy(), startOffset: 0.4)
    for time in [2.0, 3.0, 6.0] { _ = writer.write(buffer, at: time) }
    writer.finish()
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.error == nil)
    #expect(ready.chunks.map { [$0.start, $0.duration] } == [[2, 2], [6, 1]])
    #expect(ready.chunks.allSatisfy { $0.hasSpeech })
}

@Test func mutedMicrophoneDropsAudioAndClosesTheChunkSpokenBefore() throws {
    let buffer = microphoneTone(1, rate: 48_000, channels: 1)
    let writer = try MeetingChunkWriter(speaker: .me, format: buffer.format, threshold: 0.002,
                                        policy: ChunkPolicy(), startOffset: 0)
    _ = writer.write(buffer, at: 2)
    writer.setMuted(true)
    #expect(writer.takeReady().chunks.map { [$0.start, $0.duration] } == [[2, 1]])
    #expect(writer.write(buffer, at: 3).rms == 0)
    writer.setMuted(false)
    _ = writer.write(buffer, at: 4)
    writer.finish()
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.chunks.map { [$0.start, $0.duration] } == [[4, 1]])
}

@Test func mutedMicrophoneKeepsTheGapWhenBuffersHaveNoTime() throws {
    let buffer = microphoneTone(1, rate: 48_000, channels: 1)
    let writer = try MeetingChunkWriter(speaker: .me, format: buffer.format, threshold: 0.002,
                                        policy: ChunkPolicy(), startOffset: 0)
    _ = writer.write(buffer)
    writer.setMuted(true)
    _ = writer.write(buffer)
    writer.setMuted(false)
    _ = writer.write(buffer)
    writer.finish()
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.chunks.map { [$0.start, $0.duration] } == [[0, 1], [2, 1]])
}

@Test func meetingClosesTheOpenChunkOnceSystemAudioStopsArriving() throws {
    let buffer = microphoneTone(1, rate: 48_000, channels: 1)
    let writer = try MeetingChunkWriter(speaker: .them, format: buffer.format, threshold: 0.002,
                                        policy: ChunkPolicy(), startOffset: 0)
    let unstamped = try MeetingChunkWriter(speaker: .them, format: buffer.format, threshold: 0.002,
                                           policy: ChunkPolicy(), startOffset: 0)
    defer {
        writer.cancel()
        unstamped.cancel()
    }
    _ = writer.write(buffer, at: 2)
    _ = unstamped.write(buffer)
    writer.closeIfIdle(at: 3.4)
    unstamped.closeIfIdle(at: 100)
    #expect(writer.takeReady().chunks.isEmpty)
    #expect(unstamped.takeReady().chunks.isEmpty)
    writer.closeIfIdle(at: 3.6)
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.error == nil)
    #expect(ready.chunks.map { [$0.start, $0.duration] } == [[2, 1]])
    #expect(ready.chunks.allSatisfy { $0.hasSpeech })
}

@MainActor
@Test func microphoneReadinessAndFinishWaitForCurrentAudioAndCancelCleanly() async throws {
    let progress = AudioCaptureProgress()
    let old = progress.begin()
    let current = progress.begin()
    var ready = false
    let start = Task { try await progress.wait(); ready = true }
    defer { start.cancel() }
    progress.receive(through: 1, generation: old)
    try await Task.sleep(for: .milliseconds(30))
    #expect(!ready)
    progress.receive(through: 1, generation: current)
    try await start.value
    #expect(ready)

    var finished = false
    let stop = Task { try await progress.wait(through: 2); finished = true }
    defer { stop.cancel() }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!finished)
    progress.receive(through: 2, generation: current)
    try await stop.value
    #expect(finished)

    let cancelled = Task { try await progress.wait(through: 3) }
    progress.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let stalled = AudioCaptureProgress()
    do {
        try await stalled.wait(through: 1)
        Issue.record("A stalled input must time out instead of finalizing incomplete audio")
    } catch AudioRecordingError.inputStalled {}
}

@Test func stopBoundaryArrivesFromTheCaptureThreadWithoutTheMainActor() async throws {
    let progress = AudioCaptureProgress()
    let capture = progress.begin()
    let finishing = Task.detached { try await progress.wait(through: 2) }
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(40)) {
        progress.receive(through: 2, generation: capture)
    }
    try await finishing.value
}

@Test func digitalSilenceRestartsOnlyAnInputThatHasNeverSentSound() {
    var silent = DigitalSilence()
    let silentInput = [([], 5.0), ([0, 0], 1.9), ([0], 0.1)].map { silent.reaches(2, after: $0, over: $1) }
    #expect(silentInput == [false, false, true])

    var quiet = DigitalSilence()
    let quietInput = [([0, 0.00001], 0.1), ([0, 0, 0], 10.0)].map { quiet.reaches(2, after: $0, over: $1) }
    #expect(quietInput == [false, false])
}

@Test(arguments: [0.02, 0.1, 0.5])
func microphoneSpeechGateDoesNotDiluteBriefSpeechAcrossLargeBuffers(bufferSeconds: Double) throws {
    let rate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-gate-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try RecordingWriter(url: url, format: format, threshold: 0.002)
    let meeting = try MeetingChunkWriter(speaker: .me, format: format, threshold: 0.002,
                                        policy: ChunkPolicy(), startOffset: 0)
    defer { meeting.cancel() }
    let framesPerBuffer = Int(bufferSeconds * rate)
    for start in stride(from: 0, to: Int(rate), by: framesPerBuffer) {
        let buffer = microphoneTone(bufferSeconds, rate: rate, channels: 1)
        for frame in 0..<framesPerBuffer {
            let time = Double(start + frame) / rate
            buffer.floatChannelData![0][frame] = (0.04..<0.36).contains(time) ? 0.003 * sin(Float(time) * 2 * .pi * 440) : 0
        }
        _ = writer.write(buffer)
        _ = meeting.write(buffer)
    }
    let result = writer.finish()
    #expect(result.error == nil && result.hasSpeech && result.duration == 1)
    meeting.finish()
    let ready = meeting.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.error == nil)
    #expect(try #require(ready.chunks.first).hasSpeech)
}

@Test func meetingChunksEndAtPausesAboveASteadyNoiseFloorAndSkipNoiseOnlyAudio() throws {
    let rate = 16_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let writer = try MeetingChunkWriter(speaker: .me, format: format, threshold: 0.002, policy: ChunkPolicy(), startOffset: 0)
    defer { writer.cancel() }
    let speech = [1.0..<3, 4..<6]
    let frames = Int(0.1 * rate)
    for start in stride(from: 0, to: Int(10 * rate), by: frames) {
        let buffer = microphoneTone(0.1, rate: rate, channels: 1)
        for frame in 0..<frames {
            let time = Double(start + frame) / rate
            let hum = 0.005 * sin(Float(time) * 2 * .pi * 250)
            buffer.floatChannelData![0][frame] = hum + (speech.contains { $0.contains(time) } ? 0.1 * sin(Float(time) * 2 * .pi * 440) : 0)
        }
        _ = writer.write(buffer)
    }
    writer.finish()
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.error == nil)
    #expect(ready.chunks.map(\.hasSpeech) == [true, true, false, false])
}

@Test func meetingChunksEndAtPausesWhenHeadsetNoiseHasDropouts() throws {
    let rate = 16_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let writer = try MeetingChunkWriter(speaker: .me, format: format, threshold: 0.002, policy: ChunkPolicy(), startOffset: 0)
    defer { writer.cancel() }
    let slice = Int(0.02 * rate)
    let frames = Int(0.1 * rate)
    for start in stride(from: 0, to: Int(10 * rate), by: frames) {
        let buffer = microphoneTone(0.1, rate: rate, channels: 1)
        for frame in 0..<frames {
            let index = start + frame
            let time = Double(index) / rate
            let dropout = (index / slice).isMultiple(of: 10)
            let hiss = 0.004 * sin(Float(time) * 2 * .pi * 250)
            buffer.floatChannelData![0][frame] = dropout ? 0 : hiss + ((1.0..<3).contains(time) ? 0.1 * sin(Float(time) * 2 * .pi * 440) : 0)
        }
        _ = writer.write(buffer)
    }
    writer.finish()
    let ready = writer.takeReady()
    defer { for chunk in ready.chunks { try? FileManager.default.removeItem(at: chunk.url) } }
    #expect(ready.error == nil)
    #expect(ready.chunks.map(\.hasSpeech) == [true, false, false, false])
    #expect(try #require(ready.chunks.first).duration < 4)
}

@MainActor
@Test func microphoneObserverCoalescesChangesAndIgnoresThemAfterCancel() async throws {
    var changes = 0
    let observer = AudioInputObserver { changes += 1 }
    defer { observer.cancel() }
    for _ in 0..<3 {
        observer.scheduleCheck()
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while changes == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(changes == 1)
    observer.scheduleCheck()
    observer.cancel()
    try await Task.sleep(for: .milliseconds(600))
    #expect(changes == 1)
}

@Test func waveformPlaysBufferSlicesAcrossTheirDuration() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    let levels = VoiceLevels(values: [0.2, 0.9, 0.5], start: start, step: 0.02)
    #expect(levels.value(at: start.addingTimeInterval(-1)) == 0.2)
    #expect(levels.value(at: start.addingTimeInterval(0.025)) == 0.9)
    #expect(levels.value(at: start.addingTimeInterval(0.045)) == 0.5)
    #expect(levels.value(at: start.addingTimeInterval(5)) == 0.5)
    #expect(VoiceLevels().value(at: start) == 0)
}

@MainActor
@Test func parakeetRejectsMissingAssetsWithoutDownloading() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "betterwispr-parakeet-test-\(UUID().uuidString)")
    func phraseBoosterFiles() -> Set<String>? {
        (try? FileManager.default.contentsOfDirectory(atPath: ParakeetProvider.phraseBoosterDirectory.path)).map(Set.init)
    }
    let boosterFilesBefore = phraseBoosterFiles()
    for model in SpeechModel.catalog where model.engine == .parakeet {
        #expect(ParakeetProvider.source(for: model)?.repo.folderName == model.modelName)
        #expect(!ParakeetProvider.isInstalled(model, modelsDirectory: directory))
        do {
            try await ParakeetProvider(modelsDirectory: directory).prepare(model: model, download: false)
            Issue.record("An absent local model must not be prepared or downloaded")
        } catch SpeechError.modelNotInstalled {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
    #expect(phraseBoosterFiles() == boosterFilesBefore)
}

@Test func cohereIsListedOnlyWhereItsEncoderLoads() {
    #expect(SpeechModel.catalog.contains { $0.id == "cohere-transcribe" } == CohereProvider.runsOnThisMac)
}

@MainActor
@Test func cohereRejectsMissingAssetsWithoutDownloading() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "betterwispr-cohere-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = SpeechModel.cohereTranscribe
    #expect(!CohereProvider.isInstalled(model, modelsDirectory: directory))
    do {
        try await CohereProvider(modelsDirectory: directory).prepare(model: model, download: false)
        Issue.record("An absent local model must not be prepared or downloaded")
    } catch SpeechError.modelNotInstalled {
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    let folder = CohereProvider.folder(modelsDirectory: directory)
    for file in CohereProvider.requiredFiles {
        try FileManager.default.createDirectory(at: folder.appending(path: file).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: file))
    }
    #expect(!CohereProvider.isInstalled(model, modelsDirectory: directory))
    try Data().write(to: folder.appending(path: ".betterwispr-installed"))
    #expect(CohereProvider.isInstalled(model, modelsDirectory: directory))
}

@Test func cohereReceivesEveryListedLanguageAndFallsBackToTheSystemLanguage() throws {
    let languages = try #require(SpeechModel.cohereTranscribe.languages)
    #expect(Set(languages) == Set(CohereAsrConfig.Language.allCases.map(\.rawValue)))
    for code in languages { #expect(CohereProvider.language(for: code, preferred: []).rawValue == code) }
    #expect(CohereProvider.language(for: "pt-BR", preferred: ["de-DE"]) == .portuguese)
    #expect(CohereProvider.language(for: "auto", preferred: ["sv-SE", "fr-CA"]) == .french)
    #expect(CohereProvider.language(for: nil, preferred: ["ko-KR"]) == .korean)
    #expect(CohereProvider.language(for: "sv", preferred: ["fi"]) == .english)
}

@Test(arguments: ["parakeet-v3", "parakeet-ultra"])
func everyListedParakeetV3LanguageReachesTheDecoderAsAHint(_ id: String) throws {
    let languages = try #require(SpeechModel.catalog.first { $0.id == id }?.languages)
    #expect(languages.count == 25)
    for code in languages { #expect(ParakeetProvider.hint(for: code) != nil, "\(code)") }
    #expect(ParakeetProvider.hint(for: nil) == nil)
}

@Test func everyListedWhisperLanguageReachesTheEngineAsItsOwnToken() throws {
    let languages = try #require(SpeechModel.catalog.first { $0.id == "whisper-turbo" }?.languages)
    for code in languages { #expect(SpeechModel.engineLanguage(code) == code, "\(code)") }
    #expect(SpeechModel.engineLanguage("en-US") == "en")
    #expect(SpeechModel.engineLanguage("zh_Hans") == "zh")
    #expect(SpeechModel.engineLanguage("auto") == nil)
    #expect(SpeechModel.engineLanguage(nil) == nil)
}

@Test func everyDownloadableModelListsItsLanguagesByName() throws {
    for model in SpeechModel.catalog where model.engine != .apple {
        let names = try #require(model.languageNames, "\(model.id)")
        #expect(!names.isEmpty, "\(model.id)")
    }
    let turbo = try #require(SpeechModel.catalog.first { $0.id == "whisper-turbo" }?.languages)
    #expect(turbo.count == 100)
    #expect(turbo.contains("es") && turbo.contains("yue"))
    let small = try #require(SpeechModel.catalog.first { $0.id == "whisper-small" }?.languages)
    #expect(small.contains("es") && !small.contains("yue"))
}

@Test func phraseBoosterCountsAsInstalledOnlyAfterACompletedInstall() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "betterwispr-booster-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(!ParakeetProvider.isPhraseBoosterInstalled(at: directory))

    for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"] {
        try FileManager.default.createDirectory(at: directory.appending(path: bundle), withIntermediateDirectories: true)
    }
    try Data("{}".utf8).write(to: directory.appending(path: "vocab.json"))
    #expect(!ParakeetProvider.isPhraseBoosterInstalled(at: directory))

    try Data().write(to: directory.appending(path: ".betterwispr-installed"))
    #expect(ParakeetProvider.isPhraseBoosterInstalled(at: directory))

    try FileManager.default.removeItem(at: directory.appending(path: "vocab.json"))
    #expect(!ParakeetProvider.isPhraseBoosterInstalled(at: directory))
}

@Test func boostingTermsAreTrimmedDedupedAndCapped() {
    let terms = ParakeetProvider.boostingTerms(["  Kartik ", "ab", "MDX", "kartik", "", "   ", "BetterWispr\n", "KARTIK"])
    #expect(terms == ["Kartik", "MDX", "BetterWispr"])

    let limit = ParakeetProvider.maximumBoostingTerms
    let many = ParakeetProvider.boostingTerms((0..<limit + 5).map { "Term \($0)" })
    #expect(many.count == limit)
    #expect(many.first == "Term 0")
    #expect(many.last == "Term \(limit - 1)")
    #expect(ParakeetProvider.boostingTerms([]).isEmpty)
}

@Test func boostedReplacementsKeepTheOriginalPunctuation() {
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Hey, this is Karthik. Please ping Lubshetvur about it.",
        rescored: "Hey, this is Kartik Please ping Labhshetwar about it.",
        replacements: [(original: "Karthik.", replacement: "Kartik", keepsOriginal: false), (original: "Lubshetvur", replacement: "Labhshetwar", keepsOriginal: false)]
    ) == "Hey, this is Kartik. Please ping Labhshetwar about it.")
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Deploy to (Super base), then ship.",
        rescored: "Deploy to Supabase then ship.",
        replacements: [(original: "(Super base),", replacement: "Supabase", keepsOriginal: false)]
    ) == "Deploy to (Supabase), then ship.")
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Kartik met Karthik.",
        rescored: "Kartik met Kartik",
        replacements: [(original: "Karthik.", replacement: "Kartik", keepsOriginal: false)]
    ) == "Kartik met Kartik.")
    #expect(ParakeetProvider.restoringPunctuation(
        original: "one two three",
        rescored: "four five",
        replacements: []
    ) == "four five")
}

@Test func boostedReplacementsNeverSwallowNeighbouringWords() {
    let widened = (original: "seven Harry Potter", replacement: "Harry Potter")
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Have you seen all the seven Harry Potter movies?",
        rescored: "Have you seen all the Harry Potter movies?",
        replacements: [(original: widened.original, replacement: widened.replacement, keepsOriginal: true)]
    ) == "Have you seen all the seven Harry Potter movies?")
    #expect(ParakeetProvider.alreadySaysTerm(widened))
    #expect(ParakeetProvider.keepsOriginal(widened, spelledCorrectly: false))
    #expect(ParakeetProvider.alreadySaysTerm((original: "GitHub's", replacement: "GitHub")))
    #expect(!ParakeetProvider.alreadySaysTerm((original: "Karthik.", replacement: "Kartik")))
    #expect(!ParakeetProvider.alreadySaysTerm((original: "Next JS", replacement: "NextJS")))
}

@Test func boostedTermsReplaceMisheardSpellingsButNotOtherRealWords() {
    #expect(ParakeetProvider.keepsOriginal((original: "option", replacement: "Notion"), spelledCorrectly: true))
    #expect(ParakeetProvider.keepsOriginal((original: "dinner", replacement: "Disney"), spelledCorrectly: true))
    #expect(ParakeetProvider.keepsOriginal((original: "grand slam", replacement: "Granola"), spelledCorrectly: true))
    #expect(!ParakeetProvider.keepsOriginal((original: "Versal", replacement: "Vercel"), spelledCorrectly: false))
    #expect(!ParakeetProvider.keepsOriginal((original: "Karthik.", replacement: "Kartik"), spelledCorrectly: true))
    #expect(!ParakeetProvider.keepsOriginal((original: "Better Whisper", replacement: "BetterWispr"), spelledCorrectly: true))
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Pick an option, then tell Versal.",
        rescored: "Pick an Notion then tell Vercel",
        replacements: [(original: "option,", replacement: "Notion", keepsOriginal: true), (original: "Versal.", replacement: "Vercel", keepsOriginal: false)]
    ) == "Pick an option, then tell Vercel.")
    #expect(ParakeetProvider.restoringPunctuation(
        original: "Pick an option today.",
        rescored: "Pick Notion today",
        replacements: [(original: "option", replacement: "Notion", keepsOriginal: true)]
    ) == "Pick an option today.")
}

@Test func termsReadFromTheScreenReplaceOnlyMisspelledWords() {
    for spoken in [(original: "prism", replacement: "Prisma"), (original: "Doris", replacement: "Joris"), (original: "whisper kit", replacement: "WhisperKit")] {
        #expect(!ParakeetProvider.keepsOriginal(spoken, spelledCorrectly: true))
        #expect(ParakeetProvider.keepsOriginal(spoken, spelledCorrectly: true, readFromScreen: true))
    }
    #expect(!ParakeetProvider.keepsOriginal((original: "Versal", replacement: "Vercel"), spelledCorrectly: false, readFromScreen: true))
    #expect(!ParakeetProvider.keepsOriginal((original: "Better Wisper", replacement: "BetterWispr"), spelledCorrectly: false, readFromScreen: true))
    #expect(ParakeetProvider.keepsOriginal((original: "Supabase's", replacement: "Supabase"), spelledCorrectly: false, readFromScreen: true))
}

@Test func onlyVocabularyTermsCountAsFixesAndOtherTermsReplaceOnlyMisspelledWords() {
    let judged = ParakeetProvider.judging(
        [(original: "prism", replacement: "Prisma"), (original: "superbase", replacement: "Supabase"),
         (original: "Doris", replacement: "Joris"), (original: "versal", replacement: "Vercel")],
        spelledCorrectly: [true, false, true, false], vocabulary: [" joris", "Vercel"])
    #expect(judged.replacements.map(\.keepsOriginal) == [true, false, false, false])
    #expect(judged.vocabularyFixes == 2)
}

@Test func phraseBoosterDownloadsIntoTheFolderItLoadsFrom() {
    #expect(CtcModelVariant.ctc110m.repo.folderName == ParakeetProvider.phraseBoosterDirectory.lastPathComponent)
}

@Test func parakeetDownloadProgressCountsOnlyTheTransferHalf() {
    #expect(ParakeetProvider.downloadedFraction(DownloadProgress(fractionCompleted: 0.25, phase: .listing)) == 0.5)
    #expect(ParakeetProvider.downloadedFraction(DownloadProgress(fractionCompleted: 0.8, phase: .compiling(modelName: "Encoder"))) == 1)
}

@MainActor
@Test func parallelDownloadsReportOneSizeWeightedFractionThatNeverMovesBack() {
    var reported: [Double] = []
    let shares = DownloadShares(megabytes: [400, 100]) { reported.append($0) }
    shares.update(0, to: 0.5)
    shares.update(0, to: 0.3)
    shares.update(1, to: 1)
    #expect(reported == [0.4, 0.4, 0.6])
    #expect(DownloadShares(megabytes: [100, 0]) { _ in }.total == 0)
}

private enum Downloader { enum DownloadError: Error { case invalidDownloadLocation, unexpectedError } }

@Test func whisperDownloadFailuresWithoutADescriptionBecomeReadable() {
    let failure = WhisperKitProvider.readableDownloadError(Downloader.DownloadError.unexpectedError)
    #expect(failure.localizedDescription == SpeechError.downloadFailed.errorDescription)
    let described: [any Error] = [
        CocoaError(.fileWriteOutOfSpace), URLError(.notConnectedToInternet), CancellationError(), SpeechError.busy,
        NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."]),
    ]
    for error in described {
        #expect(WhisperKitProvider.readableDownloadError(error).localizedDescription == error.localizedDescription)
    }
}
