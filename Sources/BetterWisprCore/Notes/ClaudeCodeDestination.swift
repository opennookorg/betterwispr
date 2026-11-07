import Foundation

/// Where Claude Code says it sends text, from `claude auth status` and its settings files; reading it sends no text.
public struct ClaudeCodeDestination: Equatable, Sendable {
    public let label: String
    let isSubscription: Bool

    init(status: String, settingsFiles: [Data?]) throws {
        guard let auth = try? JSONDecoder().decode(Auth.self, from: Data(status.utf8)), auth.loggedIn else {
            throw MeetingNotesError.unavailable(L10n.tr("Sign in to Claude Code with claude auth login in Terminal."))
        }
        guard let method = auth.authMethod, !method.isEmpty, method != "none" else {
            throw MeetingNotesError.unavailable(L10n.tr("Claude Code didn’t say how it is signed in, so nothing was sent. Update it, then try again."))
        }
        let urls = try Self.customURLs(in: settingsFiles)
        let place = urls.isEmpty ? [Self.providerNames[auth.apiProvider ?? "firstParty"] ?? auth.apiProvider ?? ""] : urls
        label = (place + [Self.methodNames[method] ?? method]).joined(separator: " · ")
        isSubscription = method == "claude.ai" && (auth.apiProvider ?? "firstParty") == "firstParty" && urls.isEmpty
    }

    /// Runs only `claude auth status`, with no meeting text, so Models can show the destination.
    @MainActor public static func current() async throws -> ClaudeCodeDestination {
        guard let executable = await NotesCLI.claudeCode.locateExecutable() else {
            throw MeetingNotesError.unavailable(L10n.tr("Install Claude Code, then sign in with claude auth login in Terminal."))
        }
        let status: String
        do {
            status = try await CLINotesModel.run(executable, arguments: ["auth", "status"], input: "", cli: .claudeCode, timeout: .seconds(30))
        } catch is MeetingNotesError {
            throw MeetingNotesError.unavailable(L10n.tr("Couldn’t read Claude Code’s sign-in. Update it and sign in with claude auth login in Terminal."))
        }
        return try ClaudeCodeDestination(status: status, settingsFiles: installedSettingsFiles())
    }

    /// Each settings file that exists, with nil for one that can't be read, so the caller fails closed.
    @Sendable static func installedSettingsFiles() -> [Data?] {
        let environment = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let config = environment.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let managed = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        let dropIns = (try? FileManager.default.contentsOfDirectory(at: managed.appendingPathComponent("managed-settings.d"), includingPropertiesForKeys: nil)) ?? []
        return ([config.appendingPathComponent("settings.json"), managed.appendingPathComponent("managed-settings.json")] + dropIns.filter { $0.pathExtension == "json" })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try? Data(contentsOf: $0) }
    }

    private static func customURLs(in settingsFiles: [Data?]) throws -> [String] {
        let unreadable = MeetingNotesError.unavailable(L10n.tr("Couldn’t read Claude Code’s settings files, so nothing was sent. Fix them, then try again."))
        var urls: Set<String> = []
        for file in settingsFiles {
            guard let file, let settings = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any] else { throw unreadable }
            guard let env = settings["env"] else { continue }
            guard let env = env as? [String: Any] else { throw unreadable }
            for (key, value) in env where key.hasPrefix("ANTHROPIC_") && key.hasSuffix("BASE_URL") {
                guard let value = value as? String, let url = displayURL(value) else { throw unreadable }
                urls.insert(url)
            }
        }
        return urls.sorted()
    }

    /// Drops a username, password or query, which can hold a secret.
    private static func displayURL(_ text: String) -> String? {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme, let host = parts.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")\(parts.path == "/" ? "" : parts.path)"
    }

    private static let providerNames = ["firstParty": "Anthropic", "bedrock": "Amazon Bedrock", "vertex": "Google Vertex AI", "foundry": "Microsoft Foundry"]
    private static let methodNames = ["claude.ai": "Claude subscription", "oauth_token": "OAuth token", "api_key": "API key",
                                      "api_key_helper": "API key helper", "third_party": "cloud provider sign-in"]

    private struct Auth: Decodable { var loggedIn: Bool; var authMethod: String?; var apiProvider: String? }
}
