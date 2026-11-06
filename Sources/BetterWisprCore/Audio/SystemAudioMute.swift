import CoreAudio
import Foundation

@available(macOS 14.2, *)
@MainActor
protocol MutingTap: AnyObject {
    func begin() async throws
    func stop()
}

@available(macOS 14.2, *)
extension SystemAudioTap: MutingTap {
    func begin() async throws {
        _ = try await prepare()
        try start { _, _ in }
    }
}

/// Silences every other app's output through a private process tap, without touching the output device's volume or mute.
@available(macOS 14.2, *)
@MainActor
public final class SystemAudioMute: Sendable {
    private let makeTap: @MainActor () -> any MutingTap
    private var tap: (any MutingTap)?

    public convenience init() {
        self.init(makeTap: { SystemAudioTap(muteBehavior: .mutedWhenTapped) })
    }

    init(makeTap: @escaping @MainActor () -> any MutingTap) {
        self.makeTap = makeTap
    }

    public func mute() async throws {
        guard tap == nil else { return }
        let created = makeTap()
        tap = created
        do {
            try await created.begin()
        } catch {
            created.stop()
            if tap === created { tap = nil }
            throw error
        }
    }

    public func unmute() {
        tap?.stop()
        tap = nil
    }

    /// Listens to system audio for a moment, so macOS asks for System Audio Recording when the setting turns on instead of during a dictation.
    public static func requestPermission() async {
        let tap = SystemAudioTap()
        if (try? await tap.prepare()) != nil { try? tap.start { _, _ in } }
        tap.stop()
    }
}
