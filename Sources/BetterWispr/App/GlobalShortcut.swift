import AppKit
import BetterWisprCore
import Carbon
import IOKit.hidsystem
import OSLog

@MainActor
final class GlobalShortcut {
    private let identifier: EventHotKeyID
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var modifierPressed = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    init(id: UInt32 = 1) {
        identifier = EventHotKeyID(signature: 0x42575350, id: id)
    }

    isolated deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcut: DictationShortcut) throws {
        unregister()
        if shortcut.isModifierOnly {
            guard AXIsProcessTrusted() else { throw ShortcutError.accessibilityRequired }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.handleModifierEvent(event, shortcut: shortcut) }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.handleModifierEvent(event, shortcut: shortcut) }
            }
            guard localMonitor != nil, globalMonitor != nil else {
                unregister()
                throw ShortcutError.monitorUnavailable
            }
            return
        }
        guard register(keyCode: shortcut.keyCode, modifiers: [shortcut.modifiers]) else { throw ShortcutError.unavailable(shortcut) }
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: [ShortcutModifiers]) -> Bool {
        unregister()
        guard installHandler() else { return false }
        for modifier in modifiers {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(keyCode, modifier.rawValue, identifier, GetApplicationEventTarget(), 0, &hotKey)
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                Logger(subsystem: "org.betterwispr.app", category: "GlobalShortcut").error("Hot key registration failed: id=\(self.identifier.id) keyCode=\(keyCode) modifiers=\(modifier.symbols, privacy: .public) status=\(status)")
            }
        }
        return hotKeys.count == modifiers.count
    }

    func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        modifierPressed = false
    }

    func handleModifierEvent(_ event: NSEvent, shortcut: DictationShortcut) {
        guard event.type == .flagsChanged, event.keyCode == shortcut.keyCode,
              let mask = Self.modifierMasks[Int(shortcut.keyCode)] else { return }
        let pressed = event.modifierFlags.rawValue & UInt(mask) != 0
        guard pressed != modifierPressed else { return }
        // Only start with this modifier alone; always deliver its matching release.
        if pressed {
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command, .function])
            let ownFlag: NSEvent.ModifierFlags = switch DictationShortcut.modifier(for: shortcut.keyCode) {
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            case .function: .function
            default: []
            }
            guard flags == ownFlag else { return }
        }
        modifierPressed = pressed
        (pressed ? onPress : onRelease)?()
    }

    private static let modifierMasks: [Int: Int32] = [
        kVK_Control: NX_DEVICELCTLKEYMASK, kVK_RightControl: NX_DEVICERCTLKEYMASK,
        kVK_Option: NX_DEVICELALTKEYMASK, kVK_RightOption: NX_DEVICERALTKEYMASK,
        kVK_Shift: NX_DEVICELSHIFTKEYMASK, kVK_RightShift: NX_DEVICERSHIFTKEYMASK,
        kVK_Command: NX_DEVICELCMDKEYMASK, kVK_RightCommand: NX_DEVICERCMDKEYMASK,
        kVK_Function: NX_SECONDARYFNMASK
    ]

    func handle(_ event: EventRef) -> OSStatus {
        var received = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
              received.signature == identifier.signature, received.id == identifier.id else { return OSStatus(eventNotHandledErr) }
        (GetEventKind(event) == UInt32(kEventHotKeyPressed) ? onPress : onRelease)?()
        return noErr
    }

    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().handle(event) }
        }, specs.count, &specs, context, &handler) == noErr
    }
}

enum ShortcutError: LocalizedError {
    case unavailable(DictationShortcut)
    case accessibilityRequired
    case monitorUnavailable
    case alreadyAssigned(DictationShortcut)
    case needsKey
    case cancelsDictation
    var errorDescription: String? {
        switch self {
        case .unavailable(let shortcut): "\(shortcut.displayName) is used by another app."
        case .accessibilityRequired: "Allow Accessibility in Settings to use a modifier key by itself."
        case .monitorUnavailable: "Couldn’t listen for the modifier key. Try choosing the shortcut again."
        case .alreadyAssigned(let shortcut): "\(shortcut.displayName) is already BetterWispr’s other shortcut."
        case .needsKey: "This shortcut needs a key, not a modifier alone."
        case .cancelsDictation: "Esc cancels a dictation, so this shortcut can’t use it."
        }
    }
}
