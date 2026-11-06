import Foundation

@MainActor
public final class APISpeechProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var connection: SpeechConnection?
    private var transcriptionTask: Task<String, any Error>?
    private let key: (SpeechConnection) throws -> String?
    private let configuration: URLSessionConfiguration
    private let requestTimeout: TimeInterval

    public init() {
        key = { try SpeechAPIKeyStore().read(for: $0) }
        configuration = .ephemeral
        requestTimeout = 60
    }

    init(configuration: URLSessionConfiguration, requestTimeout: TimeInterval = 60, key: @escaping (SpeechConnection) throws -> String?) {
        self.configuration = configuration
        self.requestTimeout = requestTimeout
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
        let timeout = requestTimeout
        let task = Task {
            let ranges = try await SpeechAudio.chunkRanges(audioURL, seconds: connection.api == .sarvam ? 25 : 125)
            try Task.checkCancellation()
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 2
            configuration.httpMaximumConnectionsPerHost = Self.concurrentChunks
            let session = URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let send: @Sendable (Range<Double>) async throws -> ClipAnswer = { range in
                let chunk = try await SpeechAudio.wavChunk(audioURL, range)
                try Task.checkCancellation()
                let request = try Self.request(connection, key: apiKey, wav: chunk, language: language, timeout: timeout)
                do {
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else { throw SpeechAPIError.invalidResponse }
                    if http.statusCode == 429 { return .tryAgain(SpeechAPIError.http(429), after: Self.retryPause(http)) }
                    return .text(try Self.transcript(data, status: http.statusCode, api: connection.api))
                } catch let error as URLError where error.code == .timedOut {
                    return .tryAgain(error, after: .zero)
                }
            }
            var transcripts = [String?](repeating: nil, count: ranges.count)
            let pause = try await withThrowingTaskGroup(of: (Int, ClipAnswer).self) { group in
                var next = 0
                var pause: Duration?
                func start(_ index: Int) {
                    group.addTask { (index, try await send(ranges[index])) }
                }
                while next < min(Self.concurrentChunks, ranges.count) { start(next); next += 1 }
                while let (index, answer) = try await group.next() {
                    switch answer {
                    case .text(let text): transcripts[index] = text
                    case .tryAgain(_, let after): pause = max(pause ?? .zero, after)
                    }
                    if pause == nil, next < ranges.count { start(next); next += 1 }
                }
                return pause
            }
            if let pause { try await Task.sleep(for: pause) }
            for index in ranges.indices where transcripts[index] == nil {
                switch try await send(ranges[index]) {
                case .text(let text): transcripts[index] = text
                case .tryAgain(let error, _): throw error
                }
            }
            try Task.checkCancellation()
            return transcripts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
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

    /// How many pieces of one dictation are uploaded at once. Kept low for providers' rate limits.
    nonisolated static let concurrentChunks = 4

    /// How long to wait before retrying after a 429: the provider's Retry-After seconds up to 30, otherwise 1.
    nonisolated static func retryPause(_ response: HTTPURLResponse) -> Duration {
        .seconds(min(max(response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 1, 0), 30))
    }

    nonisolated static func request(_ connection: SpeechConnection, key: String, wav: Data, language: String?, timeout: TimeInterval = 60) throws -> URLRequest {
        let url = try connection.validatedURL()
        try connection.validateAPIKey(key)
        try connection.validateLanguage(language)
        let language = SpeechModel.engineLanguage(language)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
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

private enum ClipAnswer: Sendable {
    case text(String)
    case tryAgain(any Error, after: Duration)
}

/// Reject every redirect, including same-host redirects that could change which service receives audio.
final class SpeechAPIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
