import Carbon.HIToolbox
import Foundation

/// A keystroke posted after pasting to submit a prompt; never a hot key, so a bare Return or Tab is allowed.
public struct SendKeystroke: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers
    public let key: String

    public static let `return` = SendKeystroke(validKeyCode: UInt32(kVK_Return), modifiers: [], key: "Return")

    public init?(keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        // A modifier on its own submits nothing, and Fn isn't a flag a posted event can hold.
        guard !key.isEmpty, DictationShortcut.modifier(for: keyCode) == nil, !modifiers.contains(.function) else { return nil }
        self.init(validKeyCode: keyCode, modifiers: modifiers, key: key)
    }

    private init(validKeyCode keyCode: UInt32, modifiers: ShortcutModifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let keystroke = SendKeystroke(keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                                            modifiers: try container.decode(ShortcutModifiers.self, forKey: .modifiers),
                                            key: try container.decode(String.self, forKey: .key)) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container,
                                                   debugDescription: "A send keystroke needs a key that isn’t a modifier on its own.")
        }
        self = keystroke
    }

    public var displayName: String { modifiers.isEmpty ? key : modifiers.symbols + " " + key }
    public var spokenName: String { (modifiers.spokenNames + [key]).joined(separator: " ") }
}

/// Posts `keystroke` after a dictation is pasted into the app with this bundle identifier, whatever its focused field is.
/// The user writes these, so they are trusted over the Claude prompts `ClaudePrompt` recognizes on its own.
public struct AppSendRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var keystroke: SendKeystroke
    public var isEnabled: Bool

    public init(id: UUID = UUID(), bundleID: String = "", keystroke: SendKeystroke = .return, isEnabled: Bool = true) {
        self.id = id
        self.bundleID = bundleID
        self.keystroke = keystroke
        self.isEnabled = isEnabled
    }
}
