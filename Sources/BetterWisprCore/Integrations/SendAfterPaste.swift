import AppKit
import Carbon.HIToolbox

/// Chooses the keystroke that submits a dictation in the app it was pasted into: a rule the user wrote for that app, or
/// the Claude prompt `ClaudePrompt` recognizes on its own. Nil leaves the text pasted and unsent.
public enum SendAfterPaste {
    /// The enabled rule that may fire in an app, which is taken over the built-in detection because it names its app.
    @MainActor
    public static func rule(for bundleID: String?, settings: AppSettings) -> AppSendRule? {
        guard let bundleID, allowsRule(for: bundleID) else { return nil }
        return settings.sendRules.first {
            $0.isEnabled && $0.bundleID == bundleID && refusal(of: $0.keystroke, shortcut: settings.shortcut) == nil
        }
    }

    /// A key sent to a terminal could run a shell command, so only Send to Claude's foreground process check sends there.
    public static func allowsRule(for bundleID: String) -> Bool {
        !ClaudePrompt.scriptableTerminals.contains(bundleID)
    }

    /// Why a key can't be a send key, checked when recording and before sending since a saved rule can outlive either check.
    @MainActor
    public static func refusal(of keystroke: SendKeystroke, shortcut: DictationShortcut) -> String? {
        let name = keystroke.displayName
        let keyCode = Int(keystroke.keyCode)
        if [kVK_Delete, kVK_ForwardDelete].contains(keyCode) { return "\(name) would erase what you dictated." }
        let quitsOrCloses = [kVK_ANSI_Q, kVK_ANSI_W].contains(keyCode) || ["Q", "W"].contains(keystroke.key.uppercased())
        if keystroke.modifiers.contains(.command), quitsOrCloses { return "\(name) could quit the app or close its window." }
        return clashes(keystroke, with: shortcut) ? "\(name) clashes with your dictation shortcut, \(shortcut.displayName)." : nil
    }

    /// The hot key also listens with Shift while sending is on, and a posted modifier always comes from its left-hand key.
    @MainActor
    private static func clashes(_ keystroke: SendKeystroke, with shortcut: DictationShortcut) -> Bool {
        if shortcut.isModifierOnly {
            return FocusedAppIntegration.modifierKeys.contains {
                UInt32($0.virtualKey) == shortcut.keyCode && keystroke.modifiers.contains($0.modifier)
            }
        }
        return keystroke.keyCode == shortcut.keyCode && [shortcut.modifiers, shortcut.modifiers.union(.shift)].contains(keystroke.modifiers)
    }

    @MainActor
    public static func keystroke(for app: NSRunningApplication, settings: AppSettings) async -> SendKeystroke? {
        if let rule = rule(for: app.bundleIdentifier, settings: settings) { return rule.keystroke }
        guard settings.sendToClaude, await ClaudePrompt.accepts(app) else { return nil }
        return .return
    }

    /// Electron apps only expose their fields once an assistive app asks, so a rule for one needs the same nudge
    /// `ClaudePrompt.prepare` gives Claude Desktop and VS Code. Call it before reading the focused field.
    @MainActor
    public static func prepare(_ app: NSRunningApplication, settings: AppSettings) {
        if settings.sendToClaude { ClaudePrompt.prepare(app) }
        if rule(for: app.bundleIdentifier, settings: settings) != nil { ClaudePrompt.enableManualAccessibility(app) }
    }
}
