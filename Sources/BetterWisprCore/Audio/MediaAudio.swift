@preconcurrency import AVFoundation
import Foundation

public enum MediaAudioError: LocalizedError, Equatable {
    case unreadable(String)
    case noAudio(String)

    public static let formats = L10n.tr("MP3, M4A, AAC, WAV, AIFF, CAF, FLAC, MP4, MOV or M4V")

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): L10n.tr("BetterWispr can’t read the audio in “%@”. Choose an %@ file.", String(name), String(Self.formats))
        case .noAudio(let name): L10n.tr("“%@” has no audio track. Choose an %@ file.", String(name), String(Self.formats))
        }
    }
}

public struct MediaChunk: Sendable {
    public let url: URL
    public let start: TimeInterval
    public let duration: TimeInterval
}

/// Streams the first audio track of a media file as 16 kHz mono chunk files, each cut at the quietest moment 30 to 59.5 s after the last cut.
public actor MediaAudio {
    public static let sampleRate = 16_000
    static let frame = sampleRate / 100
    static let shortest = 3_000
    static let longest = 5_950
    static let smoothing = 30
    static let shortestTail = 100

    public nonisolated let duration: TimeInterval
    private let name: String
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var emitted = 0
    private var finished = false
    private static let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!

    public init(url: URL) async throws {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let assetDuration: TimeInterval
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            assetDuration = try await asset.load(.duration).seconds
        } catch {
            throw MediaAudioError.unreadable(name)
        }
        duration = Self.length(of: url) ?? assetDuration
        guard let track = tracks.first else { throw MediaAudioError.noAudio(name) }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else { throw MediaAudioError.unreadable(name) }
        reader.add(output)
        guard reader.startReading() else { throw MediaAudioError.unreadable(name) }
        self.reader = reader
        self.name = name
    }

    /// Writes the next chunk to a temporary file the caller deletes; nil once the whole track was handed out.
    public func next() throws -> MediaChunk? {
        let needed = (Self.longest + Self.shortestTail) * Self.frame
        while !finished, samples.count < needed {
            try Task.checkCancellation()
            if let buffer = output.copyNextSampleBuffer() {
                try append(buffer)
            } else {
                guard reader.status == .completed else { throw MediaAudioError.unreadable(name) }
                try resample(nil)
                finished = true
            }
        }
        guard !samples.isEmpty else { return nil }
        let frames = samples.count / Self.frame
        let end = frames > Self.longest
            ? Self.cut(levels: Self.levels(samples), minimum: Self.shortest, maximum: min(Self.longest, frames - Self.shortestTail)) * Self.frame
            : samples.count
        let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-media-\(UUID().uuidString).caf")
        do {
            try write(samples[..<end], to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let chunk = MediaChunk(url: url, start: Double(emitted) / Double(Self.sampleRate), duration: Double(end) / Double(Self.sampleRate))
        samples.removeFirst(end)
        emitted += end
        return chunk
    }

    /// The quietest frame in `minimum..<maximum` after a 300 ms centred moving average of 10 ms levels, the first one on a tie.
    static func cut(levels: [Float], minimum: Int, maximum: Int) -> Int {
        let weight = 1.0 / Double(smoothing)
        let smoothed = (minimum..<min(maximum, levels.count)).map { frame in
            levels[max(0, frame - smoothing / 2)..<min(levels.count, frame + smoothing / 2)].reduce(0.0) { $0 + Double($1) * weight }
        }
        return minimum + (smoothed.indices.min { smoothed[$0] < smoothed[$1] } ?? 0)
    }

    /// The audio file's own length, because AVAsset doubles the duration of the DASH m4a files yt-dlp writes when ffmpeg is missing.
    private static func length(of url: URL) -> TimeInterval? {
        (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate }
    }

    /// Root mean square of each whole 10 ms frame.
    static func levels(_ samples: [Float]) -> [Float] {
        (0..<samples.count / frame).map { index in
            let slice = samples[index * frame..<(index + 1) * frame]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(frame) + 1e-12).squareRoot()
        }
    }

    private func append(_ sample: CMSampleBuffer) throws {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        if converter == nil {
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let rate = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mSampleRate,
                  let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw MediaAudioError.unreadable(name) }
            converter = AVAudioConverter(from: source, to: Self.format)
            converter?.primeMethod = .none
        }
        let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        guard let converter, let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { throw MediaAudioError.unreadable(name) }
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: channel)
        buffer.frameLength = AVAudioFrameCount(count)
        try resample(buffer)
    }

    /// Resamples with one converter for the whole track because AVAssetReader's own resampling differs from run to run; nil flushes the end.
    private func resample(_ input: AVAudioPCMBuffer?) throws {
        guard let converter else { return }
        // convert(to:error:withInputFrom:) calls the block synchronously, before it returns.
        nonisolated(unsafe) var pending = input
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Self.sampleRate)),
                  let channel = output.floatChannelData?[0] else { throw MediaAudioError.unreadable(name) }
            var error: NSError?
            status = converter.convert(to: output, error: &error) { _, state in
                guard let buffer = pending else {
                    state.pointee = input == nil ? .endOfStream : .noDataNow
                    return nil
                }
                pending = nil
                state.pointee = .haveData
                return buffer
            }
            guard status != .error else { throw MediaAudioError.unreadable(name) }
            samples += UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        }
    }

    private func write(_ chunk: ArraySlice<Float>, to url: URL) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(chunk.count)), let channel = buffer.floatChannelData?[0] else {
            throw MediaAudioError.unreadable(name)
        }
        chunk.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.count) }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        try AVAudioFile(forWriting: url, settings: Self.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
    }
}
