import Darwin
import Foundation
import os

public enum NotesCLI: String, Codable, CaseIterable, Sendable {
    case claudeCode, codex

    public var name: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var loginCommand: String { self == .claudeCode ? "claude auth login" : "codex login" }
    private var command: String { self == .claudeCode ? "claude" : "codex" }

    /// Synchronous for view bodies; sees the login shell's PATH only after `locateExecutable()` has resolved it once.
    public var executable: URL? { Self.locate(command, in: Self.searchDirectories) }

    /// Resolves the login shell's PATH when the well-known folders miss, once per launch unless the shell failed, then looks the CLI up.
    @MainActor public func locateExecutable() async -> URL? {
        await locateExecutable(shell: Self.loginShell, isExecutable: Self.isExecutableFile)
    }

    @MainActor func locateExecutable(shell: String, isExecutable: (String) -> Bool) async -> URL? {
        if let found = Self.locate(command, in: Self.searchDirectories, isExecutable: isExecutable) { return found }
        if Self.loginShellResolution == nil {
            Self.loginShellResolution = Task { @MainActor in
                let path = await Self.loginShellPATH(shell: shell)
                Self.loginShellPATHCache.withLock { $0 = path }
                if path == nil { Self.loginShellResolution = nil }
            }
        }
        await Self.loginShellResolution?.value
        return Self.locate(command, in: Self.searchDirectories, isExecutable: isExecutable)
    }

    static func locate(_ command: String, in directories: [String], isExecutable: (String) -> Bool = isExecutableFile) -> URL? {
        directories.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }.first { isExecutable($0.path) }
    }

    static func isExecutableFile(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    static var searchDirectories: [String] {
        searchDirectories(home: FileManager.default.homeDirectoryForCurrentUser.path, user: NSUserName(),
                          processPATH: ProcessInfo.processInfo.environment["PATH"], loginShellPATH: loginShellPATHCache.withLock { $0 })
    }

    static func searchDirectories(home: String, user: String, processPATH: String?, loginShellPATH: String?) -> [String] {
        let wellKnown = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.nix-profile/bin",
                         "/etc/profiles/per-user/\(user)/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin"]
        return wellKnown + [processPATH, loginShellPATH].compactMap { $0 }.flatMap { $0.split(separator: ":").map(String.init) }
            .filter { $0.hasPrefix("/") }
    }

    @MainActor static func loginShellPATH(shell: String) async -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("betterwispr-shell-\(UUID())")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathFile = directory.appendingPathComponent("PATH")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "/usr/bin/printenv PATH > '\(pathFile.path)'"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { await CLINotesModel.stop(process); return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return try? String(contentsOf: pathFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var loginShell: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    }

    private static let loginShellPATHCache = OSAllocatedUnfairLock<String?>(initialState: nil)
    @MainActor private static var loginShellResolution: Task<Void, Never>?
}

struct CLINotesModel: NotesLanguageModel {
    let cli: NotesCLI
    let model: String
    var instructions = NotesWriter.instructions
    var lowLatency = false
    /// Accepts any Claude Code sign-in once its destination is confirmed; only `MeetingNotesGenerator.meetingNotesModel` sets it.
    var anySignIn = false
    var confirmedDestination: String?
    var locatedExecutable: URL?
    var settingsFiles: @Sendable () -> [Data?] = ClaudeCodeDestination.installedSettingsFiles

    func respond(to prompt: String) async throws -> String {
        try await response(to: prompt).text
    }

