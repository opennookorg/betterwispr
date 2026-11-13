@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

/// A microphone keyed by its Core Audio UID, so a saved choice survives unplugging and reconnecting.
public struct AudioInputDevice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum AudioInputs {
    /// Every connected device with an input stream, excluding private aggregates such as BetterWispr's system audio tap.
    public static func available() -> [AudioInputDevice] { inputs().map(\.device) }

    public static func systemDefault() -> AudioInputDevice? {
        var property = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &id) == noErr else { return nil }
        return device(id)
    }

    /// The chosen microphone while it is connected, otherwise Automatic, which is the macOS default input.
    public static func resolve(_ choice: AudioInputDevice?) -> AudioInputDevice? {
        resolve(choice, inputs: inputs(), systemDefault: systemDefault())
    }

    static func resolve(_ choice: AudioInputDevice?, inputs: [Input], systemDefault: AudioInputDevice?) -> AudioInputDevice? {
        inputs.first { $0.device.id == choice?.id }?.device ?? systemDefault
    }

    struct Input {
        var id = AudioDeviceID(kAudioObjectUnknown)
        let device: AudioInputDevice
    }

    static func captureDevice(_ choice: AudioInputDevice?) throws -> (AudioInputDevice, AudioDeviceID, AVAudioFormat) {
        let inputs = inputs()
        guard let device = resolve(choice, inputs: inputs, systemDefault: systemDefault()),
              let id = inputs.first(where: { $0.device.id == device.id })?.id else { throw AudioRecordingError.unavailable }
        var property = address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &stream) == noErr,
              stream.mSampleRate > 0, stream.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: stream.mSampleRate,
                                         channels: stream.mChannelsPerFrame, interleaved: true) else { throw AudioRecordingError.unavailable }
        return (device, id, format)
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func inputs() -> [Input] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in device(id).map { Input(id: id, device: $0) } }
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size) == noErr, size > 0,
              !isPrivateAggregate(id),
              let uid = string(kAudioDevicePropertyDeviceUID, of: id),
              let name = string(kAudioObjectPropertyName, of: id) else { return nil }
        return AudioInputDevice(id: uid, name: name)
    }

    /// Core Audio's per-process default aggregate and BetterWispr's tap are private and can't be recorded from directly.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var property = address(kAudioAggregateDevicePropertyComposition)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any] else { return false }
        return composition[kAudioAggregateDeviceIsPrivateKey] as? Bool ?? false
    }

    static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Tracks delivered audio from the capture worker, so a busy main thread cannot make capture look stalled.
final class AudioCaptureProgress: Sendable {
    private struct State {
        var generation = UUID()
        var latestEnd: TimeInterval?
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var generation: UUID { state.withLock { $0.generation } }

    @discardableResult
    func begin() -> UUID {
        state.withLock {
            $0.generation = UUID()
            $0.latestEnd = nil
            return $0.generation
        }
    }

    func receive(through end: TimeInterval, generation: UUID) {
        state.withLock {
            guard !$0.cancelled, $0.generation == generation, end.isFinite else { return }
            $0.latestEnd = max($0.latestEnd ?? end, end)
        }
    }

    func cancel() { state.withLock { $0.cancelled = true } }

    /// Waits for the first buffer (silence counts), or for the buffer covering a stop boundary, never a fixed tail delay.
    func wait(through boundary: TimeInterval? = nil) async throws {
        let deadline = ContinuousClock.now + (boundary == nil ? .seconds(3) : .milliseconds(500))
        while true {
            try Task.checkCancellation()
            let (cancelled, latestEnd) = state.withLock { ($0.cancelled, $0.latestEnd) }
            guard !cancelled else { throw CancellationError() }
            if let latestEnd, latestEnd >= (boundary ?? -.infinity) { return }
            guard ContinuousClock.now < deadline else { throw AudioRecordingError.inputStalled }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func endTime(_ time: AVAudioTime, frames: AVAudioFrameCount, sampleRate: Double) -> TimeInterval {
        time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime) + Double(frames) / sampleRate
            : ProcessInfo.processInfo.systemUptime
    }
}

/// Calls `onChange` on the main actor once microphones or the macOS default input settle.
@MainActor
public final class AudioInputObserver {
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private let onChange: @MainActor () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var deviceID: AudioDeviceID?
    private static var deviceProperties: [AudioObjectPropertyAddress] {
        [AudioInputs.address(kAudioDevicePropertyNominalSampleRate),
         AudioInputs.address(kAudioDevicePropertyDeviceIsAlive),
         AudioInputs.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)]
    }
    private var settling: Task<Void, Never>?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        for selector in Self.selectors {
            var property = AudioInputs.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
        self.listener = listener
    }

    public func cancel() {
        settling?.cancel()
        observeDevice(nil)
        guard let listener else { return }
        for selector in Self.selectors {
            var property = AudioInputs.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
        self.listener = nil
    }

    /// Watches same-UID Bluetooth profile changes as well as disconnection.
    func observeDevice(_ id: AudioDeviceID?) {
        guard id != deviceID, let listener else { return }
        if let deviceID {
            for var property in Self.deviceProperties {
                AudioObjectRemovePropertyListenerBlock(deviceID, &property, .main, listener)
            }
        }
        deviceID = id
        if let id {
            for var property in Self.deviceProperties {
                AudioObjectAddPropertyListenerBlock(id, &property, .main, listener)
            }
        }
    }

    /// Coalesces notifications and retries while a newly connected device settles.
    func scheduleCheck() {
        guard listener != nil else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
