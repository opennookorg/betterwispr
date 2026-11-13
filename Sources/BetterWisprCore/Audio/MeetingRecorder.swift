@preconcurrency import AVFoundation
import Foundation

public struct ChunkPolicy: Sendable {
    public var minimum: TimeInterval
    public var maximum: TimeInterval
    public var pause: TimeInterval

    public init(minimum: TimeInterval = 3, maximum: TimeInterval = 20, pause: TimeInterval = 0.6) {
        self.minimum = minimum
        self.maximum = maximum
        self.pause = pause
    }

    public func shouldRotate(duration: TimeInterval, trailingSilence: TimeInterval) -> Bool {
        duration >= maximum || (duration >= minimum && trailingSilence >= pause)
    }
}

public struct MeetingAudioChunk: Sendable {
    public let url: URL
    public let speaker: Speaker
    public let start: TimeInterval
    public let duration: TimeInterval
    public let hasSpeech: Bool
}

/// Records the microphone as Me and other apps' audio as Them, handing off rotating chunk files for transcription.
@MainActor
public final class MeetingRecorder {
    public var onChunk: (@MainActor (MeetingAudioChunk) -> Void)?
    public var onLevels: (@MainActor ((me: Float, them: Float)) -> Void)?
    public var onError: (@MainActor (any Error) -> Void)?
    public var onMicrophone: (@MainActor (AudioInputDevice?) -> Void)?
    public private(set) var systemAudioIssue: String?
    public private(set) var microphone: AudioInputDevice?
    private let policy: ChunkPolicy
    private var session: UUID?
    private var origin = ProcessInfo.processInfo.systemUptime
    private var threshold: Float = 0.002
    private var choice: AudioInputDevice?
    private var changingInput = false
    private var input: MicrophoneInput?
    private var inputObserver: AudioInputObserver?
    private var microphoneProgress: AudioCaptureProgress?
    private var recoveryAttempts = 0
    private var writers: [Speaker: MeetingChunkWriter] = [:]
    private var stopSystemAudio: (() -> Void)?
    private var meters: [Speaker: VoiceLevelMeter] = [:]
    private var levels: (me: Float, them: Float) = (0, 0)
    /// Drops the microphone's audio so only other apps (Them) reach the transcript.
    public var microphoneMuted = false {
        didSet {
            guard let writer = writers[.me] else { return }
            writer.setMuted(microphoneMuted)
            hand(writer.takeReady())
        }
    }

    public init(policy: ChunkPolicy = ChunkPolicy()) {
        self.policy = policy
    }

    /// Nil microphone uses Automatic.
    public func start(silenceThreshold: Float, microphone choice: AudioInputDevice?) async throws {
        guard session == nil, !changingInput else { throw AudioRecordingError.alreadyRecording }
        let id = UUID()
        session = id
        systemAudioIssue = nil
        threshold = silenceThreshold
        self.choice = choice
        do {
            try await startMicrophone(session: id)
            await startSystemAudio(session: id, threshold: silenceThreshold)
            guard session == id else { throw CancellationError() }
        } catch {
            if session == id { cancel() }
            throw error
        }
    }

    /// Switches the live recording to another microphone; nil uses Automatic.
    public func use(_ choice: AudioInputDevice?) {
        self.choice = choice
        if session != nil { inputObserver?.scheduleCheck() }
    }

    public func stop() async {
        guard let id = session else { return }
        inputObserver?.cancel()
        if input?.isRunning == true, let microphoneProgress {
            do { try await microphoneProgress.wait(through: ProcessInfo.processInfo.systemUptime) }
            catch { if session == id, !(error is CancellationError) { onError?(error) } }
        }
        guard session == id else { return }
        haltInputs()
        for speaker in [Speaker.me, .them] {
            guard let writer = writers[speaker] else { continue }
            writer.finish()
            hand(writer.takeReady())
        }
        reset()
    }

    public func cancel() {
        haltInputs()
        for writer in writers.values {
            writer.cancel()
            for chunk in writer.takeReady().chunks { try? FileManager.default.removeItem(at: chunk.url) }
        }
        reset()
    }

