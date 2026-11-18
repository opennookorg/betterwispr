import CoreAudio
import Foundation

/// Reads which processes are recording from a microphone through Core Audio's process objects, reported from macOS 14.2.
public enum MicrophoneActivity {
    /// Bundle IDs of every process recording audio input now; empty where macOS doesn't report process objects.
    public static func recordingBundleIDs() -> [String] {
        processes().filter(isRecording).compactMap { AudioInputs.string(kAudioProcessPropertyBundleID, of: $0) }
    }

    static func processes() -> Set<AudioObjectID> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = AudioInputs.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func isRecording(_ process: AudioObjectID) -> Bool {
        var property = AudioInputs.address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &property, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// Calls `onChange` on the main actor once any process starts or stops recording from a microphone.
@MainActor
public final class MicrophoneActivityObserver {
    private let onChange: @MainActor () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var processes: Set<AudioObjectID> = []
    private var settling: Task<Void, Never>?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        var property = AudioInputs.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        self.listener = listener
        observe(MicrophoneActivity.processes())
    }

    public func cancel() {
        settling?.cancel()
        observe([])
        guard let listener else { return }
        var property = AudioInputs.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        self.listener = nil
    }

    /// Some call apps notify Core Audio of general I/O changes only, so either event triggers a fresh input-state read.
    private func observe(_ current: Set<AudioObjectID>) {
        guard let listener else { return }
        for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunning] {
            var property = AudioInputs.address(selector)
            for process in processes.subtracting(current) {
                AudioObjectRemovePropertyListenerBlock(process, &property, .main, listener)
            }
            for process in current.subtracting(processes) {
                AudioObjectAddPropertyListenerBlock(process, &property, .main, listener)
            }
        }
        processes = current
    }

    private func scheduleCheck() {
        guard listener != nil else { return }
        observe(MicrophoneActivity.processes())
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
