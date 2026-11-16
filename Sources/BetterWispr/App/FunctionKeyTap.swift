import AppKit
import BetterWisprCore
import Carbon.HIToolbox
@preconcurrency import CoreGraphics
import OSLog

/// Consumes the fn key (keycode 63) and the separate Globe key pair (keycode 179) macOS 26 sends, so macOS's
/// "Press 🌐 key to" actions never fire. A fn press held for a chord is put back before the chord key.
@MainActor
final class FunctionKeyTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapProxy: CGEventTapProxy?
    private var heldDownEvent: CGEvent?
    private(set) var heldDownPutBack = false
    private var fnDownAt: Date?
    private static let globeKeyCode: Int64 = 179
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        heldDownEvent = nil
        heldDownPutBack = false
        fnDownAt = nil
        // An active tap needs Accessibility; Input Monitoring is what delivers keyboard events to it.
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeUnknown:
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case kIOHIDAccessTypeDenied:
            Logger(subsystem: "org.betterwispr.app", category: "FunctionKeyTap").info("Input Monitoring is off, so the function key tap stays down.")
            return
        default: break
        }
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            MainActor.assumeIsolated {
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<FunctionKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                guard let handled = tap.handle(proxy, type, event) else { return nil }
                return Unmanaged.passUnretained(handled)
            }
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Logger(subsystem: "org.betterwispr.app", category: "FunctionKeyTap").error("Couldn't create the function key tap.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        Logger(subsystem: "org.betterwispr.app", category: "FunctionKeyTap").info("Function key tap active.")
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        tapProxy = nil
        heldDownEvent = nil
        heldDownPutBack = false
        fnDownAt = nil
    }

    /// Returns the event to let through, or nil when the tap consumes it. A nil proxy is for tests.
    func handle(_ proxy: CGEventTapProxy?, _ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        tapProxy = proxy
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            heldDownEvent = nil
            heldDownPutBack = false
            fnDownAt = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // The 63 flagsChanged pair drives onPress; 179 is the Globe action macOS 26 sends after it.
        if keycode == Self.globeKeyCode, type == .keyDown || type == .keyUp {
            return nil
        }
        guard keycode == Int64(kVK_Function) else {
            putBackHeldDownIfNeeded()
            return event
        }
        let down = event.flags.contains(.maskSecondaryFn)
        if down {
            fnDownAt = Date()
            heldDownEvent = event.copy()
            heldDownPutBack = false
            onPress?()
            return nil
        }
        let held = fnDownAt.map { Date().timeIntervalSince($0) }
        fnDownAt = nil
        let wasChord = heldDownPutBack
        onRelease?()
        if wasChord {
            heldDownEvent = nil
            heldDownPutBack = false
            return event
        }
        heldDownEvent = nil
        Logger(subsystem: "org.betterwispr.app", category: "FunctionKeyTap").info("Kept a lone function-key tap from macOS after \(held ?? 0, format: .fixed(precision: 2))s.")
        return nil
    }

    /// A key arrived while the consumed fn press was held: put it back ahead of the chord key.
    private func putBackHeldDownIfNeeded() {
        guard !heldDownPutBack, let down = heldDownEvent else { return }
        heldDownPutBack = true
        if let proxy = tapProxy { down.tapPostEvent(proxy) }
    }
}