    private func startMicrophone(session id: UUID) async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation()
        guard session == id else { throw CancellationError() }
        guard allowed else { throw AudioRecordingError.permissionDenied }
        origin = ProcessInfo.processInfo.systemUptime
        let progress = AudioCaptureProgress()
        microphoneProgress = progress
        inputObserver = AudioInputObserver { [weak self] in
            Task { @MainActor [weak self] in await self?.followMicrophone(session: id) }
        }
        try await runMicrophone(session: id, startOffset: 0)
        try await progress.wait()
        guard session == id else { throw CancellationError() }
    }

    private func runMicrophone(session id: UUID, startOffset: TimeInterval) async throws {
        guard let progress = microphoneProgress else { throw AudioRecordingError.notRecording }
        changingInput = true
        defer { changingInput = false }
        let input = try MicrophoneInput(choice: choice)
        let format = input.format
        let writer = try MeetingChunkWriter(speaker: .me, format: format, threshold: threshold, policy: policy, startOffset: startOffset)
        writer.setMuted(microphoneMuted)
        let capture = progress.begin()
        let sampleRate = format.sampleRate
        let origin = origin
        do {
            inputObserver?.observeDevice(input.deviceID)
            try await input.start { @Sendable [weak self] buffer, time in
                let end = AudioCaptureProgress.endTime(time, frames: buffer.frameLength, sampleRate: sampleRate)
                let level = writer.write(buffer, at: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) - origin : nil)
                progress.receive(through: end, generation: capture)
                Task { @MainActor [weak self] in
                    guard let self, self.session == id, progress.generation == capture else { return }
                    self.receive(level, from: .me, session: id)
                }
            }
        } catch {
            input.stop()
            writer.cancel()
            throw error
        }
        guard session == id, !Task.isCancelled else {
            input.stop()
            writer.cancel()
            throw CancellationError()
        }
        self.input = input
        writer.setMuted(microphoneMuted)
        writers[.me] = writer
        recoveryAttempts = 0
        microphone = input.device
        onMicrophone?(input.device)
        inputObserver?.scheduleCheck()
    }

    /// Let a running Audio Queue handle Bluetooth format changes without another hardware restart.
    private func followMicrophone(session id: UUID) async {
        guard session == id, !changingInput else { return }
        guard input?.isRunning != true || AudioInputs.resolve(choice)?.id != microphone?.id else { return }
        await restartMicrophone(session: id)
    }

    /// Hands off the chunk recorded so far, then picks the microphone back up on whichever input now resolves.
    private func restartMicrophone(session id: UUID) async {
        guard session == id else { return }
        haltMicrophone()
        if let writer = writers.removeValue(forKey: .me) {
            writer.finish()
            hand(writer.takeReady())
        }
        do {
            try await runMicrophone(session: id, startOffset: ProcessInfo.processInfo.systemUptime - origin)
        } catch {
            guard session == id else { return }
            microphone = nil
            onMicrophone?(nil)
            levels.me = 0
            onLevels?(levels)
            recoveryAttempts += 1
            if recoveryAttempts < 3 { inputObserver?.scheduleCheck() }
            else {
                recoveryAttempts = 0
                onError?(error)
            }
        }
    }

    private func haltMicrophone() {
        inputObserver?.observeDevice(nil)
        input?.stop()
        if let error = input?.error { onError?(error) }
        input = nil
    }

    private func startSystemAudio(session id: UUID, threshold: Float) async {
        guard #available(macOS 14.2, *) else {
            systemAudioIssue = "System audio needs macOS 14.2 or later."
            return
        }
        let tap = SystemAudioTap()
        var writer: MeetingChunkWriter?
        do {
            let format = try await tap.prepare()
            guard session == id else { return tap.stop() }
            let created = try MeetingChunkWriter(speaker: .them, format: format, threshold: threshold, policy: policy,
                                                 startOffset: ProcessInfo.processInfo.systemUptime - origin)
            writer = created
            let origin = origin
            try tap.start { [weak self] buffers, time in
                let stamp = time.pointee
                let level = created.write(buffers, at: stamp.mFlags.contains(.hostTimeValid)
                                              ? AVAudioTime.seconds(forHostTime: stamp.mHostTime) - origin : nil)
                Task { @MainActor [weak self] in self?.receive(level, from: .them, session: id) }
            }
            writers[.them] = created
            stopSystemAudio = { tap.stop() }
        } catch {
            tap.stop()
            writer?.cancel()
            if session == id { systemAudioIssue = "Recording your microphone only. \(error.localizedDescription)" }
        }
    }

    /// Splits a recording into the chunks a meeting would transcribe if `speaker` played it live, in 10 ms buffers like the system audio tap.
    nonisolated public static func chunks(of url: URL, speaker: Speaker, threshold: Float = 0.002, policy: ChunkPolicy = ChunkPolicy()) throws -> [MeetingAudioChunk] {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let writer = try MeetingChunkWriter(speaker: speaker, format: format, threshold: threshold, policy: policy, startOffset: 0)
        let frames = AVAudioFrameCount(format.sampleRate / 100)
        var chunks: [MeetingAudioChunk] = []
        func collect() throws {
            let ready = writer.takeReady()
            chunks += ready.chunks
            if let error = ready.error { throw error }
        }
        do {
            while source.framePosition < source.length, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                let time = Double(source.framePosition) / format.sampleRate
                try source.read(into: buffer, frameCount: frames)
                _ = writer.write(buffer, at: time)
                try collect()
            }
            writer.finish()
            try collect()
        } catch {
            writer.cancel()
            for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
            throw error
        }
        return chunks
    }

    private func receive(_ sample: (rms: Float, duration: TimeInterval), from speaker: Speaker, session id: UUID) {
        guard session == id, let writer = writers[speaker] else { return }
        let level = meters[speaker, default: VoiceLevelMeter()].update(rms: sample.rms, over: sample.duration)
        if speaker == .me { levels.me = level } else { levels.them = level }
        onLevels?(levels)
        hand(writer.takeReady())
        guard speaker == .me, let them = writers[.them] else { return }
        them.closeIfIdle(at: ProcessInfo.processInfo.systemUptime - origin)
        hand(them.takeReady())
    }

    private func hand(_ ready: (chunks: [MeetingAudioChunk], error: (any Error)?)) {
        if let error = ready.error { onError?(error) }
        for chunk in ready.chunks {
            if let onChunk { onChunk(chunk) } else { try? FileManager.default.removeItem(at: chunk.url) }
        }
    }

    private func haltInputs() {
        inputObserver?.cancel()
        inputObserver = nil
        haltMicrophone()
        stopSystemAudio?()
    }

    private func reset() {
        writers = [:]
        stopSystemAudio = nil
        session = nil
        microphoneProgress?.cancel()
        microphoneProgress = nil
        recoveryAttempts = 0
        meters = [:]
        levels = (0, 0)
        onLevels?(levels)
        microphone = nil
        onMicrophone?(nil)
        microphoneMuted = false
    }
}

