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
/// With a `segment` recognizer it also recognizes each confirmed stretch of at least `minimumSegmentSamples` as the final text for that audio, so stopping only has the rest left.
@MainActor
public final class LiveTranscriber {
    public enum State: Sendable, Equatable { case idle, buffering, running, stopping, stopped }
    public typealias Pass = @MainActor @Sendable ([Float]) async throws -> LivePass
    public typealias Segment = @MainActor @Sendable ([Float]) async throws -> String

    public nonisolated static let sampleRate = 16_000
    /// The preview stops following after ten minutes to bound memory; the dictation itself keeps recording.
    static let maximumSamples = 605 * sampleRate
    nonisolated static let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
    private static let padding = [Float](repeating: 0, count: sampleRate)
    static let minimumSegmentSamples = 4 * sampleRate

    public private(set) var state = State.idle
    public private(set) var transcript = LiveTranscript()
    public private(set) var lastPass: Duration = .zero
    public var onUpdate: (@MainActor (LiveTranscript) -> Void)?
    /// Called with each piece's text once it has been recognized, in order.
    public var onSegment: (@MainActor (String) -> Void)?
    /// Final text for the recording up to `segmentedSamples`, one entry per piece.
    public private(set) var segments: [String] = []
    /// How many 16 kHz samples from the start of the recording `segments` cover; always a cut between words.
    public private(set) var segmentedSamples = 0
    /// Every sample delivered while buffering or running, including those past the buffer limit.
    public private(set) var receivedSamples = 0
    private var segmenting = false
    private var segmentsFailed = false
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
        receivedSamples += chunk.count
        samples += chunk.prefix(Self.maximumSamples - samples.count)
    }

    public func start(pass: @escaping Pass, segment: Segment? = nil) {
        guard state == .buffering else { return }
        state = .running
        loop = Task { @MainActor [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.state == .running else { return }
                await self.runPass(pass)
                if let segment { await self.recognizeConfirmedPiece(segment) }
                guard self.state == .running else { return }
            }
        }
    }

    /// Ends the preview and waits for an in-flight pass, so batch transcription never finds the recognizer busy.
    /// A piece already being recognized finishes, since stopping would otherwise have to recognize that audio again.
    public func stop() async {
        guard state == .buffering || state == .running else { return }
        state = .stopping
        if !segmenting { loop?.cancel() }
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

    /// Recognizes the confirmed audio not yet in `segments`, cut halfway between the last confirmed word and the next one.
    private func recognizeConfirmedPiece(_ segment: Segment) async {
        guard state == .running, !segmentsFailed else { return }
        let gapEnd = max(engine.confirmedEndTime, engine.hypothesisStartTime)
        let cut = min(samples.count, Int((engine.confirmedEndTime + gapEnd) / 2 * Double(Self.sampleRate)))
        guard cut - segmentedSamples >= Self.minimumSegmentSamples else { return }
        segmenting = true
        defer { segmenting = false }
        do {
            let text = try await segment(Array(samples[segmentedSamples..<cut]))
            guard state == .running || state == .stopping else { return }
            segments.append(text)
            segmentedSamples = cut
            onSegment?(text)
        } catch {
            // Stopping recognizes everything from `segmentedSamples` on, so a failed piece only stops further pieces.
            segmentsFailed = true
        }
    }
}

/// Joins the pieces recognized while recording with the rest of the recording recognized when it stops.
public enum StreamedDictation {
    /// The recorded file's samples after the recognized pieces, or nil when the file doesn't line up with the live samples and must be recognized whole.
    public static func remainder(of file: [Float], segmentedSamples: Int, receivedSamples: Int) -> [Float]? {
        guard segmentedSamples > 0, segmentedSamples <= file.count,
              abs(file.count - receivedSamples) <= LiveTranscriber.sampleRate / 2 else { return nil }
        let rest = file[segmentedSamples...]
        return Array(rest) + [Float](repeating: 0, count: max(0, LiveTranscriber.minimumSamples - rest.count))
    }

    /// Edits `whole` piece by piece when `editsSeparately` allows, reusing edits started while recording, then lays the joined edit out once;
    /// otherwise edits it in one call. With no edit started ahead, splitting only adds calls, since the on-device model answers one request at a time.
    /// Piece edits must skip list layout, since a list may span pieces. Nil when no edit succeeded.
    @MainActor
    public static func edit(_ whole: String, pieces: [String], ahead: [String: Task<String?, Never>],
                            editingPiece: (String) async -> String?, editingWhole: (String) async -> String?,
                            layingOut: (String) async -> String) async -> (text: String?, reused: Int) {
        guard pieces.contains(where: { ahead[$0] != nil }), editsSeparately(pieces, whole: whole) else { return (await editingWhole(whole), 0) }
        var parts: [String] = []
        var reused = 0
        var succeeded = false
        for piece in pieces {
            let edited: String?
            if let task = ahead[piece] {
                reused += 1
                edited = await task.value
            } else {
                edited = await editingPiece(piece)
            }
            parts.append(edited ?? piece)
            succeeded = succeeded || edited != nil
        }
        guard succeeded else { return (nil, reused) }
        return (await layingOut(parts.joined(separator: " ")), reused)
    }

    static let correctionCues = ["actually", "wait", "sorry", "scratch that", "i mean", "no", "never mind"]

    /// Whether each piece can be edited on its own: together they read as `whole` on one line,
    /// and no piece after the first opens with a self-correction that may revise the one before.
    // ponytail: a cue at the start of a piece is the only cross-piece correction caught; a correction later in the piece that reaches back is edited without the earlier piece.
    public static func editsSeparately(_ pieces: [String], whole: String) -> Bool {
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        guard pieces.count > 1, words(pieces.joined(separator: " ")) == words(whole), !whole.contains(where: \.isNewline) else { return false }
        return !pieces.dropFirst().contains { piece in
            let opening = piece.lowercased().split { !$0.isLetter && $0 != "'" }.prefix(2).joined(separator: " ")
            return correctionCues.contains { opening == $0 || opening.hasPrefix($0 + " ") }
        }
    }
}
