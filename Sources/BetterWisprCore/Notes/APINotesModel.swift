import Foundation

/// Reuses the speech connection metadata, destination validation and Keychain implementation.
final class APINotesModel: NotesLanguageModel {
    let connection: SpeechConnection
    let instructions: String
    let lowLatency: Bool
    private let keys: SpeechAPIKeyStore
    private let session: URLSession

    init(connection: SpeechConnection, instructions: String = NotesWriter.instructions, lowLatency: Bool = false,
         keys: SpeechAPIKeyStore = .notes, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        self.instructions = instructions
        self.lowLatency = lowLatency
        self.keys = keys
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func respond(to prompt: String) async throws -> String {
        try await chat(prompt, json: false)
    }

    private func chat(_ prompt: String, json: Bool) async throws -> String {
        try Task.checkCancellation()
        guard connection.api == .openAICompatible else {
            throw MeetingNotesError.unavailable(L10n.tr("Notes require an OpenAI-compatible chat completions endpoint."))
        }
        let key = try keys.read(for: connection) ?? ""
        try connection.validateAPIKey(key)
        var request = URLRequest(url: try connection.validatedURL(), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(prompt, json: json))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MeetingNotesError.unavailable(L10n.tr("The notes endpoint returned an invalid response.")) }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403, 429: throw SpeechAPIError.http(http.statusCode)
            case 300..<400: throw MeetingNotesError.unavailable(L10n.tr("The notes endpoint redirected. Enter its final URL in Models; transcripts and keys are never forwarded to redirects."))
            default: throw MeetingNotesError.unavailable(L10n.tr("The notes endpoint returned HTTP %@. Check its URL and model ID in Models.", String(http.statusCode)))
            }
        }
        guard let result = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = result.choices.first,
              choice.finish_reason == nil || choice.finish_reason == "stop",
              choice.message.refusal == nil,
              let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MeetingNotesError.unavailable(L10n.tr("The notes model returned an empty, incomplete or unsupported response. Try again or choose another model."))
        }
        return text
    }

    func draft(_ prompt: String) async throws -> NotesDraft {
        try NotesDraft.decode(await chat("\(prompt)\n\n\(NotesDraft.fields)", json: true))
    }

    func requestBody(_ prompt: String, json: Bool) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": connection.modelID, "stream": false,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if lowLatency { body.merge(Self.lowLatencyFields(host: try connection.validatedURL().host(), model: connection.modelID)) { $1 } }
        return body
    }

    static let openAINoReasoningModels: Set<String> = [
        "gpt-6-luna", "gpt-6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano",
    ]

    /// VoiceInk's fast-reply fields for hosts and models known to accept them; anything else keeps the plain request.
    static func lowLatencyFields(host: String?, model: String) -> [String: Any] {
        switch ((host ?? "").lowercased(), model) {
        case ("api.openai.com", _) where openAINoReasoningModels.contains(model):
            ["reasoning_effort": "none", "temperature": 0.3]
        case ("api.groq.com", "openai/gpt-oss-120b"), ("api.groq.com", "openai/gpt-oss-20b"):
            ["reasoning_effort": "low", "include_reasoning": false, "temperature": 0.3]
        case ("api.cerebras.ai", "gpt-oss-120b"):
            ["reasoning_effort": "low", "reasoning_format": "hidden", "temperature": 0.3]
        case ("api.groq.com", "qwen/qwen3.8-27b"), ("api.cerebras.ai", "qwen-3.8-27b"):
            ["reasoning_effort": "none", "temperature": 0.3]
        case ("openrouter.ai", _):
            ["provider": ["sort": "throughput", "preferred_max_latency": ["p90": 2.5]]]
        default: [:]
        }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String?; var refusal: String? }
            var message: Message
            var finish_reason: String?
        }
        var choices: [Choice]
    }
}
