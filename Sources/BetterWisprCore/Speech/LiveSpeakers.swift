import Foundation
import SpeakerKit

/// Keeps provisional speaker numbers steady across repeated passes.
public struct ProvisionalSpeakers: Sendable {
    private var numbers: [UUID: Int] = [:]

    public init() {}

    public mutating func number(_ lines: [(segment: UUID, voice: String, length: TimeInterval)]) -> [UUID: Int] {
        var voices = SpeakerDetection.agreedNumbers(lines.compactMap { line in
            numbers[line.segment].map { (voice: line.voice, number: $0, length: line.length) }
        })
        let heard = Set(lines.map(\.segment))
        var taken = Set(numbers.filter { !heard.contains($0.key) }.values).union(voices.values)
        var numbered: [UUID: Int] = [:]
        for line in lines {
            let number = voices[line.voice] ?? (1...).first { !taken.contains($0) }!
            taken.insert(number)
            voices[line.voice] = number
            numbered[line.segment] = number
        }
        numbers.merge(numbered) { $1 }
        return numbered
    }
}

/// Numbers the speakers of call audio while a meeting records.
public actor LiveSpeakerLabeller {
    private let window: TimeInterval
    private var diarizer: SpeakerKitDiarizer?
    private var samples: [Float] = []
    private var placements: [SpeakerRecording.Placement] = []
    private var speakers = ProvisionalSpeakers()
    private var isListening = false
    private static let sampleRate = 16_000.0

    public init(window: TimeInterval = 300) {
        self.window = window
    }

    public func add(_ chunk: URL, for segment: UUID) {
        guard let heard = try? ParakeetProvider.samples(of: chunk), !heard.isEmpty else { return }
        let start = Double(samples.count) / Self.sampleRate
        samples += heard
        placements.append(.init(segment: segment, start: start, end: Double(samples.count) / Self.sampleRate))
        while placements.count > 1, let last = placements.last, last.end > window {
            let dropped = placements.removeFirst().end
            samples.removeFirst(Int(dropped * Self.sampleRate))
            placements = placements.map { .init(segment: $0.segment, start: $0.start - dropped, end: $0.end - dropped) }
        }
    }

    /// The speaker of each line heard lately, or nil while an earlier pass still runs or the voices can't be read.
    public func speakers() async -> [UUID: Int]? {
        guard !isListening, !placements.isEmpty else { return nil }
        isListening = true
        defer { isListening = false }
        let placed = placements
        guard let turns = try? await turns(in: samples) else { return nil }
        let voices = SpeakerDetection.voiceTurns(turns: turns, placements: placed)
        return speakers.number(placed.compactMap { placement in
            voices[placement.segment]?.max { $0.length < $1.length }.map { (placement.segment, $0.voice, $0.length) }
        })
    }

    private func turns(in audio: [Float]) async throws -> [SpeakerSegment] {
        if diarizer == nil { diarizer = try await SpeakerDetection.installedDiarizer(from: SpeakerDetection.directory) }
        let options = PyannoteDiarizationOptions(clusterDistanceThreshold: SpeakerDetection.sameVoiceDistance)
        return try await diarizer?.diarize(audioArray: audio, options: options, progressCallback: nil).segments ?? []
    }
}
