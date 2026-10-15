@preconcurrency import AVFoundation
import Foundation
import SpeakerKit
import WhisperKit

public enum SpeakerDetection {
    private static let repo = "argmaxinc/speakerkit-coreml"
    private static let revision = "556fc52a13327837688f02289457cded017802e9"
    private static let segmenter = ModelInfo.segmenter(variant: "W32A32")
    private static let embedder = ModelInfo.embedder(variant: "W8A16")
    private static let models = [
        (info: segmenter, files: ["SpeakerSegmenter"]),
        (info: embedder, files: ["SpeakerEmbedderPreprocessor", "SpeakerEmbedder"]),
        (info: ModelInfo.plda(), files: ["PldaProjector"])
    ]

    public static let sameVoiceDistance: Float = 0.6

    public static var directory: URL {
        WhisperKitProvider.defaultModelsDirectory.appending(path: "models/\(repo)", directoryHint: .isDirectory)
    }

    public static func isInstalled(at directory: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: ".betterwispr-installed").path) && models.allSatisfy { model in
            model.files.allSatisfy { FileManager.default.fileExists(atPath: model.info.modelURL(baseURL: directory).appending(path: "\($0).mlmodelc").path) }
        }
    }

    /// Downloads and verifies the pinned models after an explicit installation action, then removes the FluidAudio speaker models they replace.
    public static func install(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let base = WhisperKitProvider.defaultModelsDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let downloader = ModelDownloader(config: ModelDownloadConfig(downloadBase: base.path, modelRepo: repo, revision: revision))
        do {
            _ = try await downloader.resolveRepo(patterns: models.map(\.info.downloadPattern), downloadBase: base, download: true) {
                progress?($0.fractionCompleted)
            }
        } catch {
            throw WhisperKitProvider.readableDownloadError(error)
        }
        try Task.checkCancellation()
        _ = try await installedDiarizer(from: directory)
        try Task.checkCancellation()
        try Data(revision.utf8).write(to: directory.appending(path: ".betterwispr-installed"), options: .atomic)
        let legacy = URL.applicationSupportDirectory.appending(path: "FluidAudio/Models/speaker-diarization", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: legacy.appending(path: ".betterwispr-installed").path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    static func installedDiarizer(from directory: URL) async throws -> SpeakerKitDiarizer {
        let diarizer = SpeakerKitDiarizer.pyannote(
            config: PyannoteConfig(modelFolder: directory.path, download: false, load: false, verbose: false),
            segmenterModelInfo: segmenter, embedderModelInfo: embedder)
        try await diarizer.loadModels()
        return diarizer
    }

    static func abandoningOnCancel<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let (results, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
        Task {
            do {
                continuation.yield(try await work())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        for try await result in results { return result }
        throw CancellationError()
    }

    /// Splits each segment into the voices heard in it, folding any stretch shorter than `shortest` seconds into a neighbour.
    static func voiceTurns(turns: [SpeakerSegment], placements: [SpeakerRecording.Placement], shortest: TimeInterval = 1) -> [UUID: [VoiceTurn]] {
        let turns = turns.compactMap { turn in
            turn.speaker.speakerId.map { VoiceTurn(voice: String($0), start: TimeInterval(turn.startTime), end: TimeInterval(turn.endTime)) }
        }.sorted { $0.start < $1.start }
        var result: [UUID: [VoiceTurn]] = [:]
        for placement in placements {
            var runs: [VoiceTurn] = []
            for turn in turns {
                let start = max(placement.start, turn.start, runs.last?.end ?? 0)
                let end = min(placement.end, turn.end)
                guard end > start else { continue }
                if runs.last?.voice == turn.voice { runs[runs.count - 1].end = end } else { runs.append(VoiceTurn(voice: turn.voice, start: start, end: end)) }
            }
            while runs.count > 1, let index = runs.indices.min(by: { runs[$0].length < runs[$1].length }), runs[index].length < shortest {
                let neighbour = index == 0 ? 1 : index == runs.count - 1 || runs[index - 1].length >= runs[index + 1].length ? index - 1 : index + 1
                runs[neighbour].start = min(runs[neighbour].start, runs[index].start)
                runs[neighbour].end = max(runs[neighbour].end, runs[index].end)
                runs.remove(at: index)
                runs = runs.reduce(into: []) { merged, run in
                    if merged.last?.voice == run.voice { merged[merged.count - 1].end = run.end } else { merged.append(run) }
                }
            }
            guard !runs.isEmpty else { continue }
            result[placement.segment] = runs.indices.map { index in
                let start = index == 0 ? placement.start : (runs[index - 1].end + runs[index].start) / 2
                let end = index == runs.count - 1 ? placement.end : (runs[index].end + runs[index + 1].start) / 2
                return VoiceTurn(voice: runs[index].voice, start: start - placement.start, end: end - placement.start)
            }
        }
        return result
    }

    /// Numbers each segment's voice by first appearance, splitting segments several voices share, with each number's voice embedding; the microphone's most heard voice stays Me.
    @MainActor
    public static func label(_ segments: [MeetingSegment], voices: SpeakerRecording,
                             transcribe: (_ audio: URL, _ start: TimeInterval, _ duration: TimeInterval) async throws -> MeetingSegment?) async throws -> (segments: [MeetingSegment], voices: [Int: [Float]]) {
        let found = try await voices.voiceTurns()
        return try await label(segments, turns: found.turns, embeddings: found.embeddings,
                               audio: { try await voices.audio(of: $0, from: $1.start, to: $1.end) }, transcribe: transcribe)
    }

    @MainActor
    static func label(_ segments: [MeetingSegment], turns: [UUID: [VoiceTurn]], embeddings: [String: [Float]] = [:], audio: (UUID, VoiceTurn) async throws -> URL,
                      transcribe: (_ audio: URL, _ start: TimeInterval, _ duration: TimeInterval) async throws -> MeetingSegment?) async throws -> (segments: [MeetingSegment], voices: [Int: [Float]]) {
        let microphone = Set(MeetingTranscript.removingEchoes(from: segments).filter { $0.speaker == .me }.map(\.id))
        let heard = microphone.compactMap { turns[$0] }.joined().reduce(into: [String: TimeInterval]()) { $0[$1.voice, default: 0] += $1.length }
        let me = heard.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        var labelled: [(segment: MeetingSegment, voice: String?)] = []
        for segment in segments {
            guard segment.speaker == .them || microphone.contains(segment.id),
                  let pieces = turns[segment.id], let longest = pieces.max(by: { $0.length < $1.length }) else {
                labelled.append((segment, nil))
                continue
            }
            var split: [(segment: MeetingSegment, voice: String?)] = []
            for piece in pieces where pieces.count > 1 {
                try Task.checkCancellation()
                do {
                    let url = try await audio(segment.id, piece)
                    defer { try? FileManager.default.removeItem(at: url) }
                    if var transcribed = try await transcribe(url, segment.start + piece.start, piece.length) {
                        transcribed.speaker = segment.speaker
                        split.append((transcribed, piece.voice))
                    }
                } catch {
                    split = []
                    break
                }
            }
            try Task.checkCancellation()
            labelled += split.isEmpty ? [(segment, longest.voice)] : split
        }
        var numbers: [String: Int] = [:]
        let numbered = labelled.map { segment, voice in
            var segment = segment
            if let voice, segment.speaker == .them || voice != me {
                segment.participant = numbers[voice] ?? numbers.count + 1
                numbers[voice] = segment.participant
            }
            return segment
        }
        return (numbered, Dictionary(uniqueKeysWithValues: numbers.compactMap { voice, number in embeddings[voice].map { (number, $0) } }))
    }

    static func recognise(_ voices: [Int: [Float]], among known: [KnownVoice]) -> [Int: KnownVoice] {
        let matches = voices.flatMap { number, embedding in
            known.compactMap { voice in distance(embedding, voice.embedding).map { (number: number, voice: voice, distance: $0) } }
        }
        .filter { $0.distance <= sameVoiceDistance }
        .sorted { ($0.distance, $0.number, $0.voice.name) < ($1.distance, $1.number, $1.voice.name) }
        var recognised: [Int: KnownVoice] = [:]
        var taken: Set<String> = []
        for match in matches where recognised[match.number] == nil && taken.insert(Meeting.nameKey(match.voice.name)).inserted {
            recognised[match.number] = match.voice
        }
        return recognised
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, let a = unit(a), let b = unit(b) else { return nil }
        return zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 && length.isFinite ? vector.map { $0 / length } : nil
    }
}

public struct HeardVoices: Sendable {
    private var embeddings: [Int: [Float]]
    private var suggestions: [Int: KnownVoice]

    public init(_ embeddings: [Int: [Float]], among known: [KnownVoice]) {
        self.embeddings = embeddings
        suggestions = SpeakerDetection.recognise(embeddings, among: known)
    }

    /// The remembered name a speaker sounds like, offered until the user names that speaker.
    public func suggestion(for number: Int, in meeting: Meeting) -> String? {
        Meeting.nameKey(meeting.participantNames?[number] ?? "").isEmpty ? suggestions[number]?.name : nil
    }

    public mutating func drop(_ number: Int) {
        embeddings[number] = nil
        suggestions[number] = nil
    }

    /// Saves each speaker the user named who still has lines.
    public func remember(in meeting: Meeting, to store: VoiceStore) throws {
        try store.replaceVoices(from: meeting.id, with: named(in: meeting))
    }

    /// Forgets and returns the remembered voice behind a speaker's suggestion once the user has named that speaker someone else.
    public mutating func reject(_ number: Int, in meeting: Meeting, from store: VoiceStore) throws -> KnownVoice? {
        let name = Meeting.nameKey(meeting.participantNames?[number] ?? "")
        guard let voice = suggestions[number], !name.isEmpty, name != Meeting.nameKey(voice.name) else { return nil }
        try store.replaceVoices(from: meeting.id, with: named(in: meeting), removing: [voice])
        suggestions[number] = nil
        return voice
    }

    private func named(in meeting: Meeting) -> [KnownVoice] {
        let speaking = Set(meeting.participants)
        return embeddings.sorted { $0.key < $1.key }.compactMap { number, embedding in
            let name = meeting.participantNames?[number]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard speaking.contains(number), !name.isEmpty, Meeting.nameKey(name) != suggestions[number].map({ Meeting.nameKey($0.name) }) else { return nil }
            return KnownVoice(name: name, meetingID: meeting.id, participant: number, embedding: embedding)
        }
    }
}

struct VoiceTurn: Equatable, Sendable {
    var voice: String
    var start: TimeInterval
    var end: TimeInterval

    var length: TimeInterval { end - start }
}

public actor SpeakerRecording {
    struct Placement: Sendable {
        var segment: UUID
        var start: TimeInterval
        var end: TimeInterval
    }

    public nonisolated let url: URL
    private var file: AVAudioFile?
    private var placements: [Placement] = []
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    public init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-meeting-voices-\(UUID().uuidString).caf")
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    public func append(_ chunk: URL, for segment: UUID) throws {
        guard let file else { return }
        let samples = try ParakeetProvider.samples(of: chunk)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let start = Double(file.length) / Self.format.sampleRate
        try file.write(from: buffer)
        placements.append(Placement(segment: segment, start: start, end: Double(file.length) / Self.format.sampleRate))
    }

    func voiceTurns() async throws -> (turns: [UUID: [VoiceTurn]], embeddings: [String: [Float]]) {
        file = nil
        guard !placements.isEmpty else { return ([:], [:]) }
        let audio = try ParakeetProvider.samples(of: url)
        let options = PyannoteDiarizationOptions(clusterDistanceThreshold: SpeakerDetection.sameVoiceDistance)
        let result = try await SpeakerDetection.abandoningOnCancel {
            try await SpeakerDetection.installedDiarizer(from: SpeakerDetection.directory).diarize(audioArray: audio, options: options, progressCallback: nil)
        }
        try Task.checkCancellation()
        let embeddings = Dictionary(uniqueKeysWithValues: result.speakerCentroidEmbeddings.map { (String($0.key), $0.value) })
        return (SpeakerDetection.voiceTurns(turns: result.segments, placements: placements), embeddings)
    }

    func audio(of segment: UUID, from start: TimeInterval, to end: TimeInterval) throws -> URL {
        guard file == nil, let placement = placements.first(where: { $0.segment == segment }) else { throw CocoaError(.fileReadUnknown) }
        let source = try AVAudioFile(forReading: url)
        let first = AVAudioFramePosition((placement.start + start) * Self.format.sampleRate)
        let last = AVAudioFramePosition(min(placement.end, placement.start + end) * Self.format.sampleRate)
        guard last > first, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(last - first)) else {
            throw CocoaError(.fileReadUnknown)
        }
        source.framePosition = first
        try source.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
        let piece = FileManager.default.temporaryDirectory.appending(path: "betterwispr-meeting-\(UUID().uuidString).caf")
        do {
            try AVAudioFile(forWriting: piece, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: piece)
            throw error
        }
        return piece
    }

    public nonisolated func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}