/// Unchecked because a lock guards the file, counters and chunks against rotation, stop and cancel, and no buffer outlives a write.
final class MeetingChunkWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let speaker: Speaker
    private let format: AVAudioFormat
    private let policy: ChunkPolicy
    private let threshold: Float
    private var file: AVAudioFile?
    private var url: URL?
    private var nextStart: TimeInterval
    private var chunkStart: TimeInterval = 0
    private var frames: AVAudioFramePosition = 0
    private var activeFrames: AVAudioFramePosition = 0
    private var silentFrames: AVAudioFramePosition = 0
    private var capturedThrough: TimeInterval?
    private var recentLevels: [Float] = []
    private var muted = false
    private var ready: [MeetingAudioChunk] = []
    private var error: (any Error)?

    init(speaker: Speaker, format: AVAudioFormat, threshold: Float, policy: ChunkPolicy, startOffset: TimeInterval) throws {
        self.speaker = speaker
        self.format = format
        self.policy = policy
        self.threshold = threshold.isFinite ? max(0, threshold) : 0.002
        self.nextStart = startOffset
        try open()
    }

    func write(_ list: UnsafePointer<AudioBufferList>, at time: TimeInterval? = nil) -> (rms: Float, duration: TimeInterval) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return (0, 0) }
        return write(buffer, at: time)
    }

    /// `time` is when the buffer's first frame was captured, in meeting seconds; without it a chunk starts where the last one ended.
    func write(_ buffer: AVAudioPCMBuffer, at time: TimeInterval? = nil) -> (rms: Float, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let count = AVAudioFramePosition(buffer.frameLength)
        guard !muted else {
            if time == nil { nextStart += seconds(count) }
            return (0, seconds(count))
        }
        if let time, isLate(time) { rotate() }
        guard let file, count > 0 else { return (0, seconds(count)) }
        if frames == 0 { chunkStart = time ?? nextStart }
        do {
            try file.write(from: buffer)
        } catch {
            self.error = error
            closeChunk()
            return (0, seconds(count))
        }
        let slices = VoiceLevelMeter.slices(of: buffer)
        let rms = slices.map(\.rms).max() ?? 0
        frames += count
        if let time { capturedThrough = time + seconds(count) }
        let gate = max(threshold, noiseFloor() * Self.speechOverNoise)
        recentLevels += slices.map(\.rms)
        recentLevels.removeFirst(max(0, recentLevels.count - Self.noiseFloorSlices))
        for slice in slices {
            if slice.rms >= gate {
                activeFrames += AVAudioFramePosition(slice.frames)
                silentFrames = 0
            } else {
                silentFrames += AVAudioFramePosition(slice.frames)
            }
        }
        if policy.shouldRotate(duration: seconds(frames), trailingSilence: seconds(silentFrames)) { rotate() }
        return (rms, seconds(count))
    }

    /// Closes the open chunk once no audio has arrived for a delivery gap, since a silent tap sends nothing that would close it.
    func closeIfIdle(at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if isLate(time) { rotate() }
    }

    /// Muting closes the open chunk so what was said before it still gets transcribed.
    func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard muted != self.muted else { return }
        self.muted = muted
        if muted { rotate() }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        closeChunk()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }

    func takeReady() -> (chunks: [MeetingAudioChunk], error: (any Error)?) {
        lock.lock()
        defer {
            ready = []
            error = nil
            lock.unlock()
        }
        return (ready, error)
    }

    private func open() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-meeting-\(UUID().uuidString).caf")
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            self.url = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func rotate() {
        closeChunk()
        do { try open() } catch { self.error = error }
    }

    private func closeChunk() {
        guard let url else { return }
        file = nil
        self.url = nil
        let duration = seconds(frames)
        if frames > 0 {
            // ponytail: an amplitude gate decides speech; use a learned VAD if room noise floods transcription.
            ready.append(MeetingAudioChunk(url: url, speaker: speaker, start: chunkStart, duration: duration,
                                           hasSpeech: seconds(activeFrames) >= 0.3 && duration >= 0.5))
            nextStart = chunkStart + duration
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        frames = 0
        activeFrames = 0
        silentFrames = 0
    }

    private func isLate(_ time: TimeInterval) -> Bool {
        guard frames > 0, let capturedThrough else { return false }
        return time - capturedThrough > Self.deliveryGap
    }

    private func seconds(_ frames: AVAudioFramePosition) -> TimeInterval {
        Double(frames) / format.sampleRate
    }

    /// The 20th percentile ignores the brief near-silent dropouts Bluetooth headsets emit, which would drag a minimum to zero.
    private func noiseFloor() -> Float {
        recentLevels.count < Self.warmupSlices ? 0 : recentLevels.sorted()[recentLevels.count / 5]
    }

    /// System audio stops arriving while nothing plays, so a late buffer starts a new chunk at its real time.
    private static let deliveryGap: TimeInterval = 0.5
    private static let warmupSlices = 150
    private static let noiseFloorSlices = 500
    private static let speechOverNoise = pow(Float(10), 10 / 20)
}
