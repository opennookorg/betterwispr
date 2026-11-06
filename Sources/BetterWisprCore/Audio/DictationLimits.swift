import AVFoundation
import Foundation

/// When a long dictation is stopped, when it reminds the user it is still running, and when it needs their approval.
public enum DictationLimits {
    /// Just under 2^32 frames, which WhisperKit's `AVAudioFrameCount` conversions can't read; the margin leaves room for buffers still in flight.
    public static let maximumFrames: AVAudioFramePosition = (1 << 32) - (1 << 24)
    /// Well past a normal dictation yet soon enough to catch a forgotten toggle; it repeats because the reminder is brief.
    public static let reminderInterval: TimeInterval = 3600
    /// The old hard limit, so anything shorter behaves as dictation always has.
    public static let confirmationDuration: TimeInterval = 10 * 60

    public static func maximumDuration(sampleRate: Double) -> TimeInterval {
        Double(maximumFrames) / sampleRate
    }

    /// The number of whole reminder intervals a recording of this length has passed.
    public static func reminderHour(after duration: TimeInterval) -> Int {
        Int(duration / reminderInterval)
    }

    public static func asksBeforeSending(duration: TimeInterval, isOnDevice: Bool) -> Bool {
        !isOnDevice && duration >= confirmationDuration
    }

    public static func asksBeforePasting(duration: TimeInterval, autoPaste: Bool) -> Bool {
        autoPaste && duration >= confirmationDuration
    }
}
