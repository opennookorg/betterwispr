import AVFoundation
import Foundation

/// 16 kHz mono samples captured while a dictation records, in order. Unchecked because a lock guards the array,
/// and the capture worker only appends while the main actor only reads copies.
public final class LiveAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    public init() {}

    public func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func copy(from start: Int, to end: Int? = nil) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let end = min(end ?? samples.count, samples.count)
        return start < end ? Array(samples[start..<end]) : []
    }
}

/// Holds one session per provider so dictations reuse the TLS connection; invalidated when the provider goes away.
/// Unchecked because a lock guards the stored session.
private final class SpeechSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?

    func session(_ make: () -> URLSession) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let made = make()
        session = made
        return made
    }

    func reset() {
        lock.lock()
        let old = session
        session = nil
        lock.unlock()
        old?.invalidateAndCancel()
    }

    deinit { session?.invalidateAndCancel() }
}

@MainActor
public final class APISpeechProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var connection: SpeechConnection?
    private var transcriptionTask: Task<String, any Error>?
    private let key: (SpeechConnection) throws -> String?
    private let configuration: URLSessionConfiguration
    private let requestTimeout: TimeInterval
    /// AAC for OpenAI-compatible endpoints; tests that read the WAV body turn it off.
    private let compressesUploads: Bool
    private let sessions = SpeechSessionBox()
    private var live: LiveUpload?

    private struct LiveUpload {
        let buffer: LiveAudioBuffer
        let language: String?
        let connection: SpeechConnection
        var cut = 0
        var pieces: [Task<String, any Error>] = []
        var poller: Task<Void, Never>?
    }

    public init() {
        key = { try SpeechAPIKeyStore().read(for: $0) }
        configuration = .ephemeral
        requestTimeout = 60
        compressesUploads = true
    }

    init(configuration: URLSessionConfiguration, requestTimeout: TimeInterval = 60, compressesUploads: Bool = true,
         key: @escaping (SpeechConnection) throws -> String?) {
        self.configuration = configuration
        self.requestTimeout = requestTimeout
        self.compressesUploads = compressesUploads
        self.key = key
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard transcriptionTask == nil else { throw SpeechError.busy }
        guard model.engine == .api, let next = model.connection else {
            connection = nil
            throw SpeechError.invalidModel
        }
        try Task.checkCancellation()
        _ = try next.validatedURL()
        try next.validateAPIKey(key(next) ?? "")
        if connection != next {
            endLiveUpload()
            sessions.reset()
        }
        connection = next
        // No request, model discovery or audio upload during preparation.
    }

    /// Starts sending finished pieces of a dictation while the user is still speaking, so only the last piece is left on release.
    /// Only OpenAI-compatible endpoints use it, and any problem falls back to uploading the saved recording.
    public func beginLiveUpload(_ buffer: LiveAudioBuffer, language: String?) {
        endLiveUpload()
        guard let connection, connection.api == .openAICompatible else { return }
        live = LiveUpload(buffer: buffer, language: language, connection: connection)
        live?.poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.cutLivePieces()
            }
        }
    }

    /// Pieces are cut at the quietest 50 ms between 9 and 15 s. Short pieces keep the part left at release small:
    /// on a link with about 100 ms of latency, a 5 s piece came back in about 0.9 s and a 25 s piece in about 2.2 s.
    nonisolated static let livePieceSeconds = 12.0, livePieceSlack = 3.0

    private func cutLivePieces() {
        guard var state = live else { return }
        let rate = 16_000
        let window = Int((Self.livePieceSeconds + Self.livePieceSlack) * Double(rate))
        while state.buffer.count - state.cut >= window {
            let lo = state.cut + Int((Self.livePieceSeconds - Self.livePieceSlack) * Double(rate))
            let region = state.buffer.copy(from: lo, to: state.cut + window)
            let end = lo + Self.quietestFrame(region, frame: rate / 20)
            let piece = state.buffer.copy(from: state.cut, to: end)
            state.cut = end
            state.pieces.append(upload(piece, language: state.language, connection: state.connection))
        }
        live = state
    }

    /// Offset of the quietest 50 ms frame, measured on every fourth sample.
    nonisolated static func quietestFrame(_ samples: [Float], frame: Int) -> Int {
        guard samples.count > frame else { return samples.count }
        var best = 0, bestLevel = Float.greatestFiniteMagnitude
        var start = 0
        while start + frame <= samples.count {
            var level: Float = 0
            var index = start
            while index < start + frame { level += abs(samples[index]); index += 4 }
            if level < bestLevel { bestLevel = level; best = start }
            start += frame
        }
        return best
    }

    private func endLiveUpload() {
        live?.poller?.cancel()
        live?.pieces.forEach { $0.cancel() }
        live = nil
    }

    private func upload(_ samples: [Float], language: String?, connection: SpeechConnection) -> Task<String, any Error> {
        let apiKey = (try? key(connection)) ?? ""
        let session = currentSession()
        let timeout = requestTimeout
        let compress = compressesUploads
        return Task {
            switch try await Self.send(SpeechAudio.wav(samples), connection: connection, key: apiKey, language: language,
                                       timeout: timeout, session: session, compress: compress) {
            case .text(let text): return text
            case .tryAgain(let error, _): throw error
            }
        }
    }

    private func currentSession() -> URLSession {
        let timeout = requestTimeout
        return sessions.session {
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 2
            configuration.httpMaximumConnectionsPerHost = Self.concurrentChunks
            return URLSession(configuration: configuration, delegate: SpeechAPIRedirectGuard(), delegateQueue: nil)
        }
    }

    /// Sends one piece. OpenAI-compatible endpoints get AAC, about an eighth of the WAV size, and the piece is sent again
    /// as WAV when the endpoint answers 400, 415 or 422.
    nonisolated private static func send(_ wav: Data, connection: SpeechConnection, key: String, language: String?,
                                         timeout: TimeInterval, session: URLSession, compress: Bool) async throws -> ClipAnswer {
        var uploads: [(Data, String, String)] = []
        if compress, connection.api == .openAICompatible, let aac = SpeechAudio.aac(SpeechAudio.samples(fromWAV: wav)) {
            uploads.append((aac, "audio.m4a", "audio/mp4"))
        }
        uploads.append((wav, "audio.wav", "audio/wav"))
        for (index, (audio, filename, mimeType)) in uploads.enumerated() {
            let request = try Self.request(connection, key: key, audio: audio, filename: filename, mimeType: mimeType,
                                           language: language, timeout: timeout)
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw SpeechAPIError.invalidResponse }
                if index < uploads.count - 1, [400, 415, 422].contains(http.statusCode) { continue }
                if http.statusCode == 429 { return .tryAgain(SpeechAPIError.http(429), after: Self.retryPause(http)) }
                return .text(try Self.transcript(data, status: http.statusCode, api: connection.api))
            } catch let error as URLError where error.code == .timedOut {
                return .tryAgain(error, after: .zero)
            }
        }
        throw SpeechAPIError.invalidResponse
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard let connection else { throw SpeechError.notPrepared }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        try Task.checkCancellation()
        let apiKey = try key(connection) ?? ""
        // Validate before doing audio work, and read the key anew after rotation/removal.
        _ = try Self.request(connection, key: apiKey, wav: Data(), language: language)
        let timeout = requestTimeout
        let livePieces = takeLiveUpload(for: audioURL, connection: connection, language: language)
        let session = currentSession()
        let compress = compressesUploads
        let task = Task {
            if let livePieces {
                do {
                    var texts: [String] = []
                    for piece in livePieces { texts.append(try await piece.value) }
                    try Task.checkCancellation()
                    return texts.filter { !$0.isEmpty }.joined(separator: " ")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The saved recording below is the source of truth; a failed live piece only costs time.
                }
            }
            let ranges = try await SpeechAudio.chunkRanges(audioURL, seconds: connection.api == .sarvam ? 25 : 125)
            try Task.checkCancellation()
            let send: @Sendable (Range<Double>) async throws -> ClipAnswer = { range in
                let chunk = try await SpeechAudio.wavChunk(audioURL, range)
                try Task.checkCancellation()
                return try await Self.send(chunk, connection: connection, key: apiKey, language: language, timeout: timeout,
                                           session: session, compress: compress)
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

    /// Hands over the live pieces plus the unsent tail when they cover the whole recording; otherwise discards them.
    private func takeLiveUpload(for audioURL: URL, connection: SpeechConnection, language: String?) -> [Task<String, any Error>]? {
        cutLivePieces()
        guard var state = live else { return nil }
        state.poller?.cancel()
        live = nil
        guard state.connection == connection, state.language == language,
              let file = try? AVAudioFile(forReading: audioURL) else {
            state.pieces.forEach { $0.cancel() }
            return nil
        }
        let recorded = Double(file.length) / file.processingFormat.sampleRate
        let captured = Double(state.buffer.count) / 16_000
        // The live copy must match the saved recording, or the recording is uploaded instead.
        guard recorded > 0, abs(recorded - captured) <= 0.75 else {
            state.pieces.forEach { $0.cancel() }
            return nil
        }
        let tail = state.buffer.copy(from: state.cut)
        if !tail.isEmpty { state.pieces.append(upload(tail, language: language, connection: connection)) }
        return state.pieces
    }

    public func cancel() {
        transcriptionTask?.cancel()
        endLiveUpload()
    }

    /// How many pieces of one dictation are uploaded at once. Kept low for providers' rate limits.
    nonisolated static let concurrentChunks = 4

    /// How long to wait before retrying after a 429: the provider's Retry-After seconds up to 30, otherwise 1.
    nonisolated static func retryPause(_ response: HTTPURLResponse) -> Duration {
        .seconds(min(max(response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) } ?? 1, 0), 30))
    }

    nonisolated static func request(_ connection: SpeechConnection, key: String, wav: Data, language: String?, timeout: TimeInterval = 60) throws -> URLRequest {
        try request(connection, key: key, audio: wav, filename: "audio.wav", mimeType: "audio/wav", language: language, timeout: timeout)
    }

    nonisolated static func request(_ connection: SpeechConnection, key: String, audio: Data, filename: String, mimeType: String,
                                    language: String?, timeout: TimeInterval = 60) throws -> URLRequest {
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
            request.httpBody = audio
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
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audio)
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
