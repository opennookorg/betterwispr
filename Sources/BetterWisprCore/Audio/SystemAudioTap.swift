@preconcurrency import AVFoundation
import CoreAudio
import Foundation

struct SystemAudioError: LocalizedError {
    let step: String
    let status: OSStatus

    var errorDescription: String? { L10n.tr("Couldn’t %@ (Core Audio error %@).", String(step), String(status)) }
}

/// Captures every other app's output through a private process tap on a private aggregate device.
@available(macOS 14.2, *)
@MainActor
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "org.betterwispr.meeting-tap", qos: .userInitiated)
    private let muteBehavior: CATapMuteBehavior

    init(muteBehavior: CATapMuteBehavior = .unmuted) {
        self.muteBehavior = muteBehavior
    }

    func prepare() async throws -> AVAudioFormat {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        description.name = "BetterWispr Meeting Tap"
        description.isPrivate = true
        description.muteBehavior = muteBehavior
        try check(AudioHardwareCreateProcessTap(description, &tapID), tapID, L10n.tr("create the system audio tap"))
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BetterWispr Meeting Audio",
            kAudioAggregateDeviceUIDKey: "org.betterwispr.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), aggregateID, L10n.tr("create the system audio device"))
        var stream = try await streamDescription()
        guard let format = AVAudioFormat(streamDescription: &stream) else {
            throw SystemAudioError(step: L10n.tr("read the system audio format"), status: kAudioHardwareUnsupportedOperationError)
        }
        return format
    }

    func start(_ receive: @escaping @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        try listen(receive)
        try check(AudioDeviceStart(aggregateID, procID), aggregateID, L10n.tr("start system audio"))
    }

    /// Starts off the main actor, because `kAudioAggregateDeviceTapAutoStartKey` makes `AudioDeviceStart` wait for the first audio from a tapped app; `stop()` must wait for this to return.
    func startInBackground() async throws {
        try listen { _, _ in }
        let device = aggregateID
        let proc = procID
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: AudioDeviceStart(device, proc)) }
        }
        try check(status, device, L10n.tr("start system audio"))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func listen(_ receive: @escaping @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void) throws {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { @Sendable _, input, inputTime, _, _ in receive(input, inputTime) }
        guard status == noErr, procID != nil else { throw SystemAudioError(step: L10n.tr("listen to system audio"), status: status) }
    }

    private func streamDescription() async throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = noErr
        for _ in 0..<5 {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
            if status == noErr, format.mSampleRate > 0, format.mChannelsPerFrame > 0 { return format }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SystemAudioError(step: L10n.tr("read the system audio format"), status: status)
    }

    private func check(_ status: OSStatus, _ object: AudioObjectID, _ step: String) throws {
        guard status == noErr, object != kAudioObjectUnknown else { throw SystemAudioError(step: step, status: status) }
    }

    nonisolated static func ownProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID)
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }
}
