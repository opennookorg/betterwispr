import CoreAudio
import Foundation

/// Silences every other app's output, such as a browser playing a video, through a private muted process tap.
/// A tap only mutes while its device runs, so the tap's private aggregate device runs and discards what it hears.
/// BetterWispr's own sounds still play, the output device's volume and mute are never touched, and the tap and
/// device are private to this process, so Core Audio removes them if BetterWispr exits without unmuting.
@available(macOS 14.2, *)
@MainActor
public final class SystemAudioMute: Sendable {
    private var tap: SystemAudioTap?

    public init() {}

    public func mute() async {
        guard tap == nil else { return }
        let created = SystemAudioTap(muteBehavior: .muted)
        tap = created
        do {
            _ = try await created.prepare()
            try created.start { _, _ in }
        } catch {
            created.stop()
            if tap === created { tap = nil }
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