    private func response(to prompt: String) async throws -> (text: String, modelName: String) {
        let located: URL? = if let locatedExecutable { locatedExecutable } else { await cli.locateExecutable() }
        guard let executable = located else {
            throw MeetingNotesError.unavailable("Install \(cli.name), then sign in with \(cli.loginCommand) in Terminal.")
        }
        var destination: ClaudeCodeDestination?
        // Use the CLI's login, never extract or store its OAuth credentials in BetterWispr.
        if cli == .claudeCode {
            let status = try await Self.run(executable, arguments: ["auth", "status"], input: "", cli: cli)
            let current = try ClaudeCodeDestination(status: status, settingsFiles: settingsFiles())
            if let problem = Self.claudeSignInProblem(current, anySignIn: anySignIn, confirmed: confirmedDestination) { throw MeetingNotesError.unavailable(problem) }
            destination = current
        }
        let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chosen.count <= 200, !chosen.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MeetingNotesError.unavailable("Enter a model ID of at most 200 characters without control characters.")
        }
        let output = try await Self.run(executable, arguments: arguments + (chosen.isEmpty ? [] : ["--model", chosen]),
                                        input: "\(instructions)\n\n\(prompt)", cli: cli, finalMessage: cli == .codex)
        if cli == .claudeCode {
            guard let result = try? JSONDecoder().decode(ClaudeResult.self, from: Data(output.utf8)),
                  !result.is_error, let text = result.result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Self.failure(cli, output: output)
            }
            let actual = result.modelUsage?.keys.sorted().joined(separator: ", ") ?? ""
            let route = anySignIn ? (destination.map { " · \($0.label)" } ?? "") : ""
            return (text, "\(cli.name) · \(actual.isEmpty ? chosen : actual)\(route)")
        }
        return (output, "\(cli.name) · \(chosen)")
    }

    var arguments: [String] {
        switch cli {
        case .claudeCode:
            ["--print", "--output-format", "json", "--no-session-persistence", "--safe-mode",
             "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
             "--system-prompt", instructions] + (lowLatency ? ["--effort", "low"] : [])
                + (anySignIn ? ["--max-budget-usd", Self.spendingLimitPerRequest] : [])
        case .codex:
            ["--no-daemon", "exec", "--ignore-user-config", "--skip-git-repo-check", "--ephemeral",
             "--sandbox", "read-only", "--color", "never", "-c", "approval_policy=\"never\"",
             "-c", "forced_login_method=\"chatgpt\"", "-c", "project_doc_max_bytes=0",
             "-c", "web_search=\"disabled\"", "-c", "history.persistence=\"none\"",
             "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins",
             "--disable", "multi_agent", "--disable", "hooks", "--disable", "skill_search"]
                + (lowLatency ? ["-c", "model_reasoning_effort=\"low\""] : [])
        }
    }

    func draft(_ prompt: String) async throws -> NotesDraft {
        let response = try await response(to: "\(prompt)\n\n\(NotesDraft.fields)")
        var draft = try NotesDraft.decode(response.text)
        draft.generatedWith = response.modelName
        return draft
    }

    /// Why Claude Code may not send this request to `destination`, or nil when it may.
    static func claudeSignInProblem(_ destination: ClaudeCodeDestination, anySignIn: Bool, confirmed: String?) -> String? {
        if anySignIn {
            guard destination.label != confirmed else { return nil }
            return "Confirm that Claude Code may send meeting text to \(destination.label) in Models > Meeting notes, then try again. Nothing was sent."
        }
        guard !destination.isSubscription else { return nil }
        return "Claude Code sends to \(destination.label), not only your Claude subscription, so nothing was sent. Run claude auth login in Terminal and remove any custom base URL. For meeting notes only, you can instead turn on Allow any Claude Code sign-in in Models."
    }

    private static let spendingLimitPerRequest = "1.00"

    private struct ClaudeResult: Decodable {
        struct Usage: Decodable {}
        var is_error: Bool
        var result: String?
        var modelUsage: [String: Usage]?
    }

    private struct ClaudeStop: Decodable { var subtype: String? }

    private static func failure(_ cli: NotesCLI, output: String? = nil) -> MeetingNotesError {
        if let output, (try? JSONDecoder().decode(ClaudeStop.self, from: Data(output.utf8)))?.subtype == "error_max_budget_usd" {
            return .unavailable("\(cli.name) stopped at BetterWispr’s spending limit of about $\(spendingLimitPerRequest) per request. Your meeting is still saved.")
        }
        return .unavailable("\(cli.name) couldn’t write notes. Update the CLI, check your usage limits or spending cap and model, and sign in with \(cli.loginCommand) in Terminal. Your meeting is still saved.")
    }

    /// File-backed stdio avoids pipe deadlocks. All Process access stays on the main actor;
    /// waiting suspends, and cancellation terminates the child before deleting its private files.
    @MainActor
    static func run(_ executable: URL, arguments: [String], input: String, cli: NotesCLI,
                    finalMessage: Bool = false, timeout: Duration = .seconds(600),
                    until: (@MainActor (String) -> Bool)? = nil) async throws -> String {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("betterwispr-notes-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        let finalURL = directory.appendingPathComponent("reply")
        try Data(input.utf8).write(to: inputURL, options: .atomic)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process()
        let controlInput = until == nil ? nil : Pipe()
        defer { try? controlInput?.fileHandleForWriting.close(); try? controlInput?.fileHandleForReading.close() }
        process.executableURL = executable
        process.arguments = arguments + (finalMessage ? ["--output-last-message", finalURL.path, "-"] : [])
        process.currentDirectoryURL = directory
        // Prevent inherited API keys or provider URLs from changing the route; Claude Code's settings files still apply, so ClaudeCodeDestination reads them.
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "CLAUDE_CONFIG_DIR"]
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["PATH"] = ([executable.deletingLastPathComponent().path] + NotesCLI.searchDirectories + ["/usr/bin", "/bin"]).joined(separator: ":")
        process.environment = environment
        if let controlInput { process.standardInput = controlInput } else { process.standardInput = stdin }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var completed: String?
        do {
            // Discovery requests are small JSON messages. Keep stdin open until the reply arrives.
            if let controlInput { try controlInput.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw MeetingNotesError.unavailable("\(cli.name) took too long to respond. Try again; your meeting is still saved.")
                }
                let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw Self.failure(cli) }
                if let until {
                    let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
                    if until(output) { completed = output; break }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            await stop(process)
            throw error
        }
        if let completed {
            try? controlInput?.fileHandleForWriting.close()
            await stop(process)
            try Task.checkCancellation()
            return completed
        }
        guard process.terminationStatus == 0 else { throw Self.failure(cli, output: try? String(contentsOf: outputURL, encoding: .utf8)) }
        let text = try String(contentsOf: finalMessage ? finalURL : outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Self.failure(cli) }
        return text
    }

    @MainActor static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        // Cleanup must finish even when the calling task is cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        while process.isRunning {
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
        }
    }
}
