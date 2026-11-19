import CoreAudio
import Foundation

/// Reads which processes are recording from a microphone through Core Audio's process objects, reported from macOS 14.2.
public enum MicrophoneActivity {
    /// Bundle IDs of every process recording audio input now; empty where macOS doesn't report process objects.
    public static func recordingBundleIDs() -> [String] {
        processes().filter { running(kAudioProcessPropertyIsRunningInput, on: $0) == true }.compactMap { AudioInputs.string(kAudioProcessPropertyBundleID, of: $0) }
    }

    /// nil means Core Audio could not establish the call app's state. Output keeps a muted call alive.
    public static func hasActiveAudio(for appID: String) -> Bool? {
        let current = processes()
        guard !current.isEmpty else { return nil }
        var complete = true
        for process in current {
            guard let bundle = AudioInputs.string(kAudioProcessPropertyBundleID, of: process) else {
                complete = false
                continue
            }
            guard MeetingPlatform.app(recording: bundle) == appID else { continue }
            let input = running(kAudioProcessPropertyIsRunningInput, on: process)
            let output = running(kAudioProcessPropertyIsRunningOutput, on: process)
            if input == true || output == true { return true }
            if input == nil || output == nil { complete = false }
        }
        return complete ? false : nil
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

    private static func running(_ selector: AudioObjectPropertySelector, on process: AudioObjectID) -> Bool? {
        var property = AudioInputs.address(selector)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
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

    /// Watches each process's input state, since the process list only changes when an app first uses audio or quits.
    private func observe(_ current: Set<AudioObjectID>) {
        guard let listener else { return }
        var input = AudioInputs.address(kAudioProcessPropertyIsRunningInput)
        for process in processes.subtracting(current) {
            AudioObjectRemovePropertyListenerBlock(process, &input, .main, listener)
        }
        for process in current.subtracting(processes) {
            AudioObjectAddPropertyListenerBlock(process, &input, .main, listener)
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
