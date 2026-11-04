import Accelerate
@preconcurrency import AVFoundation
import Foundation
import OSLog

public struct RecordedAudio: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let hasSpeech: Bool
}

public enum AudioRecordingError: LocalizedError {
    case permissionDenied, unavailable, inputStalled, alreadyRecording, notRecording

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow Microphone access for BetterWispr in System Settings → Privacy & Security."
        case .unavailable: "No microphone input is available. Check your input device in Sound settings."
        case .inputStalled: "The microphone stopped delivering audio. Reconnect it or choose another input in Settings."
        case .alreadyRecording: "A recording is already running."
        case .notRecording: "No recording is running."
        }
    }
}

@MainActor
public final class AudioRecorder {
    public var onLevel: (@MainActor @Sendable (VoiceLevels) -> Void)?
    public var onError: (@MainActor (any Error) -> Void)?
    /// RMS amplitude gate, not a semantic speech detector. Lower this for quiet microphones.
    public var silenceThreshold: Float = 0.002
    /// Nil uses Automatic.
    public var microphone: AudioInputDevice? {
        didSet { if recordingID != nil { inputObserver?.scheduleCheck() } }
    }
    private var changingInput = false
    private var input: MicrophoneInput?
    private var inputObserver: AudioInputObserver?
    private var device: AudioInputDevice?
    private var recoveryAttempts = 0
    private var recoveryError: (any Error)?
    private var writer: RecordingWriter?
    private var tap: LiveSampleTap?
    private var progress: AudioCaptureProgress?
    private var recordingURL: URL?
    private var starting = false
    private var recordingID: UUID?
    private var meter = VoiceLevelMeter()

    public init() {}

    /// `onSamples` receives 16 kHz mono copies of each buffer on the capture worker; the recorded file is unchanged.
    public func start(onSamples: (@Sendable ([Float]) -> Void)? = nil) async throws {
        guard writer == nil, !starting, !changingInput else { throw AudioRecordingError.alreadyRecording }
        starting = true
        defer { starting = false }
        let id = UUID()
        recordingID = id
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard recordingID == id else { throw CancellationError() }
        guard allowed else { throw AudioRecordingError.permissionDenied }
        recordingURL = FileManager.default.temporaryDirectory.appending(path: "betterwispr-\(UUID().uuidString).caf")
        meter = VoiceLevelMeter()
        tap = onSamples.map(LiveSampleTap.init)
        let progress = AudioCaptureProgress()
        self.progress = progress
        inputObserver = AudioInputObserver { [weak self] in
            Task { @MainActor [weak self] in await self?.followMicrophone(session: id) }
        }
        do {
            try await runMicrophone(session: id)
            try await progress.wait()
            guard recordingID == id else { throw CancellationError() }
        } catch {
            if recordingID == id { cancel() }
            throw error
        }
    }

    /// Completes the in-flight audio buffer before finalizing a normal dictation.
    public func finish() async throws -> RecordedAudio {
        guard let id = recordingID, let progress, writer != nil else { throw AudioRecordingError.notRecording }
        inputObserver?.cancel()
        do {
            try await progress.wait(through: ProcessInfo.processInfo.systemUptime)
            guard recordingID == id else { throw CancellationError() }
        } catch {
            if recordingID == id { cancel() }
            throw error
        }
        return try stop()
    }

    /// Stops immediately, used when cancelling without waiting for more microphone data.
    public func stop() throws -> RecordedAudio {
        guard let writer, let url = recordingURL else { throw AudioRecordingError.notRecording }
        haltMicrophone()
        let result = writer.finish()
        let error = result.error ?? recoveryError
        reset()
        if let error {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        guard result.duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw SpeechError.emptyAudio
        }
        return RecordedAudio(url: url, duration: result.duration, hasSpeech: result.hasSpeech)
    }

    public func cancel() {
        haltMicrophone()
        _ = writer?.finish()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        reset()
    }

    /// Both recording features use the same input-only Core Audio capture path.
    private func runMicrophone(session id: UUID) async throws {
        guard let url = recordingURL, let progress else { throw AudioRecordingError.notRecording }
        changingInput = true
        defer { changingInput = false }
        let input = try MicrophoneInput(choice: microphone)
        let format = input.format
        let writer = try self.writer ?? RecordingWriter(url: url, format: format, threshold: silenceThreshold)
        let sampleRate = format.sampleRate
        let capture = progress.begin()
        let tap = tap
        inputObserver?.observeDevice(input.deviceID)
        try await input.start { @Sendable [weak self] buffer, time in
            let end = AudioCaptureProgress.endTime(time, frames: buffer.frameLength, sampleRate: sampleRate)
            let loudness = writer.write(buffer)
            tap?.receive(buffer)
            let step = Double(buffer.frameLength) / sampleRate / Double(max(1, loudness.count))
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == id, progress.generation == capture else { return }
                progress.receive(through: end, generation: capture)
                let values = loudness.map { self.meter.update(rms: $0, over: step) }
                self.onLevel?(VoiceLevels(values: values, start: .now.addingTimeInterval(-step * Double(max(0, values.count - 1))), step: step))
            }
        }
        guard recordingID == id, !Task.isCancelled else {
            input.stop()
            throw CancellationError()
        }
        self.input = input
        self.writer = writer
        self.device = input.device
        recoveryAttempts = 0
        recoveryError = nil
        inputObserver?.scheduleCheck()
    }

    /// Audio Queue converts native rate changes itself; restart only for a new device or stopped queue.
    private func followMicrophone(session id: UUID) async {
        guard recordingID == id, !changingInput else { return }
        guard input?.isRunning != true || AudioInputs.resolve(microphone)?.id != device?.id else { return }
        haltMicrophone()
        do {
            try await runMicrophone(session: id)
        } catch {
            guard recordingID == id else { return }
            recoveryError = error
            recoveryAttempts += 1
            if recoveryAttempts < 3 {
                inputObserver?.scheduleCheck()
            } else {
                cancel()
                onError?(error)
            }
        }
    }

    private func haltMicrophone() {
        inputObserver?.observeDevice(nil)
        input?.stop()
        if let error = input?.error { recoveryError = error }
        input = nil
    }

    private func reset() {
        inputObserver?.cancel()
        inputObserver = nil
        device = nil
        progress?.cancel()
        progress = nil
        recoveryAttempts = 0
        recoveryError = nil
        writer = nil
        tap = nil
        recordingURL = nil
        recordingID = nil
        onLevel?(VoiceLevels())
    }
}

