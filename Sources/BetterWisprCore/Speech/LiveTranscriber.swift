import FluidAudio
import Foundation

/// One recognizer pass over a slice of the live buffer, with timings relative to that slice.
public struct LivePass: Sendable {
    public var words: [TimedWord]
    public var confidence: Float

    public init(words: [TimedWord], confidence: Float) {
        self.words = words
        self.confidence = confidence
    }
}

extension TimedWord {
    /// Merges SentencePiece tokens into words; a token starting with "▁" or a space begins a new word.
    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidences: [Float] = []
        let flush = {
            guard !text.isEmpty else { return }
            words.append(TimedWord(text: text, startTime: start, endTime: end, confidence: confidences.reduce(0, +) / Float(confidences.count)))
        }
        for token in tokens {
            if token.token.hasPrefix("▁") || token.token.hasPrefix(" ") {
                flush()
                text = token.token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "▁", with: "")
                start = token.startTime
                confidences = [token.confidence]
            } else {
                if text.isEmpty { start = token.startTime }
                text += token.token
                confidences.append(token.confidence)
            }
            end = token.endTime
        }
        flush()
        return words
    }
}

/// Previews Parakeet recognition while recording: buffers 16 kHz samples, re-recognizes the unconfirmed tail about once a second and publishes confirmed plus provisional text.
@MainActor
public final class LiveTranscriber {
    public enum State: Sendable, Equatable { case idle, buffering, running, stopping, stopped }
    public typealias Pass = @MainActor @Sendable ([Float]) async throws -> LivePass

    public static let sampleRate = 16_000
    /// The preview stops following after ten minutes to bound memory; the dictation itself keeps recording.
    static let maximumSamples = 605 * sampleRate
    static let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
    private static let padding = [Float](repeating: 0, count: sampleRate)

    public private(set) var state = State.idle
    public private(set) var transcript = LiveTranscript()
    public private(set) var lastPass: Duration = .zero
    public var onUpdate: (@MainActor (LiveTranscript) -> Void)?
    private let interval: Duration
    private var samples: [Float] = []
    private var passedCount = 0
    private var engine = WordAgreementEngine()
    private var loop: Task<Void, Never>?

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    /// Keeps samples from recording start so the first pass covers speech before the recognizer was ready.
    public func beginBuffering() {
        guard state == .idle else { return }
        state = .buffering
    }

    public func append(_ chunk: [Float]) {
        guard state == .buffering || state == .running else { return }
        samples += chunk.prefix(Self.maximumSamples - samples.count)
    }

    public func start(pass: @escaping Pass) {
        guard state == .buffering else { return }
        state = .running
        loop = Task { @MainActor [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.state == .running else { return }
                await self.runPass(pass)
            }
        }
    }

    /// Ends the preview and waits for an in-flight pass, so batch transcription never finds the recognizer busy.
    public func stop() async {
        guard state == .buffering || state == .running else { return }
        state = .stopping
        loop?.cancel()
        await loop?.value
        loop = nil
        state = .stopped
    }

    public func cancel() {
        loop?.cancel()
        loop = nil
        state = .stopped
    }

    private func runPass(_ pass: Pass) async {
        let seek = min(samples.count, Int(engine.seekTime * Double(Self.sampleRate)))
        guard samples.count - seek >= Self.minimumSamples, samples.count - passedCount >= Self.minimumSamples else { return }
        passedCount = samples.count
        let started = ContinuousClock.now
        guard let result = try? await pass(Array(samples[seek...]) + Self.padding) else { return }
        lastPass = ContinuousClock.now - started
        guard state == .running else { return }
        let offset = Double(seek) / Double(Self.sampleRate)
        let words = result.words.map { TimedWord(text: $0.text, startTime: $0.startTime + offset, endTime: $0.endTime + offset, confidence: $0.confidence) }
        transcript = engine.process(words, passConfidence: result.confidence)
        onUpdate?(transcript)
    }
}
