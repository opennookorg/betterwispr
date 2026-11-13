import Foundation

/// A recognized word with timings relative to the recording start.
public struct TimedWord: Sendable, Equatable {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ";"]

    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float = 1) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    /// Lowercased letters, numbers and spaces only, so punctuation and case never break agreement.
    var normalized: String { Self.normalized(text) }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "-", with: " ").filter { $0.isLetter || $0.isNumber || $0.isWhitespace })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var sentenceEnder: Character? {
        guard let last = text.last, Self.sentenceEnders.contains(last) else { return nil }
        return last
    }
}

/// Preview text while recording: `confirmed` no longer changes, `hypothesis` may still be rewritten.
public struct LiveTranscript: Sendable, Equatable {
    public var confirmed = ""
    public var hypothesis = ""

    public init(confirmed: String = "", hypothesis: String = "") {
        self.confirmed = confirmed
        self.hypothesis = hypothesis
    }

    public var isEmpty: Bool { confirmed.isEmpty && hypothesis.isEmpty }
}

/// Confirms words once several consecutive recognizer passes agree on them, adapted from VoiceInk.
public struct WordAgreementEngine: Sendable {
    static let confirmationsNeeded = 3
    static let minimumWords = 5
    static let minimumPassConfidence: Float = 0.15
    static let minimumWordConfidence: Float = 0.6

    private var confirmed: [TimedWord] = []
    private var previous: [TimedWord] = []
    private var agreements = 0
    private var isFirstPass = true
    public private(set) var confirmedEndTime: TimeInterval = 0
    public private(set) var hypothesisStartTime: TimeInterval = 0

    public init() {}

    /// Confirmed words followed by the latest provisional ones, in spoken order.
    var words: [TimedWord] { confirmed + previous }
    var confirmedCount: Int { confirmed.count }

    /// Where the next pass should start reading audio, in seconds.
    public var seekTime: TimeInterval { hypothesisStartTime > 0 ? hypothesisStartTime : confirmedEndTime }

    public mutating func process(_ words: [TimedWord], passConfidence: Float = 1) -> LiveTranscript {
        guard !words.isEmpty else { return transcript(hypothesis: []) }
        if isFirstPass {
            isFirstPass = false
            previous = words
            return transcript(hypothesis: words)
        }
        if passConfidence < Self.minimumPassConfidence {
            agreements = 0
            previous = words
            return transcript(hypothesis: words)
        }
        let earlier = previous
        let prefix = zip(words, earlier).prefix { $0.normalized == $1.normalized }.count
        previous = words
        guard prefix >= Self.minimumWords else {
            agreements = 0
            return transcript(hypothesis: words)
        }
        agreements += 1
        guard agreements >= Self.confirmationsNeeded,
              let cut = Self.sentenceCut(words.prefix(min(prefix, words.count - 1))),
              words.prefix(cut).map(\.sentenceEnder) == earlier.prefix(cut).map(\.sentenceEnder),
              words.prefix(cut).suffix(3).allSatisfy({ $0.confidence >= Self.minimumWordConfidence })
        else { return transcript(hypothesis: words) }
        let hypothesis = Array(words.dropFirst(cut))
        confirmed += words.prefix(cut)
        confirmedEndTime = words[cut - 1].endTime
        hypothesisStartTime = hypothesis.first?.startTime ?? confirmedEndTime
        agreements = hypothesis.isEmpty ? 0 : 1
        previous = hypothesis
        isFirstPass = hypothesis.isEmpty
        return transcript(hypothesis: hypothesis)
    }

    /// Words to confirm: through the last sentence ender among agreed words that more speech follows, so only the sentence still being spoken stays provisional
    /// and a piece can be recognized and edited while the next sentence is spoken. The pass's final word is excluded, since the end of the audio looks like a sentence end.
    private static func sentenceCut(_ words: ArraySlice<TimedWord>) -> Int? {
        guard let last = words.indices.last(where: { words[$0].sentenceEnder != nil }) else { return nil }
        return last + 1 >= minimumWords ? last + 1 : nil
    }

    private func transcript(hypothesis: [TimedWord]) -> LiveTranscript {
        LiveTranscript(confirmed: confirmed.map(\.text).joined(separator: " "),
                       hypothesis: hypothesis.map(\.text).joined(separator: " "))
    }
}
