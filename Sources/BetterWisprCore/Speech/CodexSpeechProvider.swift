import Foundation

// Auth and request format adapted from Wangnov/codex-asr, revision 479f6a7.
// MIT license retained in Resources/Licenses/codex-asr-MIT.txt.
@MainActor
public final class CodexSpeechProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var prepared = false
    private var transcriptionTask: Task<String, any Error>?
    private let credentials: () throws -> CodexCredentials
    private let configuration: URLSessionConfiguration

    public init() {
        credentials = { try CodexCredentials.load() }
        configuration = .ephemeral
    }

    init(configuration: URLSessionConfiguration, credentials: @escaping () throws -> CodexCredentials) {
        self.configuration = configuration
        self.credentials = credentials
    }

    /// Checks only the local sign-in file. Service access and token expiry are checked on transcription.
    public static var isSignedIn: Bool { (try? CodexCredentials.load()) != nil }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard transcriptionTask == nil else { throw SpeechError.busy }
        prepared = false
        guard model == .codex else { throw SpeechError.invalidModel }
        try Task.checkCancellation()
        _ = try credentials()
        prepared = true
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard prepared else { throw SpeechError.notPrepared }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        try Task.checkCancellation()
        let auth = try credentials()
        let language = try Self.language(language)
        let task = Task {
            let ranges = try await SpeechAudio.chunkRanges(audioURL, seconds: 125)
            try Task.checkCancellation()
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            let session = URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var texts: [String] = []
            for (index, range) in ranges.enumerated() {
                let chunk = try await SpeechAudio.wavChunk(audioURL, range)
                try Task.checkCancellation()
                let request = Self.request(auth: auth, wav: chunk, language: language)
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw (error as? URLError)?.code == .timedOut ? CodexSpeechError.timedOut : .connectionFailed
                }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw CodexSpeechError.invalidResponse }
                texts.append(try Self.transcript(data, status: http.statusCode))
                onProgress?(Double(index + 1) / Double(ranges.count))
            }
            try Task.checkCancellation()
            return texts.filter { !$0.isEmpty }.joined(separator: " ")
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

    nonisolated private static func language(_ identifier: String?) throws -> String? {
        guard let language = SpeechModel.engineLanguage(identifier) else { return nil }
        guard language.utf8.count <= 16, language.utf8.allSatisfy({ (97...122).contains($0) }) else {
            throw CodexSpeechError.invalidLanguage
        }
        return language
    }

    nonisolated static func request(auth: CodexCredentials, wav: Data, language: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID = auth.accountID { request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let boundary = "BetterWispr-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav)
        body.append(Data("\r\n".utf8))
        if let language {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    nonisolated private static var userAgent: String {
        let version = Bundle(path: "/Applications/Codex.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let safeVersion = version.flatMap { value in
            !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } ? value : nil
        } ?? "26.429.30905"
        #if arch(arm64)
        let architecture = "aarch64"
        #else
        let architecture = "x86_64"
        #endif
        return "Codex Desktop/\(safeVersion) (macos; \(architecture))"
    }

    nonisolated static func transcript(_ data: Data, status: Int) throws -> String {
        switch status {
        case 401: throw CodexSpeechError.signInRequired
        case 403: throw CodexSpeechError.accessDenied
        case 429: throw CodexSpeechError.quotaReached
        case 200..<300: break
        default: throw CodexSpeechError.http(status)
        }
        struct Response: Decodable { let text: String }
        guard data.count <= 2_000_000, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CodexSpeechError.invalidResponse
        }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexSpeechError: LocalizedError, Equatable {
    case signInRequired, accessDenied, quotaReached, timedOut, connectionFailed, invalidResponse, invalidLanguage
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to your ChatGPT account with codex login in Terminal, then try again."
        case .accessDenied: "ChatGPT denied transcription access. Check your account access or choose another speech model."
        case .quotaReached: "ChatGPT's transcription limit was reached. Try later or choose another speech model."
        case .timedOut: "Codex transcription took too long. Check your connection or try a shorter recording."
        case .connectionFailed: "Couldn't connect to ChatGPT for transcription. Check your connection and try again."
        case .invalidResponse: "ChatGPT returned an unsupported transcription response. Try again or choose another speech model."
        case .invalidLanguage: "Choose a supported language or Auto before transcription."
        case .http(let status): "ChatGPT transcription failed (HTTP \(status)). Try again or choose another speech model."
        }
    }
}

struct CodexCredentials: Sendable {
    let accessToken: String
    let accountID: String?

    init(data: Data) throws {
        struct AuthFile: Decodable {
            let auth_mode: String?
            let authMode: String?
            let tokens: Tokens?
            struct Tokens: Decodable {
                let access_token: String?
                let account_id: String?
            }
        }
        guard let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              (auth.auth_mode ?? auth.authMode).map({ ["chatgpt", "chatgpt_auth_tokens"].contains($0) }) ?? true,
              let token = auth.tokens?.access_token, Self.safeHeader(token) else {
            throw CodexSpeechError.signInRequired
        }
        let account = auth.tokens?.account_id ?? Self.accountID(in: token)
        guard account.map(Self.safeHeader) ?? true else { throw CodexSpeechError.signInRequired }
        accessToken = token
        accountID = account
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        let directory = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return try load(file: directory.appendingPathComponent("auth.json"))
    }

    static func load(file: URL) throws -> Self {
        let limit = 1_048_576
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
                throw CodexSpeechError.signInRequired
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw CodexSpeechError.signInRequired }
            return try Self(data: data)
        } catch { throw CodexSpeechError.signInRequired }
    }

    private static func safeHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32_768 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    private static func accountID(in token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = object["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}
