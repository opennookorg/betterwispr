import AVFoundation
import Foundation
import Testing
@testable import BetterWisprCore

@Test func speechConnectionsValidateDestinationsAndKeepSecretsOutOfSettings() throws {
    var connection = SpeechConnection(api: .openAICompatible)
    for endpoint in ["http://localhost:8000/v1/audio/transcriptions", "http://127.0.0.1:8000/transcribe", "http://[::1]:8000/transcribe", "https://speech.example/transcribe"] {
        connection.endpoint = endpoint
        #expect(try connection.validatedURL().absoluteString == endpoint)
    }
    for endpoint in ["http://speech.example/transcribe", "http://localhost.evil.test/transcribe", "file:///tmp/audio", "https://key@host/transcribe", "https://host/transcribe?key=secret", "https://host/transcribe#fragment", "https://host:99999/transcribe"] {
        connection.endpoint = endpoint
        #expect(throws: SpeechAPIError.self) { try connection.validatedURL() }
    }
    connection = SpeechConnection(api: .sarvam)
    #expect(throws: SpeechAPIError.self) { try connection.validateAPIKey("") }
    #expect(throws: SpeechAPIError.self) { try connection.validateAPIKey("secret\r\nX-Key: injected") }
    let account = connection.keychainAccount
    connection.endpoint = "https://other.example/transcribe"
    #expect(connection.keychainAccount != account)
    #expect(throws: SpeechAPIError.self) { try connection.validatedURL() }

    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(settings.speechConnections.isEmpty)
    settings.speechConnections = [SpeechConnection(api: .sarvam)]
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == settings)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("apiKey"))
}

@Test func speechAPIRequestsMatchEachWireFormat() throws {
    let wav = SpeechAudio.wav([0, 0.25, -0.25])
    let sarvam = try APISpeechProvider.request(SpeechConnection(api: .sarvam), key: "test-key", wav: wav, language: "hi")
    #expect(sarvam.value(forHTTPHeaderField: "api-subscription-key") == "test-key")
    #expect(sarvam.value(forHTTPHeaderField: "Authorization") == nil)
    let body = String(decoding: try #require(sarvam.httpBody), as: UTF8.self)
    #expect(body.contains("name=\"language_code\"\r\n\r\nhi-IN"))
    #expect(body.contains("name=\"mode\"\r\n\r\ntranscribe"))
    #expect(body.contains("filename=\"audio.wav\""))
    #expect(!body.contains("test-key"))
    #expect(throws: SpeechAPIError.self) {
        try APISpeechProvider.request(SpeechConnection(api: .sarvam), key: "key", wav: wav, language: "ja")
    }

    let smallest = try APISpeechProvider.request(SpeechConnection(api: .smallest), key: "test-key", wav: wav, language: "en")
    #expect(smallest.url?.absoluteString == "https://api.smallest.ai/waves/v1/stt/?model=pulse&language=en")
    #expect(smallest.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    #expect(smallest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(smallest.httpBody == wav)
    #expect(throws: SpeechAPIError.self) {
        try APISpeechProvider.request(SpeechConnection(api: .smallest), key: "key", wav: wav, language: nil)
    }
    var pro = SpeechConnection(api: .smallest)
    pro.modelID = "pulse-pro"
    #expect(throws: SpeechAPIError.self) { try pro.validateLanguage("hi") }
    try pro.validateLanguage("en")
    #expect(throws: SpeechAPIError.self) { try SpeechConnection(api: .smallest).validateLanguage("ar") }
    try SpeechConnection(api: .smallest).validateLanguage("hi")
    let tagalog = try APISpeechProvider.request(SpeechConnection(api: .smallest), key: "key", wav: wav, language: "tl")
    #expect(tagalog.url?.absoluteString == "https://api.smallest.ai/waves/v1/stt/?model=pulse&language=tl")

    let custom = try APISpeechProvider.request(SpeechConnection(api: .openAICompatible), key: "", wav: wav, language: nil)
    #expect(custom.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(String(decoding: try #require(custom.httpBody), as: UTF8.self).contains("name=\"response_format\"\r\n\r\njson"))
    for (api, field) in [(SpeechAPI.sarvam, "transcript"), (.smallest, "transcription"), (.openAICompatible, "text")] {
        #expect(try APISpeechProvider.transcript(Data("{\"\(field)\":\" नमस्ते \"}".utf8), status: 200, api: api) == "नमस्ते")
        #expect(throws: SpeechAPIError.self) { try APISpeechProvider.transcript(Data("{}".utf8), status: 200, api: api) }
        #expect(throws: SpeechAPIError.self) { try APISpeechProvider.transcript(Data("secret error details".utf8), status: 401, api: api) }
    }
}

@Test func speechAPIResamplesCAFAndSplitsWithoutDroppingAudio() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-api-test-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let frames: AVAudioFrameCount = 48_000 * 26
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for index in 0..<Int(frames) { channels[channel][index] = 0.1 * sin(Float(index) * 0.03) }
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    let chunks = try await SpeechAudio.wavChunks(url, seconds: 25)
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { String(decoding: $0.prefix(4), as: UTF8.self) == "RIFF" })
    #expect(chunks.reduce(0) { $0 + ($1.count - 44) / 2 } == 26 * 16_000)
    let firstChunkByteCount: Int = 44 + 25 * 16_000 * 2
    #expect(chunks[0].count == firstChunkByteCount)
    #expect(chunks[0][22] == 1) // Mono, signed 16-bit PCM.
    #expect(chunks[0][34] == 16)
}

