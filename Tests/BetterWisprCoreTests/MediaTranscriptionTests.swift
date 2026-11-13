@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

@concurrent private func mediaFile(seconds: Double, silent: [Range<Double>], tone: Bool = true) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-test-\(UUID().uuidString).wav")
    let rate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    for second in 0..<Int(seconds.rounded(.up)) {
        let frames = Int(min(1, seconds - Double(second)) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let time = Double(second) + Double(frame) / rate
            let value: Float = tone && !silent.contains { $0.contains(time) } ? 0.2 * sin(Float(time) * 2 * .pi * 300) : 0
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
    }
    return url
}

private func chunks(of url: URL) async throws -> (audio: MediaAudio, chunks: [MediaChunk]) {
    let audio = try await MediaAudio(url: url)
    var chunks: [MediaChunk] = []
    while let chunk = try await audio.next() { chunks.append(chunk) }
    return (audio, chunks)
}

@Test func mediaCutsAtTheFirstQuietestSmoothedFrameInTheWindow() {
    var gap = [Float](repeating: 1, count: 6_000)
    gap[3_200] = 0
    for frame in 5_000..<5_100 { gap[frame] = 0 }
    #expect(MediaAudio.cut(levels: gap, minimum: 3_000, maximum: 5_950) == 5_015)
    #expect(MediaAudio.cut(levels: [Float](repeating: 1, count: 6_000), minimum: 3_000, maximum: 5_950) == 3_000)
    var outside = [Float](repeating: 1, count: 6_200)
    for frame in Array(1_000..<1_100) + Array(6_000..<6_100) { outside[frame] = 0 }
    #expect(MediaAudio.cut(levels: outside, minimum: 3_000, maximum: 5_950) == 3_000)
    #expect(MediaAudio.cut(levels: [Float](repeating: 1, count: 5_960), minimum: 3_000, maximum: 5_950) == 5_949)
}

@Test func mediaAudioCutsInSilentGapsIntoContiguousChunksThatCoverTheFile() async throws {
    let url = try await mediaFile(seconds: 130, silent: [40..<41, 85..<86])
    defer { try? FileManager.default.removeItem(at: url) }
    let (audio, chunks) = try await chunks(of: url)
    defer { for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) } }

    #expect(abs(audio.duration - 130) < 0.01)
    #expect(chunks.count == 3)
    #expect((40.0...41).contains(chunks[0].start + chunks[0].duration))
    #expect((85.0...86).contains(chunks[1].start + chunks[1].duration))
    #expect(chunks.allSatisfy { $0.duration <= 59.5 })
    #expect(chunks.first?.start == 0)
    #expect(zip(chunks, chunks.dropFirst()).allSatisfy { $0.start + $0.duration == $1.start })
    #expect(abs(chunks.last.map { $0.start + $0.duration - 130 } ?? 130) < 0.01)
    for chunk in chunks {
        let file = try AVAudioFile(forReading: chunk.url)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
        #expect(Double(file.length) == chunk.duration * 16_000)
    }
    #expect(try await audio.next() == nil)
}

@Test func silentMediaStillYieldsChunksAtTheShortestLength() async throws {
    let url = try await mediaFile(seconds: 70, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let (_, chunks) = try await chunks(of: url)
    defer { for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) } }

    #expect(chunks.count == 2)
    #expect(chunks.first?.duration == 30)
    #expect(abs((chunks.last?.duration ?? 0) - 40) < 0.01)
}

@Test func mediaAudioKeepsAtLeastASecondAfterTheLastCut() async throws {
    let url = try await mediaFile(seconds: 59.7, silent: [59.3..<60])
    defer { try? FileManager.default.removeItem(at: url) }
    let (_, chunks) = try await chunks(of: url)
    defer { for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) } }

    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.duration >= 1 })
    #expect(abs(chunks.map(\.duration).reduce(0, +) - 59.7) < 0.01)
}

@Test func mediaAudioRejectsAFileItCannotReadWithTheSupportedFormats() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-test-\(UUID().uuidString).mp3")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: MediaAudioError.unreadable(url.lastPathComponent)) { try await MediaAudio(url: url) }
    #expect(MediaAudioError.unreadable("talk.mkv").localizedDescription.contains("MP3, M4A, AAC, WAV, AIFF, CAF, FLAC, MP4, MOV or M4V"))
}

