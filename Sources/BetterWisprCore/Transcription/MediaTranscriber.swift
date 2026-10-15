import Foundation

public enum MediaStage: Equatable, Sendable {
    case downloading(Double?)
    case reading
    case transcribing(Double)
    case findingSpeakers
}

public struct MediaTranscript: Sendable {
    public var segments: [MeetingSegment] = []
    public var duration: TimeInterval = 0
    /// Why voices stayed unlabeled although speaker detection is installed.
    public var speakerError: (any Error)?
}

/// Transcribes every chunk of a media file in order with the meeting cleanup and vocabulary, then labels voices when speaker detection is installed.
@MainActor
public enum MediaTranscriber {
    public static func transcribe(_ url: URL, with provider: any SpeechProvider, language: String?, vocabulary: [VocabularyEntry],
                                  findSpeakers: Bool = SpeakerDetection.isInstalled(), progress: (MediaStage) -> Void = { _ in }) async throws -> MediaTranscript {
        progress(.reading)
        let audio = try await MediaAudio(url: url)
        let voices = findSpeakers ? try? SpeakerRecording() : nil
        defer { voices?.discard() }
        func segment(of chunk: URL, start: TimeInterval, duration: TimeInterval) async throws -> MeetingSegment? {
            let raw = try await provider.transcribe(audioURL: chunk, language: language, vocabulary: VocabularyProcessor.hints(vocabulary))
            let text = VocabularyProcessor.apply(vocabulary, to: TranscriptCleaner.clean(raw, language: language))
            return text.isEmpty ? nil : MeetingSegment(speaker: .them, start: start, duration: duration, text: text, rawText: raw)
        }
        var transcript = MediaTranscript()
        progress(.transcribing(0))
        while let chunk = try await audio.next() {
            defer { try? FileManager.default.removeItem(at: chunk.url) }
            if let segment = try await segment(of: chunk.url, start: chunk.start, duration: chunk.duration) {
                transcript.segments.append(segment)
                try? await voices?.append(chunk.url, for: segment.id)
            }
            transcript.duration = chunk.start + chunk.duration
            progress(.transcribing(audio.duration > 0 ? min(1, transcript.duration / audio.duration) : 0))
            try Task.checkCancellation()
        }
        guard let voices, !transcript.segments.isEmpty else { return transcript }
        progress(.findingSpeakers)
        do {
            transcript.segments = try await SpeakerDetection.label(transcript.segments, voices: voices, transcribe: segment).segments
        } catch {
            try Task.checkCancellation()
            transcript.speakerError = error
        }
        return transcript
    }
}
