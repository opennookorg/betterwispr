import Carbon.HIToolbox
import Foundation

/// How a dictation can start: a keyboard shortcut or a side mouse button, for push to talk or hands-free dictation.
public enum DictationTrigger: Codable, Equatable, Hashable, Sendable {
    case keyboard(DictationShortcut)
    /// A side mouse button, by its system button number: 3 is Mouse 4 (back), 4 is Mouse 5 (forward).
    case mouse(button: Int)

    public static let recordableMouseButtons = [3, 4]

    public var displayName: String {
        switch self {
        case .keyboard(let shortcut): shortcut.displayName
        case .mouse(let button): Self.mouseName(button)
        }
    }

    public var spokenName: String {
        switch self {
        case .keyboard(let shortcut): shortcut.spokenName
        case .mouse(let button): Self.mouseName(button)
        }
    }

    /// Whether this is the function key alone, which also carries the always-on double-tap hands-free trigger.
    public var isFunctionTap: Bool {
        guard case .keyboard(let shortcut) = self else { return false }
        return shortcut.keyCode == UInt32(kVK_Function) && shortcut.isModifierOnly
    }

    /// Whether hearing this trigger needs Accessibility, because it is a modifier key alone, such as fn.
    public var needsAccessibility: Bool {
        if case .keyboard(let shortcut) = self { return shortcut.isModifierOnly }
        return false
    }

    public static func mouseName(_ button: Int) -> String { L10n.tr("Mouse %ld", button + 1) }
}

/// Recognizes the fixed double-tap-function hands-free trigger, telling the model what each function-key transition means.
///
/// Holding the function key still means push to talk when it is a push-to-talk trigger; only quick taps take part here.
public struct DoubleTapTracker: Equatable, Sendable {
    /// What the model should do about any running dictation after a function-key release.
    public enum Decision: Equatable, Sendable {
        /// The release was too long to be a tap, or no press was pending.
        case longPress
        /// A quick tap that may still become a double-tap: a session it started keeps listening hands-free.
        case firstTap
        /// A second quick tap inside the window: the pair toggles hands-free dictation.
        case secondTap
    }

    private var pressStarted: Date?
    private var firstTapEnded: Date?

    /// A tap is a press and release shorter than this; two taps count as a double-tap while the gap stays under this window.
    public static let tapLimit: TimeInterval = 0.3
    public static let window: TimeInterval = 0.35

    public init() {}

    public mutating func press(_ now: Date) {
        // A stale first tap no longer takes part in a double-tap.
        if let ended = firstTapEnded, now.timeIntervalSince(ended) > Self.window { firstTapEnded = nil }
        pressStarted = now
    }

    public mutating func release(_ now: Date) -> Decision {
        guard let started = pressStarted else { return .longPress }
        pressStarted = nil
        guard now.timeIntervalSince(started) < Self.tapLimit else {
            firstTapEnded = nil
            return .longPress
        }
        if let ended = firstTapEnded {
            firstTapEnded = nil
            if now.timeIntervalSince(ended) <= Self.window { return .secondTap }
        }
        firstTapEnded = now
        return .firstTap
    }

    public mutating func reset() {
        pressStarted = nil
        firstTapEnded = nil
    }
}
