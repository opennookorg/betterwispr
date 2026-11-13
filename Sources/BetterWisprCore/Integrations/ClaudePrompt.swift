import AppKit
import ApplicationServices
import Darwin

/// Recognizes a focused Claude prompt, where Send to Claude presses Return after pasting. In a terminal or editor
/// Return could run a shell command or edit a file, so anything it can't recognize doesn't get Return.
public enum ClaudePrompt {
    /// Long enough to start another dictation that adds to this one before it is sent.
    public static let defaultDelay = 1_000
    public static let delayChoices = [120, 250, 500, 1_000, 2_000]

    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let vsCode = "com.microsoft.VSCode"
    /// Terminals that report their focused tab's device through Apple Events once the user allows it.
    public static let scriptableTerminals = ["com.apple.Terminal", "com.googlecode.iterm2"]

    /// Electron apps only expose their fields, and VS Code only labels its terminals and Claude Code panel, once an
    /// assistive app asks. Call it before reading the focused field, since the app builds its tree afterwards.
    @MainActor
    public static func prepare(_ app: NSRunningApplication) {
        guard [claudeDesktop, vsCode].contains(app.bundleIdentifier) else { return }
        enableManualAccessibility(app)
    }

    /// Asks an app to build its full accessibility tree. Apps that don't honour the attribute ignore it.
    @MainActor
    public static func enableManualAccessibility(_ app: NSRunningApplication) {
        AXUIElementSetAttributeValue(element(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Whether Return in the app's focused field submits a Claude prompt. Terminal and iTerm2 are asked off the main thread.
    @MainActor
    public static func accepts(_ app: NSRunningApplication) async -> Bool {
        let pid = app.processIdentifier
        switch app.bundleIdentifier {
        case claudeDesktop:
            // Not a button or a menu, where Return would confirm something instead.
            return isTextInput(role: element(pid).element(kAXFocusedUIElementAttribute)?.string(kAXRoleAttribute))
        case vsCode:
            guard let focused = element(pid).element(kAXFocusedUIElementAttribute) else { return false }
            let classes = focused.strings("AXDOMClassList")
            let description = focused.string(kAXDescriptionAttribute) ?? ""
            if isClaudeCodePanel(description: description, classes: classes) { return true }
            return false
        case let bundleID? where scriptableTerminals.contains(bundleID):
            guard let device = await focusedTerminalDevice(bundleID) else { return false }
            return foregroundProcesses(onDevice: device, in: processTable()).contains(where: isClaudeCode)
        default:
            return false
        }
    }

    /// An unresponsive app must not hold up the main thread for the default six seconds.
    private static func element(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }

    static func isTextInput(role: String?) -> Bool {
        role == kAXTextAreaRole
    }

    /// The Claude Code extension's prompt box, a web view text area labelled "Message input".
    static func isClaudeCodePanel(description: String, classes: [String]) -> Bool {
        description == "Message input" && classes.contains { $0.hasPrefix("messageInput_") }
    }

    // MARK: Terminal and iTerm2

    /// Asks macOS once for permission to read the focused tab of each scriptable terminal that is open.
    @concurrent
    public static func requestTerminalPermission() async {
        for bundleID in scriptableTerminals {
            guard let target = AppleEventTarget.descriptor(for: bundleID) else { continue }
            AppleEventTarget.allowed(target, askingUser: true)
        }
    }

    /// Nil when the terminal isn't open, so its permission can't be checked yet.
    @concurrent
    public static func terminalAllowed(_ bundleID: String) async -> Bool? {
        AppleEventTarget.descriptor(for: bundleID).map { AppleEventTarget.allowed($0, askingUser: false) }
    }

    /// Reads the focused tab's device, such as /dev/ttys003, without ever prompting during a dictation.
    @concurrent
    private static func focusedTerminalDevice(_ bundleID: String) async -> dev_t? {
        guard let target = AppleEventTarget.descriptor(for: bundleID), AppleEventTarget.allowed(target, askingUser: false) else { return nil }
        // Codes from each app's scripting dictionary: Terminal's `tty of selected tab of window 1`,
        // and iTerm2's `tty of current session of current window`.
        let tty = bundleID == "com.apple.Terminal"
            ? AppleEventTarget.property("ttty", of: AppleEventTarget.property("tcnt", of: AppleEventTarget.element("cwin", at: 1)))
            : AppleEventTarget.property("Stty", of: AppleEventTarget.property("Wcsn", of: AppleEventTarget.property("Crwn")))
        guard let path = AppleEventTarget.get(tty, from: target)?.stringValue, path.hasPrefix("/dev/") else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_rdev
    }

    // MARK: Processes

    struct ProcessEntry: Equatable {
        var pid: pid_t
        var parent: pid_t
        var command: String
        /// The controlling terminal's device, or nil without one.
        var device: dev_t?
        /// In the foreground process group of its terminal, so it receives what is typed there.
        var isForeground: Bool
    }

    static func foregroundProcesses(onDevice device: dev_t, in table: [ProcessEntry]) -> [ProcessEntry] {
        table.filter { $0.isForeground && $0.device == device }
    }

    private static func isClaudeCode(_ process: ProcessEntry) -> Bool {
        process.command == "claude" || commandLine(of: process.pid).map(isClaudeCode) == true
    }

    /// The native installer runs a versioned binary such as ~/.local/share/claude/versions/2.1.308, whose process name is
    /// its version, and an npm install runs node with Claude Code's script, so the name alone isn't enough.
    static func isClaudeCode(executable: String, arguments: [String]) -> Bool {
        executable.contains("/claude/versions/") || (executable as NSString).lastPathComponent == "claude"
            || arguments.prefix(2).contains { ($0 as NSString).lastPathComponent == "claude" || $0.contains("@anthropic-ai/claude-code/") }
    }

    /// The executable path and arguments of a process, read from the kernel's copy of its argument area.
    private static func commandLine(of pid: pid_t) -> (executable: String, arguments: [String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc, the executable path, padding NULs, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let executable = strings.first else { return nil }
        return (executable, Array(strings.dropFirst().prefix(Int(max(argc, 0)))))
    }

    private static func processTable() -> [ProcessEntry] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Leave room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride).map { process in
            let command = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let device = process.kp_eproc.e_tdev == -1 ? nil : process.kp_eproc.e_tdev // NODEV
            return ProcessEntry(pid: process.kp_proc.p_pid, parent: process.kp_eproc.e_ppid, command: command, device: device,
                                isForeground: device != nil && process.kp_eproc.e_pgid == process.kp_eproc.e_tpgid)
        }
    }
}
