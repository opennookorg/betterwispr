import Foundation
import os
import Testing
@testable import BetterWisprCore

@Suite(.serialized)
struct SpeechAPIClipTests {
    @MainActor
    @Test(arguments: [[3, 4, 2, 1, 0], [0, 1, 2, 3, 4], [2, 0, 4, 3, 1]])
    func speechAPIUploadsAtMostFourClipsAndJoinsThemInSpokenOrder(answerOrder: [Int]) async throws {
        let audio = try ClipAudio(clips: 5)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.started.count == 4 })
        await endpoint.settle()
        #expect(endpoint.state.started.sorted() == [0, 1, 2, 3])
        for (position, clip) in answerOrder.enumerated() {
            #expect(await endpoint.waitUntil { $0.waiting.contains(clip) })
            endpoint.answer(clip, with: .text("clip\(clip)"))
            if position == 0 { #expect(await endpoint.waitUntil { $0.started.contains(4) }) }
        }
        #expect(try await task.value == "clip0 clip1 clip2 clip3 clip4")
        #expect(endpoint.state.started.sorted() == [0, 1, 2, 3, 4])
        #expect(endpoint.state.mostActive == 4)
    }

    @MainActor
    @Test(arguments: [ClipReply.status(429), .status(500), .malformed, .dropped])
    func speechAPIFailsTheWholeDictationWhenOneClipFails(failure: ClipReply) async throws {
        let audio = try ClipAudio(clips: 5)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.started.count == 4 })
        endpoint.answer(0, with: .text("clip0"))
        #expect(await endpoint.waitUntil { $0.waiting.contains(4) })
        endpoint.answer(2, with: failure)
        do {
            let text = try await task.value
            Issue.record("A failed clip must not produce text: \(text)")
        } catch {
            #expect(failure.matches(error), "Unexpected error: \(error)")
        }
        #expect(await endpoint.waitUntil { Set($0.stopped).isSuperset(of: [1, 3, 4]) })
        #expect(endpoint.state.waiting.isEmpty)
    }

    @MainActor
    @Test func speechAPIFailureBeforeTheLastClipStartsNeverSendsIt() async throws {
        let audio = try ClipAudio(clips: 5)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.started.count == 4 })
        endpoint.answer(1, with: .status(429))
        await #expect(throws: SpeechAPIError.self) { try await task.value }
        await endpoint.settle()
        #expect(!endpoint.state.started.contains(4))
        #expect(await endpoint.waitUntil { Set($0.stopped).isSuperset(of: [0, 2, 3]) })
    }

    @MainActor
    @Test(arguments: [false, true])
    func speechAPICancellationStopsEveryClipAndLeavesTheProviderReady(cancelProvider: Bool) async throws {
        let audio = try ClipAudio(clips: 5)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.started.count == 4 })
        if cancelProvider { provider.cancel() } else { task.cancel() }
        do {
            let text = try await task.value
            Issue.record("Cancelled audio must not produce text: \(text)")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(await endpoint.waitUntil { Set($0.stopped).isSuperset(of: [0, 1, 2, 3]) })
        await endpoint.settle()
        #expect(endpoint.state.started.sorted() == [0, 1, 2, 3])
        #expect(endpoint.state.active == 0)
        #expect(FileManager.default.fileExists(atPath: audio.url.path))

        let next = try ClipAudio(clips: 1, seconds: 1)
        defer { next.remove() }
        let session = Task { try await provider.transcribe(audioURL: next.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.waiting.contains(0) })
        endpoint.answer(0, with: .text("next session"))
        #expect(try await session.value == "next session")
    }

    @MainActor
    @Test func speechAPICancelQueuedBehindTheLastAnswerDiscardsTheText() async throws {
        let audio = try ClipAudio(clips: 1, seconds: 1)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.waiting.contains(0) })
        endpoint.answer(0, with: .text("stale"))
        usleep(300_000)
        provider.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @MainActor
    @Test func speechAPIStaysBusyUntilEveryClipOfTheSessionHasStopped() async throws {
        let audio = try ClipAudio(clips: 5)
        defer { audio.remove() }
        let endpoint = ClipEndpoint()
        let provider = try await endpoint.provider()
        let task = Task { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(await endpoint.waitUntil { $0.started.count == 4 })
        await #expect(throws: SpeechError.self) { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        provider.cancel()
        _ = try? await task.value
    }

    @MainActor
    @Test func speechAPIConnectionsAreNeverPreparedForOtherEnginesOrWarmedUp() async throws {
        let provider = APISpeechProvider(configuration: .ephemeral, key: { _ in "" })
        #expect(SpeechModel.catalog.allSatisfy { $0.processingLocation.isOnDevice })
        let local = try #require(SpeechModel.catalog.first)
        await #expect(throws: SpeechError.self) { try await provider.prepare(model: local, download: false) }
        let audio = try ClipAudio(clips: 1, seconds: 1)
        defer { audio.remove() }
        await #expect(throws: SpeechError.self) { try await provider.transcribe(audioURL: audio.url, language: "en", vocabulary: []) }
        #expect(!SpeechConnection(api: .openAICompatible).speechModel.supportsSyntheticWarmUp)
        #expect(!SpeechConnection(api: .openAICompatible).speechModel.processingLocation.isOnDevice)
        #expect(AppSettings().selectedModelID == "apple")
    }
}

