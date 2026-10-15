import AppKit
import ApplicationServices

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
    private static var pendingRestore: (items: [NSPasteboardItem], task: Task<Void, Never>)?
    private static let screenSharing = "com.apple.ScreenSharing"
    public let keepsCopy: Bool
    public init(keepsCopy: Bool) { self.keepsCopy = keepsCopy }
    public func deliver(_ text: String, to target: NSRunningApplication?) async throws -> OutputResult {
        // Never steal focus or paste into an app the user switched to while decoding.
        guard let target, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              AXIsProcessTrusted() else {
            _ = try await ClipboardIntegration().deliver(text, to: nil)
            return .copiedForManualPaste
        }
        let pasteboard = NSPasteboard.general
        let previousItems: [NSPasteboardItem] = Self.pendingRestore?.items ?? pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        Self.pendingRestore?.task.cancel()
        Self.pendingRestore = nil
        _ = try await ClipboardIntegration().deliver(text, to: target)
        let ourChange = pasteboard.changeCount
        let isScreenSharing = target.bundleIdentifier == Self.screenSharing
        if isScreenSharing, !(await Self.sendClipboard(through: target)) { return .copiedForManualPaste }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let events = Self.pasteKeystroke() else { return .copiedForManualPaste }
        for event in events { event.postToPid(target.processIdentifier) }
        if !keepsCopy, !isScreenSharing {
            Self.pendingRestore = (previousItems, Task {
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

    static let leftCommandDeviceFlag = CGEventFlags(rawValue: 0x8)

    /// Presses Screen Sharing's Send Clipboard, turning Use Shared Clipboard off around it because that setting disables the item.
    static func sendClipboard(through app: NSRunningApplication) async -> Bool {
        guard let send = menuItem(sendClipboardKey, of: app) else { return false }
        if send.bool(kAXEnabledAttribute) == true { return press(send) }
        guard let shared = menuItem(sharedClipboardKey, of: app), shared.bool(kAXEnabledAttribute) == true,
              !(shared.string(kAXMenuItemMarkCharAttribute) ?? "").isEmpty, press(shared) else { return false }
        let sent = await becomesEnabled(send) && press(send)
        _ = press(shared)
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
}

public enum OutputError: LocalizedError {
    case clipboard
    public var errorDescription: String? { "Could not write to the clipboard. Your transcript is still available in BetterWispr." }
}
