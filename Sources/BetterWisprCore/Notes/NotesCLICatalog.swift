import Foundation

public struct NotesCLIModel: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
}

public struct NotesCLICatalog: Sendable {
    public var models: [NotesCLIModel]
    public var defaultID: String?

    /// Asks the signed-in CLI for its picker catalog. No inference or meeting text is sent.
    public static func load(_ cli: NotesCLI) async throws -> NotesCLICatalog {
        guard let executable = await cli.locateExecutable() else { throw unavailable(cli) }
        switch cli {
        case .claudeCode:
            let output = try await CLINotesModel.run(executable,
                arguments: ["--print", "--safe-mode", "--input-format", "stream-json", "--output-format", "stream-json",
                            "--verbose", "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"],
                input: "{\"type\":\"control_request\",\"request_id\":\"models\",\"request\":{\"subtype\":\"initialize\"}}\n",
                cli: cli, timeout: .seconds(30))
            return try claudeCatalog(output)
        case .codex:
            var models: [NotesCLIModel] = []
            var defaultID: String?
            var cursor: String?
            var seenCursors: Set<String> = []
            repeat {
                var params: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let messages: [[String: Any]] = [
                    ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "betterwispr", "version": "0.1.0"]]],
                    ["method": "initialized"], ["id": 2, "method": "model/list", "params": params],
                ]
                let input = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
                let output = try await CLINotesModel.run(executable,
                    arguments: ["--no-daemon", "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "app-server", "--stdio"],
                    input: input, cli: cli, timeout: .seconds(30), until: { codexReply($0) != nil })
                guard let page = codexReply(output)?.result else { throw unavailable(cli) }
                models += page.data.filter { $0.hidden != true }.map { NotesCLIModel(id: $0.model, name: $0.displayName, detail: $0.description ?? "") }
                defaultID = defaultID ?? page.data.first(where: { $0.isDefault == true })?.model
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw unavailable(cli) }
            } while cursor != nil
            guard !models.isEmpty else { throw unavailable(cli) }
            return NotesCLICatalog(models: models, defaultID: defaultID)
        }
    }

    static func claudeCatalog(_ output: String) throws -> NotesCLICatalog {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let envelope = try? JSONDecoder().decode(ClaudeEnvelope.self, from: Data(line.utf8)),
                  envelope.response.request_id == "models", let entries = envelope.response.response?.models else { continue }
            var seen: Set<String> = []
            let models = entries.filter { $0.value != "default" }.compactMap { entry -> NotesCLIModel? in
                let id = entry.resolvedModel ?? entry.value
                guard seen.insert(id).inserted else { return nil }
                return NotesCLIModel(id: id, name: entry.displayName, detail: entry.description ?? "")
            }
            guard !models.isEmpty else { throw unavailable(.claudeCode) }
            return NotesCLICatalog(models: models, defaultID: entries.first { $0.value == "default" }?.resolvedModel)
        }
        throw unavailable(.claudeCode)
    }

    static func unavailable(_ cli: NotesCLI) -> MeetingNotesError {
        .unavailable(L10n.tr("Couldn’t list %@ models. Update the CLI and sign in with %@, then refresh. You can also enter an exact model ID.", String(cli.name), String(cli.loginCommand)))
    }

    private struct ClaudeEnvelope: Decodable {
        struct Response: Decodable {
            struct Catalog: Decodable {
                struct Model: Decodable { var value: String; var resolvedModel: String?; var displayName: String; var description: String? }
                var models: [Model]
            }
            var request_id: String
            var response: Catalog?
        }
        var response: Response
    }

    private struct CodexEnvelope: Decodable {
        struct Page: Decodable {
            struct Model: Decodable {
                var model: String; var displayName: String; var description: String?; var isDefault: Bool?; var hidden: Bool?
            }
            var data: [Model]
            var nextCursor: String?
        }
        var id: Int
        var result: Page?
    }

    private static func codexReply(_ output: String) -> CodexEnvelope? {
        output.split(whereSeparator: \.isNewline).compactMap { try? JSONDecoder().decode(CodexEnvelope.self, from: Data($0.utf8)) }.first { $0.id == 2 }
    }
}
