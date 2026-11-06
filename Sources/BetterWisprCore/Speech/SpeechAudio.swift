import AVFoundation
import Foundation
@preconcurrency import WhisperKit

enum SpeechAudio {
    /// The stretches of a recording, in seconds, that are uploaded as separate requests.
    @concurrent
    nonisolated static func chunkRanges(_ url: URL, seconds: Double) async throws -> [Range<Double>] {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw SpeechError.audioUnavailable }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw SpeechError.emptyAudio }
        // ponytail: fixed 125 s chunks (25 s for Sarvam) can split a word at each cut; cut at quiet points with MediaAudio.cut if boundary errors matter.
        return stride(from: 0.0, to: duration, by: seconds).map { $0..<min(duration, $0 + seconds) }
    }

    /// Reads one stretch from disk, so a long recording is never held in memory whole.
    @concurrent
    nonisolated static func wavChunk(_ url: URL, _ range: Range<Double>) async throws -> Data {
        try Task.checkCancellation()
        let buffer = try AudioProcessor.loadAudio(fromPath: url.path, startTime: range.lowerBound, endTime: range.upperBound)
        return wav(AudioProcessor.convertBufferToArray(buffer: buffer))
    }

    nonisolated static func wav(_ samples: [Float]) -> Data {
        let pcm = samples.map { sample in
            Int16((min(1, max(-1, sample.isFinite ? sample : 0)) * Float(Int16.max)).rounded()).littleEndian
        }
        let size = UInt32(pcm.count * 2)
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(size + 36)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(size)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