@MainActor
private final class ScriptedProvider: SpeechProvider {
    var onProgress: (@MainActor @Sendable (Double) -> Void)?
    var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    var replies: [() throws -> String]
    var heard: [(audio: URL, vocabulary: [String])] = []

    init(_ replies: [() throws -> String]) { self.replies = replies }

    func prepare(model: SpeechModel, download: Bool) async throws {}

    func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        heard.append((audioURL, vocabulary))
        return try replies.removeFirst()()
    }

    func cancel() {}
}

@MainActor
@Test func mediaTranscriptionCleansEveryChunkInOrderAndDeletesItsAudio() async throws {
    let url = try await mediaFile(seconds: 100, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let provider = ScriptedProvider([{ "um so the api is ready" }, { "  " }, { "thanks everyone" }])
    var stages: [MediaStage] = []

    let transcript = try await MediaTranscriber.transcribe(url, with: provider, language: "en", vocabulary: [VocabularyEntry(phrase: "api", replacement: "API")],
                                                           findSpeakers: false) {
        stages.append($0)
    }

    #expect(transcript.segments.map(\.text) == ["So the API is ready", "thanks everyone"])
    #expect(transcript.segments.map(\.rawText) == ["um so the api is ready", "thanks everyone"])
    #expect(transcript.segments.map(\.start) == [0, 60])
    #expect(transcript.segments.allSatisfy { $0.speaker == .them && $0.participant == nil })
    #expect(abs(transcript.duration - 100) < 0.01)
    #expect(provider.heard.map(\.vocabulary) == [["API"], ["API"], ["API"]])
    #expect(provider.heard.allSatisfy { !FileManager.default.fileExists(atPath: $0.audio.path) })
    #expect(stages.first == .reading)
    #expect(stages.last.map { if case .transcribing(let done) = $0 { abs(done - 1) < 0.01 } else { false } } == true)
}

@MainActor
@Test func mediaTranscriptionFailsOnAFailedChunkOrCancellationAndLeavesNoAudio() async throws {
    let url = try await mediaFile(seconds: 100, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let failing = ScriptedProvider([{ "hello" }, { throw SpeechError.timedOut }, { "never" }])
    await #expect(throws: SpeechError.self) {
        try await MediaTranscriber.transcribe(url, with: failing, language: "en", vocabulary: [])
    }
    #expect(failing.heard.count == 2)
    #expect(failing.heard.allSatisfy { !FileManager.default.fileExists(atPath: $0.audio.path) })

    let cancelling = ScriptedProvider([{ "hello" }, { withUnsafeCurrentTask { $0?.cancel() }; return "bye" }, { "never" }])
    let job = Task { try await MediaTranscriber.transcribe(url, with: cancelling, language: "en", vocabulary: []) }
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(cancelling.heard.count == 2)
    #expect(cancelling.heard.allSatisfy { !FileManager.default.fileExists(atPath: $0.audio.path) })
}

@MainActor
@Test func transcriptionJobBlocksConnectionEditsSavesItsRecordAndCancelsWithoutOne() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try await mediaFile(seconds: 40, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let renamed = url.deletingLastPathComponent().appending(path: "Quarterly review \(UUID().uuidString.prefix(4)).wav")
    try FileManager.default.moveItem(at: url, to: renamed)
    defer { try? FileManager.default.removeItem(at: renamed) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    let speechModel = try #require(SpeechModel.catalog.first { $0.id == "parakeet-110m" })
    let transcriptions = model.transcriptions

    transcriptions.transcribe(file: renamed, with: speechModel, provider: ScriptedProvider([{ "thanks everyone" }]), language: "en", vocabulary: [])
    #expect(!model.canEditConnections)
    let ignored = ScriptedProvider([{ "never" }])
    transcriptions.transcribe(file: renamed, with: speechModel, provider: ignored, language: "en", vocabulary: [])
    await transcriptions.work?.value

    #expect(transcriptions.job == nil && transcriptions.error == nil && model.canEditConnections)
    #expect(ignored.heard.isEmpty)
    let record = try #require(transcriptions.transcripts.first)
    #expect(transcriptions.transcripts.count == 1)
    #expect(record.title == renamed.deletingPathExtension().lastPathComponent)
    #expect(record.language == "en" && record.modelName == speechModel.name && abs(record.duration - 40) < 0.01)
    #expect(record.segments.map(\.rawText) == ["thanks everyone"])
    #expect(MeetingStore(directory: folder.appending(path: "Transcriptions")).load().meetings.map(\.id) == [record.id])
    #expect(record.transcriptionText == "[00:00] thanks everyone\n")

    transcriptions.transcribe(file: renamed, with: speechModel, provider: ScriptedProvider([{
        transcriptions.cancel()
        return "cancelled words"
    }]), language: "en", vocabulary: [])
    let cancelled = transcriptions.work
    await cancelled?.value

    #expect(transcriptions.job == nil && transcriptions.error == nil && model.canEditConnections)
    #expect(transcriptions.transcripts.map(\.id) == [record.id])
    #expect(MeetingStore(directory: folder.appending(path: "Transcriptions")).load().meetings.count == 1)
}

@MainActor
@Test func transcribedFileReportsSavedOnlyAfterItsTranscriptIsSaved() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try await mediaFile(seconds: 40, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let model = AppModel(store: LocalStore(directory: folder), startsServices: false)
    let speechModel = try #require(SpeechModel.catalog.first { $0.id == "parakeet-110m" })
    let transcriptions = model.transcriptions
    var saved = 0

    transcriptions.transcribe(file: url, with: speechModel, provider: ScriptedProvider([{ "  " }]), language: "en", vocabulary: [], onSaved: { saved += 1 })
    await transcriptions.work?.value
    #expect(saved == 0)

    transcriptions.transcribe(file: url, with: speechModel, provider: ScriptedProvider([{ throw SpeechError.timedOut }]), language: "en", vocabulary: [], onSaved: { saved += 1 })
    await transcriptions.work?.value
    #expect(saved == 0)

    transcriptions.transcribe(file: url, with: speechModel, provider: ScriptedProvider([{ "thanks everyone" }]), language: "en", vocabulary: [], onSaved: { saved += 1 })
    await transcriptions.work?.value
    #expect(saved == 1)
    #expect(MeetingStore(directory: folder.appending(path: "Transcriptions")).load().meetings.count == 1)
}

@Test func transcriptionTextNamesOnlyVoicesSpeakerDetectionFound() {
    var meeting = Meeting(title: "Panel", segments: [
        MeetingSegment(speaker: .them, start: 0, duration: 5, text: "Welcome.", rawText: "welcome", participant: 2),
        MeetingSegment(speaker: .them, start: 65, duration: 5, text: "Thanks.", rawText: "thanks"),
    ], modelName: "Parakeet Ultra", language: "auto")
    meeting.participantNames = [2: "Ada"]

    #expect(meeting.transcriptionText == "[00:00] Ada: Welcome.\n[01:05] Thanks.\n")
    #expect(!meeting.transcriptionMarkdown.contains("Them"))
    #expect(meeting.transcriptionMarkdown.hasPrefix("# Panel\n\n"))
    #expect(meeting.transcriptionMarkdown.contains("**01:05** Thanks."))
}

@MainActor
@Test func mediaTranscriptionHintsLearnedWordsWithoutReplacingThemWhenReplacementIsOff() async throws {
    let url = try await mediaFile(seconds: 10, silent: [], tone: false)
    defer { try? FileManager.default.removeItem(at: url) }
    let learned = [VocabularyEntry(phrase: "cloud", replacement: "Claude", learned: true)]
    var settings = AppSettings()
    settings.replaceLearnedWords = false
    let provider = ScriptedProvider([{ "ask cloud about it" }])

    let transcript = try await MediaTranscriber.transcribe(url, with: provider, language: "en", vocabulary: learned,
                                                           replacements: settings.replacements(learned), findSpeakers: false)

    #expect(transcript.segments.map(\.text) == ["ask cloud about it"])
    #expect(provider.heard.map(\.vocabulary) == [["Claude"]])
}
