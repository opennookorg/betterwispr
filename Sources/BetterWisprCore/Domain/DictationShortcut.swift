import Carbon.HIToolbox
import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 8)
    public static let shift = ShortcutModifiers(rawValue: 1 << 9)
    public static let option = ShortcutModifiers(rawValue: 1 << 11)
    public static let control = ShortcutModifiers(rawValue: 1 << 12)
    /// Only ever held by a standalone Fn shortcut; Carbon hot keys can't use it.
    public static let function = ShortcutModifiers(rawValue: 1 << 17)

    fileprivate static let names: [(modifier: ShortcutModifiers, symbol: String, spoken: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
        (.function, "fn", "Fn")
    ]

    fileprivate var activeNames: [(modifier: ShortcutModifiers, symbol: String, spoken: String)] {
        Self.names.filter { contains($0.modifier) }
    }

    public var symbols: String { activeNames.map(\.symbol).joined() }
    public var spokenNames: [String] { activeNames.map(\.spoken) }
}

public struct DictationShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    public let key: String

    public static let optionSpace = DictationShortcut(validKeyCode: 49, modifiers: .option, key: "Space")
    public static let f5 = DictationShortcut(validKeyCode: UInt32(kVK_F5), modifiers: [], key: "F5")
    private static let functionKeyCodes = Set([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                                               kVK_F20].map(UInt32.init))

    public init?(keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        guard !key.isEmpty else { return nil }
        if Self.modifier(for: keyCode) != nil {
            guard modifiers.isEmpty else { return nil }
        } else {
            guard Self.functionKeyCodes.contains(keyCode) || !modifiers.isDisjoint(with: [.control, .option, .command]) else { return nil }
        }
        self.init(validKeyCode: keyCode, modifiers: modifiers, key: key)
    }

    public static func modifier(for keyCode: UInt32) -> ShortcutModifiers? {
        switch Int(keyCode) {
        case kVK_Control, kVK_RightControl: .control
        case kVK_Option, kVK_RightOption: .option
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Command, kVK_RightCommand: .command
        case kVK_Function: .function
        default: nil
        }
    }

    public var isModifierOnly: Bool { modifiers.isEmpty && Self.modifier(for: keyCode) != nil }

    /// Whether Shift is part of the shortcut, so it can't also mean "paste without pressing Return".
    public var usesShift: Bool { modifiers.union(Self.modifier(for: keyCode) ?? []).contains(.shift) }

    public var cancelModifiers: [ShortcutModifiers] {
        let held = modifiers.union(Self.modifier(for: keyCode) ?? []).subtracting(.function)
        guard !held.isEmpty, !held.contains(.command), keyCode != UInt32(kVK_Escape) else { return [[]] }
        return [[], held]
    }

    private init(validKeyCode keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let shortcut = DictationShortcut(keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                                               modifiers: try container.decode(ShortcutModifiers.self, forKey: .modifiers),
                                               key: try container.decode(String.self, forKey: .key)) else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container,
                                                   debugDescription: "A shortcut needs a modifier key or Fn alone, Control, Option or Command with a key, or a function key.")
        }
        self = shortcut
    }

    public static func localizedKeyName(keyCode: UInt32, fallback: String) -> String {
        let name: String? = switch Int(keyCode) {
        case kVK_Control: "Left Control"
        case kVK_RightControl: "Right Control"
        case kVK_Option: "Left Option"
        case kVK_RightOption: "Right Option"
        case kVK_Shift: "Left Shift"
        case kVK_RightShift: "Right Shift"
        case kVK_Command: "Left Command"
        case kVK_RightCommand: "Right Command"
        case kVK_Function: "Fn"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_Escape: "Esc"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        default: nil
        }
        return name.map { L10n.tr($0, table: "ShortcutKey") } ?? fallback
    }

    private var localizedKey: String { Self.localizedKeyName(keyCode: keyCode, fallback: key) }

    public var displayName: String { modifiers.isEmpty ? localizedKey : modifiers.symbols + " " + localizedKey }
    public var spokenName: String { (modifiers.activeNames.map { L10n.tr($0.spoken) } + [localizedKey]).joined(separator: " ") }
}
