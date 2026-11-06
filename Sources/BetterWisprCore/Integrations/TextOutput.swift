import AppKit
import ApplicationServices
import Carbon.HIToolbox

public enum OutputResult: Sendable, Equatable {
    case copied
    case copiedForManualPaste
    case pasted(into: String)
}

@MainActor
public protocol TextOutputIntegration {
    func deliver(_ text: String, to target: NSRunningApplication?) async throws -> OutputResult
}

@MainActor
public struct ClipboardIntegration: TextOutputIntegration {
    public init() {}
    public func deliver(_ text: String, to target: NSRunningApplication?) async throws -> OutputResult {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw OutputError.clipboard }
        return .copied
    }
}

@MainActor
public struct FocusedAppIntegration: TextOutputIntegration {
    private static var pendingRestore: (contents: (items: [NSPasteboardItem], changeCount: Int), task: Task<Void, Never>)?
    private static let screenSharing = "com.apple.ScreenSharing"
    public let keepsCopy: Bool
    private let expectedFocus: AXUIElement?
    public init(keepsCopy: Bool, expectedFocus: AXUIElement? = nil) {
        self.keepsCopy = keepsCopy
        self.expectedFocus = expectedFocus
    }
    public func deliver(_ text: String, to target: NSRunningApplication?) async throws -> OutputResult {
        try Task.checkCancellation()
        // Never steal focus or paste into an app the user switched to while decoding.
        guard let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              AXIsProcessTrusted(),
              Self.focusMatches(expectedFocus, current: Self.focusedElement(in: target)) else {
            _ = try await ClipboardIntegration().deliver(text, to: nil)
            return .copiedForManualPaste
        }
        let pasteboard = NSPasteboard.general
        let previousItems = Self.clipboardItems(pasteboard, pending: Self.pendingRestore?.contents)
        Self.pendingRestore?.task.cancel()
        Self.pendingRestore = nil
        _ = try await ClipboardIntegration().deliver(text, to: target)
        let ourChange = pasteboard.changeCount
        let isScreenSharing = target.bundleIdentifier == Self.screenSharing
        if isScreenSharing, !(await Self.sendClipboard(through: target, while: {
            !Task.isCancelled && pasteboard.changeCount == ourChange
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
                && Self.focusMatches(expectedFocus, current: Self.focusedElement(in: target))
        })) { return .copiedForManualPaste }
        try Task.checkCancellation()
        guard pasteboard.changeCount == ourChange,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              Self.focusMatches(expectedFocus, current: Self.focusedElement(in: target)),
              let events = Self.pasteKeystroke() else { return .copiedForManualPaste }
        for event in events { event.postToPid(target.processIdentifier) }
        if !keepsCopy, !isScreenSharing {
            Self.pendingRestore = ((previousItems, ourChange), Task {
                // ponytail: applications expose no paste acknowledgement; allow 750 ms before restoring.
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                Self.pendingRestore = nil
                if pasteboard.changeCount == ourChange {
                    pasteboard.clearContents()
                    if !previousItems.isEmpty { _ = pasteboard.writeObjects(previousItems) }
                }
            })
        }
        return .pasted(into: target.localizedName ?? "your app")
    }

    /// Posts `keystroke` to `target` only while it is still the frontmost app with the field the dictation started in.
    public func press(_ keystroke: SendKeystroke, in target: NSRunningApplication, requiringRecordedFocus: Bool) -> Bool {
        guard !Task.isCancelled, !target.isTerminated, AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              Self.sendFocusMatches(expectedFocus, current: Self.focusedElement(in: target), requiringRecorded: requiringRecordedFocus),
              let events = Self.keystrokeEvents(for: keystroke) else { return false }
        for event in events { event.postToPid(target.processIdentifier) }
        return true
    }

    static let leftCommandDeviceFlag = CGEventFlags(rawValue: 0x8)

    /// The device-dependent bits a real keyboard sets alongside each modifier mask, for the left-hand key.
    private static let modifierKeys: [(modifier: ShortcutModifiers, virtualKey: CGKeyCode, flags: CGEventFlags)] = [
        (.control, CGKeyCode(kVK_Control), [.maskControl, CGEventFlags(rawValue: 0x1)]),
        (.option, CGKeyCode(kVK_Option), [.maskAlternate, CGEventFlags(rawValue: 0x20)]),
        (.shift, CGKeyCode(kVK_Shift), [.maskShift, CGEventFlags(rawValue: 0x2)]),
        (.command, CGKeyCode(kVK_Command), [.maskCommand, leftCommandDeviceFlag]),
    ]

