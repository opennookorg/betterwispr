import Foundation

public enum Ollama {
    static let api = URL(string: "http://127.0.0.1:11434/api/")!
    /// Ollama reloads a model whose context length differs from the last request, so every request sends the same one.
    static let contextLength = 8192

    /// Lists models stored in Ollama on this Mac that can write text, leaving out cloud and embedding models.
    public static func installedModels() async throws -> [String] {
        var names: [String] = []
        for name in try JSONDecoder().decode(Tags.self, from: try await send("tags", timeout: 5)).localNames {
            let show = try JSONDecoder().decode(Show.self, from: try await send("show", ["model": name], timeout: 5))
            if show.capabilities.contains("completion") { names.append(name) }
        }
        return names
    }

    static func send(_ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: api.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw MeetingNotesError.unavailable(L10n.tr("Ollama isn’t running. Open Ollama and try again, or choose Apple Intelligence in Notetaker settings."))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw MeetingNotesError.unavailable(L10n.tr("Ollama couldn’t write notes. %@", String(reason)))
        }
        return data
    }

    struct Tags: Decodable {
        struct Model: Decodable {
            let name: String
            let remoteHost: String?

            enum CodingKeys: String, CodingKey { case name, remoteHost = "remote_host" }
        }

        let models: [Model]

        var localNames: [String] { models.filter { $0.remoteHost == nil }.map(\.name) }
    }

    struct Show: Decodable { let capabilities: [String] }
    struct Chat: Decodable { struct Message: Decodable { let content: String }; let message: Message }
    struct Failure: Decodable { let error: String }
}

struct OllamaNotesModel: NotesLanguageModel {
    let name: String
    var instructions = NotesWriter.instructions

    private static var schema: [String: Any] {
        let list: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return ["type": "object",
                "properties": ["title": ["type": "string"], "overview": ["type": "string"],
                               "keyPoints": list, "decisions": list, "actionItems": list],
                "required": ["title", "overview", "keyPoints", "decisions", "actionItems"]]
    }

    func respond(to prompt: String) async throws -> String {
        try await chat(prompt)
    }

    func draft(_ prompt: String) async throws -> NotesDraft {
        try NotesDraft.decode(await chat("\(prompt)\n\n\(NotesDraft.fields)", format: Self.schema))
    }

    private func chat(_ prompt: String, format: [String: Any]? = nil) async throws -> String {
        var body: [String: Any] = [
            "model": name, "stream": false, "think": false,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
            "options": ["temperature": 0.3, "num_ctx": Ollama.contextLength],
        ]
        if let format { body["format"] = format }
        let data = try await Ollama.send("chat", body, timeout: 600)
        return try JSONDecoder().decode(Ollama.Chat.self, from: data).message.content
    }
}
