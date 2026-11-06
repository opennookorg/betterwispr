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
        try await startInBackground()
    }
}

/// Silences every other app's output through a private process tap, without touching the output device's volume or mute.
@available(macOS 14.2, *)
@MainActor
public final class SystemAudioMute: Sendable {
    private let makeTap: @MainActor () -> any MutingTap
    private var tap: (any MutingTap)?
    private var wanted = false
    private(set) var starting: Task<Void, Never>?

    public convenience init() {
        self.init(makeTap: { SystemAudioTap(muteBehavior: .mutedWhenTapped) })
    }

    init(makeTap: @escaping @MainActor () -> any MutingTap) {
        self.makeTap = makeTap
    }

    /// Returns without waiting for the tap, whose start can last until some app plays audio; a start still running is reused rather than doubled.
    public func mute(onFailure: @escaping @MainActor @Sendable (any Error) -> Void) {
        wanted = true
        guard tap == nil else { return }
        let created = makeTap()
        tap = created
        starting = Task {
            do {
                try await created.begin()
                starting = nil
                if !wanted { release() }
            } catch {
                starting = nil
                release()
                if wanted { onFailure(error) }
            }
        }
    }

    /// Ends the mute now, or as soon as a start still running returns, because a tap can't be stopped mid-start.
    public func unmute() {
        wanted = false
        if starting == nil { release() }
    }

    private func release() {
        tap?.stop()
        tap = nil
    }

    /// Listens to system audio for a moment, so macOS asks for System Audio Recording when the setting turns on instead of during a dictation.
    public static func requestPermission() async {
        let tap = SystemAudioTap()
        if (try? await tap.prepare()) != nil { try? await tap.startInBackground() }
        tap.stop()
    }
}