enum ClipReply: Sendable, CustomTestStringConvertible {
    case text(String), status(Int), malformed, dropped

    var testDescription: String {
        switch self {
        case .text(let text): "text \(text)"
        case .status(let status): "HTTP \(status)"
        case .malformed: "malformed JSON"
        case .dropped: "dropped connection"
        }
    }

    func matches(_ error: any Error) -> Bool {
        switch (self, error) {
        case (.status(let status), let error as SpeechAPIError):
            if case .http(status) = error { true } else { false }
        case (.malformed, let error as SpeechAPIError):
            if case .invalidResponse = error { true } else { false }
        case (.dropped, let error as URLError): error.code == .networkConnectionLost
        default: false
        }
    }
}

private struct ClipAudio {
    let url = FileManager.default.temporaryDirectory.appending(path: "betterwispr-api-test-\(UUID()).wav")

    init(clips: Int, seconds: Int = 100) throws {
        var pcm = Data()
        for clip in 0..<clips {
            pcm.append(Data(repeating: ClipEndpoint.levelByte(of: clip), count: 16_000 * 2 * (clip == clips - 1 ? seconds : 125)))
        }
        var wav = SpeechAudio.wav([])
        wav.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(pcm.count + 36).littleEndian) { Data($0) })
        wav.replaceSubrange(40..<44, with: withUnsafeBytes(of: UInt32(pcm.count).littleEndian) { Data($0) })
        try (wav + pcm).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class ClipEndpoint: Sendable {
    struct State: Sendable {
        var started: [Int] = []
        var stopped: [Int] = []
        var waiting: Set<Int> = []
        var active = 0
        var mostActive = 0
    }

    static let all = OSAllocatedUnfairLock(initialState: [String: ClipEndpoint]())
    let path = "/\(UUID())"
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let stubs = OSAllocatedUnfairLock(initialState: [Int: ClipStub]())

    init() { Self.all.withLock { $0[path] = self } }

    var state: State { lock.withLock { $0 } }

    @MainActor
    func provider() async throws -> APISpeechProvider {
        var connection = SpeechConnection(api: .openAICompatible)
        connection.endpoint = "https://speech.example\(path)"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClipStub.self]
        let provider = APISpeechProvider(configuration: config, key: { _ in "" })
        try await provider.prepare(model: connection.speechModel, download: false)
        return provider
    }

    static func levelByte(of clip: Int) -> UInt8 { UInt8(clip + 1) * 12 }

    static func clip(inBody body: Data) -> Int? {
        guard let riff = body.range(of: Data("RIFF".utf8))?.lowerBound, body.count > riff + 1_045 else { return nil }
        return (Int(body[riff + 1_045]) + 6) / 12 - 1
    }

    func start(_ clip: Int, stub: ClipStub) {
        stubs.withLock { $0[clip] = stub }
        lock.withLock {
            $0.started.append(clip)
            $0.waiting.insert(clip)
            $0.active += 1
            $0.mostActive = max($0.mostActive, $0.active)
        }
    }

    func stop(_ clip: Int) {
        stubs.withLock { $0[clip] = nil }
        lock.withLock {
            guard $0.waiting.remove(clip) != nil else { return }
            $0.stopped.append(clip)
            $0.active -= 1
        }
    }

    func answer(_ clip: Int, with reply: ClipReply) {
        guard let stub = stubs.withLock({ $0.removeValue(forKey: clip) }) else { return }
        lock.withLock {
            $0.waiting.remove(clip)
            $0.active -= 1
        }
        stub.deliver(reply)
    }

    func waitUntil(_ condition: @Sendable (State) -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition(state) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(state)
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
}

// URLProtocol is not Sendable, and URLSession calls this subclass on its own threads. Its only stored
// property is immutable; everything it shares lives behind the locks in ClipEndpoint.
private final class ClipStub: URLProtocol, @unchecked Sendable {
    private let clip: Int?

    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: (any URLProtocolClient)?) {
        clip = ClipEndpoint.clip(inBody: Self.start(of: request))
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var endpoint: ClipEndpoint? { ClipEndpoint.all.withLock { $0[request.url!.path] } }

    private static func start(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        stream.open()
        defer { stream.close() }
        let read = stream.read(&buffer, maxLength: buffer.count)
        return Data(buffer.prefix(max(0, read)))
    }

    override func startLoading() {
        if let clip { endpoint?.start(clip, stub: self) }
    }

    override func stopLoading() {
        if let clip { endpoint?.stop(clip) }
    }

    func deliver(_ reply: ClipReply) {
        if case .dropped = reply {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var status = 200
        var body = Data("{}".utf8)
        switch reply {
        case .text(let text): body = Data(#"{"text":"\#(text)"}"#.utf8)
        case .status(let code): status = code
        case .malformed, .dropped: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
