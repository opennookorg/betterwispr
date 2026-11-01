import AppKit

/// Chooses the keystroke that submits a dictation in the app it was pasted into: a rule the user wrote for that app, or
/// the Claude prompt `ClaudePrompt` recognizes on its own. Nil leaves the text pasted and unsent.
public enum SendAfterPaste {
    /// The enabled rule for a bundle identifier. A rule names its app, so it is taken over the built-in detection, which
    /// has to guess from the focused field and deliberately refuses anything it doesn't recognize.
    public static func rule(for bundleID: String?, in rules: [AppSendRule]) -> AppSendRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.isEnabled && $0.bundleID == bundleID }
    }

    @MainActor
    public static func keystroke(for app: NSRunningApplication, settings: AppSettings) async -> SendKeystroke? {
        if let rule = rule(for: app.bundleIdentifier, in: settings.sendRules) { return rule.keystroke }
        guard settings.sendToClaude, await ClaudePrompt.accepts(app) else { return nil }
        return .return
    }

    /// Electron apps only expose their fields once an assistive app asks, so a rule for one needs the same nudge
    /// `ClaudePrompt.prepare` gives Claude Desktop and VS Code. Call it before reading the focused field.
    @MainActor
    public static func prepare(_ app: NSRunningApplication, settings: AppSettings) {
        if settings.sendToClaude { ClaudePrompt.prepare(app) }
        if rule(for: app.bundleIdentifier, in: settings.sendRules) != nil { ClaudePrompt.enableManualAccessibility(app) }
    }
}