/// Waveform levels for consecutive slices of one audio buffer, timestamped across the time it covers.
public struct VoiceLevels: Sendable, Equatable {
    public var values: [Float]
    public var start: Date
    public var step: TimeInterval

    public init(values: [Float] = [], start: Date = .distantPast, step: TimeInterval = 0) {
        self.values = values
        self.start = start
        self.step = step
    }

    public func value(at date: Date) -> Float {
        guard !values.isEmpty else { return 0 }
        let last = Double(values.count - 1)
        let elapsed = step > 0 ? date.timeIntervalSince(start) / step : last
        return values[Int(min(last, max(0, elapsed)))]
    }
}

/// Maps RMS over a stretch of audio to a 0...1 waveform level relative to the room's noise floor and the speaker's recent peak.
public struct VoiceLevelMeter: Sendable {
    public private(set) var level: Float = 0
    private var floor: Float?
    private var peak: Float = -60

    public init() {}

    /// Rates are tuned per 0.1 s and scaled by `duration`, so the meter moves at the same speed for any slice length.
    public mutating func update(rms: Float, over duration: TimeInterval) -> Float {
        let ticks = Float(max(0, duration) / Self.tick)
        var target: Float = 0
        if rms == 0 { floor = -60 }
        if rms.isFinite, rms > 0 {
            let decibels = max(-60, 20 * log10(rms))
            let floor = min((self.floor ?? decibels) + Self.floorRise * ticks, decibels)
            peak = max(decibels, peak - Self.peakFall * ticks, floor + Self.minimumRange)
            let span = peak - floor - Self.gate
            target = pow(min(1, max(0, (decibels - floor - Self.gate) / span)), Self.curve)
            self.floor = floor
        }
        let rate = target > level ? Self.attack : Self.release
        level += (target - level) * (1 - pow(1 - rate, ticks))
        return level
    }

    /// Fixed 20 ms windows keep the amplitude gate independent of device/tap buffer size.
    static func slices(of buffer: AVAudioPCMBuffer) -> [(frames: Int, rms: Float)] {
        let length = Int(buffer.frameLength)
        let step = max(1, Int(buffer.format.sampleRate * 0.02))
        return stride(from: 0, to: length, by: step).map { start in
            let range = start..<min(start + step, length)
            return (range.count, rms(of: buffer, in: range))
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer, in frames: Range<Int>) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let spacing = interleaved ? count : 1
        return (0..<count).reduce(0) { loudest, channel in
            let first = interleaved ? channels[0].advanced(by: channel) : channels[channel]
            var value: Float = 0
            vDSP_rmsqv(first.advanced(by: frames.lowerBound * spacing), vDSP_Stride(spacing), &value, vDSP_Length(frames.count))
            return max(loudest, value)
        }
    }

    private static let tick: TimeInterval = 0.1
    private static let floorRise: Float = 0.1
    private static let peakFall: Float = 0.12
    private static let minimumRange: Float = 15
    private static let gate: Float = 3
    private static let curve: Float = 0.7
    private static let attack: Float = 0.8
    private static let release: Float = 0.6
}

/// Unchecked because a lock guards writes and finalization against stop and cancel, and no buffer escapes the capture worker.
final class RecordingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var activeFrames: AVAudioFramePosition = 0
    private var maximumRMS: Float = 0
    private var error: (any Error)?
    private let formatter = FormatConverter()
    private let sampleRate: Double
    private let threshold: Float

    init(url: URL, format: AVAudioFormat, threshold: Float) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        sampleRate = format.sampleRate
        self.threshold = threshold.isFinite ? max(0, threshold) : 0.002
    }

    func write(_ input: AVAudioPCMBuffer) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let file, error == nil, input.frameLength > 0 else { return [] }
        let buffer: AVAudioPCMBuffer
        do {
            buffer = try formatter.convert(input, to: file.processingFormat)
            guard buffer.frameLength > 0 else { return [] }
            try file.write(from: buffer)
        } catch {
            self.error = error
            return []
        }
        let length = Int(buffer.frameLength)
        frames += AVAudioFramePosition(length)
        let slices = VoiceLevelMeter.slices(of: buffer)
        maximumRMS = max(maximumRMS, slices.map(\.rms).max() ?? 0)
        for slice in slices where slice.rms >= threshold { activeFrames += AVAudioFramePosition(slice.frames) }
        return slices.map(\.rms)
    }

    func finish() -> (duration: TimeInterval, hasSpeech: Bool, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        Logger(subsystem: "org.betterwispr.app", category: "MicrophoneCapture").notice("Finished input: duration=\(Double(self.frames) / self.sampleRate)s active=\(Double(self.activeFrames) / self.sampleRate)s maxRMS=\(self.maximumRMS) threshold=\(self.threshold)")
        // ponytail: an amplitude gate rejects silence; use a learned VAD if noise rejection is needed.
        return (Double(frames) / sampleRate, Double(activeFrames) / sampleRate >= 0.12, error)
    }
}
