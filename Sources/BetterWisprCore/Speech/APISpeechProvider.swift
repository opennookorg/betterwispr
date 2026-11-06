import Foundation

@MainActor
public final class APISpeechProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var connection: SpeechConnection?
    private var transcriptionTask: Task<String, any Error>?
    private let key: (SpeechConnection) throws -> String?
    private let configuration: URLSessionConfiguration

    public init() {
        key = { try SpeechAPIKeyStore().read(for: $0) }
        configuration = .ephemeral
    }

    init(configuration: URLSessionConfiguration, key: @escaping (SpeechConnection) throws -> String?) {
        self.configuration = configuration
        self.key = key
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard transcriptionTask == nil else { throw SpeechError.busy }
        connection = nil
        guard model.engine == .api, let connection = model.connection else { throw SpeechError.invalidModel }
        try Task.checkCancellation()
        _ = try connection.validatedURL()
        try connection.validateAPIKey(key(connection) ?? "")
        self.connection = connection
        // No request, model discovery or audio upload during preparation.
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard let connection else { throw SpeechError.notPrepared }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        try Task.checkCancellation()
        let apiKey = try key(connection) ?? ""
        // Validate before doing audio work, and read the key anew after rotation/removal.
        _ = try Self.request(connection, key: apiKey, wav: Data(), language: language)
        let task = Task {
            let ranges = try await SpeechAudio.chunkRanges(audioURL, seconds: connection.api == .sarvam ? 25 : 125)
            try Task.checkCancellation()
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            let session = URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var transcripts: [String] = []
            for range in ranges {
                let chunk = try await SpeechAudio.wavChunk(audioURL, range)
                try Task.checkCancellation()
                let request = try Self.request(connection, key: apiKey, wav: chunk, language: language)
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw SpeechAPIError.invalidResponse }
                let text = try Self.transcript(data, status: http.statusCode, api: connection.api)
                transcripts.append(text)
            }
            return transcripts.filter { !$0.isEmpty }.joined(separator: " ")
        }
        transcriptionTask = task
        defer { transcriptionTask = nil }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    public func cancel() { transcriptionTask?.cancel() }

    nonisolated static func request(_ connection: SpeechConnection, key: String, wav: Data, language: String?) throws -> URLRequest {
        let url = try connection.validatedURL()
        try connection.validateAPIKey(key)
        try connection.validateLanguage(language)
        let language = SpeechModel.engineLanguage(language)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            request.setValue(connection.api == .sarvam ? key : "Bearer \(key)",
                             forHTTPHeaderField: connection.api == .sarvam ? "api-subscription-key" : "Authorization")
        }
        if connection.api == .smallest {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "model", value: connection.modelID), URLQueryItem(name: "language", value: language)]
            request.url = components.url
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = wav
            return request
        }

        var fields = [("model", connection.modelID)]
        if connection.api == .sarvam {
            fields += [("language_code", language.map { "\($0)-IN" } ?? "unknown"), ("mode", "transcribe")]
        } else {
            fields.append(("response_format", "json"))
            if let language { fields.append(("language", language)) }
        }
        let boundary = "BetterWispr-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    nonisolated static func transcript(_ data: Data, status: Int, api: SpeechAPI) throws -> String {
        guard (200..<300).contains(status) else { throw SpeechAPIError.http(status) }
        let field = switch api {
        case .sarvam: "transcript"
        case .smallest: "transcription"
        case .openAICompatible: "text"
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object[field] as? String else { throw SpeechAPIError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reject every redirect, including same-host redirects that could change which service receives audio.
final class SpeechAPIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