@Test func speechAPIAcceptsDictationsLongerThanTwoMinutes() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-api-test-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let frames: AVAudioFrameCount = 16_000 * 180
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    let chunks = try await SpeechAudio.wavChunks(url, seconds: 125)
    #expect(chunks.count == 2)
    #expect(chunks.reduce(0) { $0 + ($1.count - 44) / 2 } == 180 * 16_000)
}

@MainActor
@Test func speechAPIUsesThePreparedConnectionAndSurfacesHTTPFailures() async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: "betterwispr-api-test-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: audio) }
    try SpeechAudio.wav(Array(repeating: 0.1, count: 1600)).write(to: audio)
    for path in ["ok", "unauthorized", "malformed"] {
        var connection = SpeechConnection(api: .openAICompatible)
        connection.endpoint = "https://speech.example/\(UUID())/\(path)"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpeechEndpointStub.self]
        let provider = APISpeechProvider(configuration: config, key: { _ in "test-key" })
        let requestPath = try connection.validatedURL().path
        try await provider.prepare(model: connection.speechModel, download: false)
        #expect(await !SpeechEndpointStub.probe.started.contains(requestPath))
        if path == "ok" {
            #expect(try await provider.transcribe(audioURL: audio, language: "en", vocabulary: ["Private vocabulary"]) == "Hello")
        } else {
            await #expect(throws: SpeechAPIError.self) { try await provider.transcribe(audioURL: audio, language: "en", vocabulary: []) }
        }
    }
}

@MainActor
@Test(arguments: [false, true])
func speechAPICancellationStopsAnInFlightRequest(cancelProvider: Bool) async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: "betterwispr-api-test-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: audio) }
    try SpeechAudio.wav(Array(repeating: 0.1, count: 1600)).write(to: audio)
    var connection = SpeechConnection(api: .openAICompatible)
    let path = "/wait-\(UUID())"
    connection.endpoint = "https://speech.example\(path)"
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SpeechEndpointStub.self]
    let provider = APISpeechProvider(configuration: config, key: { _ in "test-key" })
    try await provider.prepare(model: connection.speechModel, download: false)
    let task = Task { try await provider.transcribe(audioURL: audio, language: "en", vocabulary: []) }
    for _ in 0..<500 {
        if await SpeechEndpointStub.probe.started.contains(path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await SpeechEndpointStub.probe.started.contains(path))
    if cancelProvider { provider.cancel() } else { task.cancel() }
    do { _ = try await task.value; Issue.record("Cancelled audio must not produce text") }
    catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    for _ in 0..<100 {
        if await SpeechEndpointStub.probe.stopped.contains(path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await SpeechEndpointStub.probe.stopped.contains(path))
}

@Test func speechAPIKeysStayBoundToTheirDestinationAndCanBeRemoved() throws {
    let keys = SpeechAPIKeyStore(service: "org.betterwispr.tests.\(UUID())")
    let connection = SpeechConnection(api: .openAICompatible)
    defer { try? keys.save("", for: connection) }
    #expect(try keys.read(for: connection) == nil)
    try keys.save("test-only-key", for: connection)
    #expect(try keys.read(for: connection) == "test-only-key")
    var changed = connection
    changed.endpoint = "https://another.example/transcribe"
    #expect(try keys.read(for: changed) == nil)
    try keys.save("rotated-test-key", for: connection)
    #expect(try keys.read(for: connection) == "rotated-test-key")
    try keys.save("", for: connection)
    #expect(try keys.read(for: connection) == nil)
}

@Test func speechAPIRejectsRedirectsWithoutForwardingAudioOrKeys() {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = URL(string: "https://speech.example/transcribe")!
    var redirected = URLRequest(url: URL(string: "https://elsewhere.example/transcribe")!)
    redirected.setValue("test-key", forHTTPHeaderField: "api-subscription-key")
    let task = session.dataTask(with: original)
    SpeechAPIRedirectGuard().urlSession(session, task: task,
        willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil)!,
        newRequest: redirected) { request in
            #expect(request == nil)
        }
}

private actor SpeechRequestProbe {
    var started: Set<String> = []
    var stopped: Set<String> = []
    func start(_ path: String) { started.insert(path) }
    func stop(_ path: String) { stopped.insert(path) }
}

// URLProtocol is called on URLSession's threads. This subclass has no mutable instance state;
// the shared request probe is isolated to its actor.
private final class SpeechEndpointStub: URLProtocol, @unchecked Sendable {
    static let probe = SpeechRequestProbe()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let requestPath = request.url!.path
        Task { await SpeechEndpointStub.probe.start(requestPath) }
        if path.hasPrefix("wait-") { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "unauthorized" ? 401 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((path == "malformed" ? "{}" : #"{"text":"Hello"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        let path = request.url!.path
        Task { await SpeechEndpointStub.probe.stop(path) }
    }
}