    /// A keystroke as a physical keyboard sends it: each modifier pressed as its own flags-changed event, the key, then the
    /// modifiers released. Every event carries explicit flags, so modifiers still held from the dictation shortcut can't
    /// turn a bare Return into Option- or Shift-Return. For ⌘V this produces exactly `pasteKeystroke`.
    static func keystrokeEvents(for keystroke: SendKeystroke) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        let held = modifierKeys.filter { keystroke.modifiers.contains($0.modifier) }
        var flags: CGEventFlags = []
        var events: [CGEvent] = []
        for modifier in held {
            flags.formUnion(modifier.flags)
            guard let press = CGEvent(keyboardEventSource: source, virtualKey: modifier.virtualKey, keyDown: true) else { return nil }
            press.type = .flagsChanged
            press.flags = flags
            events.append(press)
        }
        guard let keyCode = CGKeyCode(exactly: keystroke.keyCode),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        events += [down, up]
        for modifier in held.reversed() {
            flags.subtract(modifier.flags)
            guard let release = CGEvent(keyboardEventSource: source, virtualKey: modifier.virtualKey, keyDown: false) else { return nil }
            release.type = .flagsChanged
            release.flags = flags
            events.append(release)
        }
        return events
    }

    /// Presses Screen Sharing's Send Clipboard, turning Use Shared Clipboard off around it because that setting disables the item.
    static func sendClipboard(through app: NSRunningApplication, while isCurrent: () -> Bool) async -> Bool {
        guard let send = menuItem(sendClipboardKey, of: app) else { return false }
        if send.bool(kAXEnabledAttribute) == true { return isCurrent() && press(send) }
        guard let shared = menuItem(sharedClipboardKey, of: app), shared.bool(kAXEnabledAttribute) == true,
              !(shared.string(kAXMenuItemMarkCharAttribute) ?? "").isEmpty, press(shared) else { return false }
        let sent = await becomesEnabled(send) && isCurrent() && press(send)
        if (shared.string(kAXMenuItemMarkCharAttribute) ?? "").isEmpty { _ = press(shared) }
        return sent
    }

    static let sendClipboardKey = "281.title"
    static let sharedClipboardKey = "100521.title"

    /// A menu item's title in every language the app ships, from its `MainMenu.loctable`.
    static func menuTitles(_ key: String, in bundle: URL?) -> Set<String> {
        guard let url = bundle?.appendingPathComponent("Contents/Resources/MainMenu.loctable"),
              let tables = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        return Set(tables.values.compactMap { ($0 as? [String: Any])?[key] as? String })
    }

    private static func menuItem(_ key: String, of app: NSRunningApplication) -> AXUIElement? {
        let titles = menuTitles(key, in: app.bundleURL)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let menus = root.element(kAXMenuBarAttribute)?.elements(kAXChildrenAttribute).flatMap { $0.elements(kAXChildrenAttribute) } ?? []
        return menus.lazy.flatMap { $0.elements(kAXChildrenAttribute) }.first { titles.contains($0.string(kAXTitleAttribute) ?? "") }
    }

    private static func press(_ item: AXUIElement) -> Bool { AXUIElementPerformAction(item, kAXPressAction as CFString) == .success }

    /// Waits for AppKit, which refreshes menu state for Accessibility about once a second and ignores presses on stale disabled items.
    private static func becomesEnabled(_ item: AXUIElement) async -> Bool {
        for _ in 0..<40 where !Task.isCancelled {
            if item.bool(kAXEnabledAttribute) == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Command-V as a physical keyboard sends it, with left Command pressed and released as its own events.
    static func pasteKeystroke() -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else { return nil }
        commandDown.type = .flagsChanged
        commandUp.type = .flagsChanged
        let leftCommand: CGEventFlags = [.maskCommand, leftCommandDeviceFlag]
        commandDown.flags = leftCommand
        vDown.flags = leftCommand
        vUp.flags = leftCommand
        commandUp.flags = []
        return [commandDown, vDown, vUp, commandUp]
    }

    public static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
        guard let app, AXIsProcessTrusted(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element.element(kAXFocusedUIElementAttribute)
    }

    static func focusMatches(_ expected: AXUIElement?, current: AXUIElement?) -> Bool {
        guard let expected else { return true }
        return current.map { CFEqual(expected, $0) } ?? false
    }

    /// Whether a send may fire: Send to Claude needs a recorded field to compare, while a rule also accepts an app that exposed none.
    static func sendFocusMatches(_ expected: AXUIElement?, current: AXUIElement?, requiringRecorded: Bool) -> Bool {
        (expected != nil || !requiringRecorded) && focusMatches(expected, current: current)
    }

    static func clipboardItems(_ pasteboard: NSPasteboard, pending: (items: [NSPasteboardItem], changeCount: Int)?) -> [NSPasteboardItem] {
        if let pending, pasteboard.changeCount == pending.changeCount { return pending.items }
        return pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }
}

public enum OutputError: LocalizedError {
    case clipboard
    public var errorDescription: String? { "Could not write to the clipboard. Your transcript is still available in BetterWispr." }
}
