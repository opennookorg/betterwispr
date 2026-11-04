import AVFoundation
import Foundation
@preconcurrency import WhisperKit

enum SpeechAudio {
    @concurrent
    nonisolated static func wavChunks(_ url: URL, seconds: Double) async throws -> [Data] {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw SpeechError.audioUnavailable }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw SpeechError.emptyAudio }
        var chunks: [Data] = []
        // ponytail: fixed 125 s chunks (25 s for Sarvam) can split a word at each cut; cut at quiet points with MediaAudio.cut if boundary errors matter.
        for start in stride(from: 0.0, to: duration, by: seconds) {
            try Task.checkCancellation()
            let buffer = try AudioProcessor.loadAudio(fromPath: url.path, startTime: start, endTime: min(duration, start + seconds))
            let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
            chunks.append(wav(samples))
        }
        try Task.checkCancellation()
        return chunks
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
