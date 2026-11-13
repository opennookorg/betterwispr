import Foundation
import LlamaSwift
import os

public struct ChatPrompt: Sendable, Equatable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }

    /// Qwen's ChatML with thinking turned off.
    var segments: [(text: String, parsesSpecialTokens: Bool)] {
        [("<|im_start|>system\n", true), (system, false), ("<|im_end|>\n<|im_start|>user\n", true), (user, false),
         ("<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", true)]
    }
}

public enum LlamaEngineError: LocalizedError, Equatable {
    case modelMissing, loadFailed, contextFailed, grammarRejected
    case promptTooLong(tokens: Int, limit: Int)
    case replyTooLong(limit: Int)
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelMissing: L10n.tr("The built-in model isn’t downloaded. Download it in Models.")
        case .loadFailed, .contextFailed: L10n.tr("The built-in model couldn’t start on this Mac.")
        case .grammarRejected: L10n.tr("The built-in model couldn’t prepare its reply format.")
        case .promptTooLong: L10n.tr("This text is too long for the built-in model.")
        case .replyTooLong: L10n.tr("The built-in model’s reply ran past its limit.")
        case .decodeFailed: L10n.tr("The built-in model stopped unexpectedly. Try again.")
        }
    }
}

protocol LanguageWeights: AnyObject, Sendable {
    var contextLength: Int { get }
    func tokens(for prompt: ChatPrompt) throws -> [Int32]
    func open(grammar: String?) throws -> any TokenStream
    func close()
}

protocol TokenStream: AnyObject {
    func prefill(_ tokens: ArraySlice<Int32>) throws
    func next() throws -> Int32?
    func append(_ token: Int32) throws -> [UInt8]
}

public final class LlamaEngine: Sendable {
    public enum Lane: Sendable { case interactive, background }
    enum Verdict: Sendable { case proceed, pause, stop }

    static let contextLength = 8192
    static let replyReserve = 1024
    static let prefillChunk = 256

    public static let shared = LlamaEngine {
        guard BuiltInModel.isInstalled() else { throw LlamaEngineError.modelMissing }
        return try LlamaWeights(contentsOf: BuiltInModel.fileURL)
    }

    typealias Waiter = CheckedContinuation<any LanguageWeights, any Error>

    struct Request: Sendable {
        let lane: Lane
        var holdsWeights = false
        var cancelled = false
    }

    enum Phase: Sendable {
        case idle
        case loading([UUID: Waiter])
        case loaded(any LanguageWeights)
        case draining(any LanguageWeights)
        case closing([UUID: Waiter])

        var waiters: [UUID: Waiter] {
            get {
                switch self {
                case .loading(let waiters), .closing(let waiters): waiters
                case .idle, .loaded, .draining: [:]
                }
            }
            set {
                switch self {
                case .loading: self = .loading(newValue)
                case .closing: self = .closing(newValue)
                case .idle, .loaded, .draining: break
                }
            }
        }
    }

    struct State: Sendable {
        var phase = Phase.idle
        var requests: [UUID: Request] = [:]
        var accepting = true
        var uses = 0
        var holders: Bool { requests.values.contains(where: \.holdsWeights) }
    }

    private enum Admission: Sendable { case ready(any LanguageWeights), wait, load, refuse }

    private let load: @Sendable () throws -> any LanguageWeights
    private let idleDelay: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(idleDelay: Duration = .seconds(300), load: @escaping @Sendable () throws -> any LanguageWeights) {
        self.idleDelay = idleDelay
        self.load = load
    }

    /// Cancelling the task stops it by the next prefill batch or decode step.
    public func complete(_ prompt: ChatPrompt, lane: Lane, grammar: String? = nil) async throws -> String {
        try await run(lane: lane) { weights, checkpoint in
            try Self.generate(prompt, grammar: grammar, limit: nil, with: weights, checkpoint: checkpoint)
        }
    }

    public func warmUp() async {
        _ = try? await run(lane: .interactive) { _, _ in () }
    }

    func verify(grammar: String) async throws {
        _ = try await run(lane: .interactive) { weights, checkpoint in
            try Self.generate(ChatPrompt(system: "Reply with JSON.", user: "Say hello."), grammar: grammar, limit: 1, with: weights, checkpoint: checkpoint)
        }
    }

    /// Cancels running requests and frees the weights once they stop; later requests load again.
    public func unload() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.drain()
                continuation.resume()
            }
        }
    }

    /// Refuses new requests, cancels running ones and blocks until every llama object is freed, so exit cannot abort.
    public func shutdown() {
        let waiters = state.withLock { state -> [Waiter] in
            state.accepting = false
            for id in state.requests.keys { state.requests[id]?.cancelled = true }
            defer { state.phase.waiters = [:] }
            return Array(state.phase.waiters.values)
        }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        drain()
    }

    private func run<T: Sendable>(lane: Lane, _ work: @escaping @Sendable (any LanguageWeights, () -> Verdict) throws -> T) async throws -> T {
        let id = UUID()
        state.withLock { $0.requests[id] = Request(lane: lane) }
        defer { release(id) }
        return try await withTaskCancellationHandler {
            let weights = try await acquire(id)
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: lane == .interactive ? .userInitiated : .utility).async {
                    continuation.resume(with: Result { try work(weights) { self.verdict(for: id) } })
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func acquire(_ id: UUID) async throws -> any LanguageWeights {
        try await withCheckedThrowingContinuation { (continuation: Waiter) in
            let admission = state.withLock { state -> Admission in
                guard state.accepting, state.requests[id]?.cancelled == false else { return .refuse }
                switch state.phase {
                case .loaded(let weights):
                    state.requests[id]?.holdsWeights = true
                    state.uses += 1
                    return .ready(weights)
                case .loading, .closing:
                    state.phase.waiters[id] = continuation
                    return .wait
                case .idle:
                    state.phase = .loading([id: continuation])
                    return .load
                case .draining:
                    return .refuse
                }
            }
            switch admission {
            case .ready(let weights): continuation.resume(returning: weights)
            case .refuse: continuation.resume(throwing: CancellationError())
            case .wait: break
            case .load: startLoading()
            }
        }
    }

    private func startLoading() {
        DispatchQueue.global(qos: .userInitiated).async { self.finishLoading(Result { try self.load() }) }
    }

    private func finishLoading(_ result: Result<any LanguageWeights, any Error>) {
        let (waiters, orphan, stamp) = state.withLock { state -> ([Waiter], (any LanguageWeights)?, Int?) in
            guard case .loading(let waiters) = state.phase else { return ([], try? result.get(), nil) }
            guard case .success(let weights) = result else {
                state.phase = .idle
                return (Array(waiters.values), nil, nil)
            }
            guard state.accepting else {
                state.phase = .closing([:])
                return (Array(waiters.values), weights, nil)
            }
            state.phase = .loaded(weights)
            for id in waiters.keys { state.requests[id]?.holdsWeights = true }
            state.uses += 1
            return (Array(waiters.values), nil, waiters.isEmpty ? state.uses : nil)
        }
        finishClosing(orphan)
        for waiter in waiters { orphan == nil ? waiter.resume(with: result) : waiter.resume(throwing: CancellationError()) }
        if let stamp { scheduleIdleUnload(stamp) }
    }

    private func verdict(for id: UUID) -> Verdict {
        state.withLock { state in
            guard let request = state.requests[id], !request.cancelled else { return .stop }
            guard request.lane == .background else { return .proceed }
            return state.requests.values.contains { $0.lane == .interactive && $0.holdsWeights } ? .pause : .proceed
        }
    }

    private func cancel(_ id: UUID) {
        let waiter = state.withLock { state -> Waiter? in
            state.requests[id]?.cancelled = true
            return state.phase.waiters.removeValue(forKey: id)
        }
        waiter?.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        let (retired, stamp) = state.withLock { state -> ((any LanguageWeights)?, Int?) in
            state.requests[id] = nil
            guard !state.holders else { return (nil, nil) }
            switch state.phase {
            case .draining(let weights):
                state.phase = .closing([:])
                return (weights, nil)
            case .loaded: return (nil, state.uses)
            case .idle, .loading, .closing: return (nil, nil)
            }
        }
        finishClosing(retired)
        if let stamp { scheduleIdleUnload(stamp) }
    }

    private func scheduleIdleUnload(_ stamp: Int) {
        let seconds = Double(idleDelay.components.seconds) + Double(idleDelay.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let retired = self.state.withLock { state -> (any LanguageWeights)? in
                guard state.uses == stamp, !state.holders, case .loaded(let weights) = state.phase else { return nil }
                state.phase = .closing([:])
                return weights
            }
            self.finishClosing(retired)
        }
    }

    private func finishClosing(_ weights: (any LanguageWeights)?) {
        guard let weights else { return }
        weights.close()
        let reload = state.withLock { state -> Bool in
            let waiters = state.phase.waiters
            state.phase = waiters.isEmpty ? .idle : .loading(waiters)
            return !waiters.isEmpty
        }
        if reload { startLoading() }
    }

    private func drain() {
        while true {
            let (retired, unloaded) = state.withLock { state -> ((any LanguageWeights)?, Bool) in
                switch state.phase {
                case .idle: return (nil, true)
                case .loading, .draining, .closing: break
                case .loaded(let weights):
                    guard state.holders else {
                        state.phase = .closing([:])
                        return (weights, true)
                    }
                    state.phase = .draining(weights)
                }
                for id in state.requests.keys { state.requests[id]?.cancelled = true }
                return (nil, false)
            }
            finishClosing(retired)
            if unloaded { return }
            usleep(10_000)
        }
    }

    static func generate(_ prompt: ChatPrompt, grammar: String?, limit: Int?, with weights: any LanguageWeights,
                         checkpoint: () -> Verdict) throws -> String {
        let tokens = try weights.tokens(for: prompt)
        let room = weights.contextLength - tokens.count
        guard room >= replyReserve else { throw LlamaEngineError.promptTooLong(tokens: tokens.count, limit: weights.contextLength - replyReserve) }
        let stream = try weights.open(grammar: grammar)
        var start = 0
        while start < tokens.count {
            try proceed(checkpoint)
            let end = min(start + prefillChunk, tokens.count)
            try stream.prefill(tokens[start..<end])
            start = end
        }
        var bytes: [UInt8] = []
        for _ in 0..<min(room, limit ?? room) {
            try proceed(checkpoint)
            guard let token = try stream.next() else { return String(decoding: bytes, as: UTF8.self) }
            bytes += try stream.append(token)
        }
        guard limit != nil else { throw LlamaEngineError.replyTooLong(limit: room) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func proceed(_ checkpoint: () -> Verdict) throws {
        while true {
            switch checkpoint() {
            case .proceed: return
            case .pause: usleep(2_000)
            case .stop: throw CancellationError()
            }
        }
    }
}

/// `@unchecked Sendable`: the model is immutable after loading, llama.cpp lets contexts on separate threads share it, and the engine calls `close` only after every context over it is freed.
final class LlamaWeights: LanguageWeights, @unchecked Sendable {
    let contextLength = LlamaEngine.contextLength
    private let model: OpaquePointer
    private let vocab: OpaquePointer

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LlamaEngineError.modelMissing }
        _ = Self.backend
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = -1
        parameters.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let model = llama_model_load_from_file(url.path, parameters), let vocab = llama_model_get_vocab(model) else {
            throw LlamaEngineError.loadFailed
        }
        self.model = model
        self.vocab = vocab
    }

    func tokens(for prompt: ChatPrompt) throws -> [Int32] {
        try prompt.segments.flatMap { segment in
            var tokens = [llama_token](repeating: 0, count: segment.text.utf8.count + 8)
            let count = llama_tokenize(vocab, segment.text, Int32(segment.text.utf8.count), &tokens, Int32(tokens.count), false, segment.parsesSpecialTokens)
            guard count >= 0 else { throw LlamaEngineError.decodeFailed(count) }
            return tokens.prefix(Int(count))
        }
    }

    func open(grammar: String?) throws -> any TokenStream {
        var parameters = llama_context_default_params()
        parameters.n_ctx = UInt32(contextLength)
        parameters.n_batch = UInt32(LlamaEngine.prefillChunk)
        parameters.n_ubatch = UInt32(LlamaEngine.prefillChunk)
        parameters.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        parameters.type_k = GGML_TYPE_Q8_0
        parameters.type_v = GGML_TYPE_Q8_0
        guard let context = llama_init_from_model(model, parameters) else { throw LlamaEngineError.contextFailed }
        guard let grammar else { return LlamaStream(context: context, vocab: vocab, grammar: nil) }
        guard let sampler = llama_sampler_init_grammar(vocab, grammar, "root") else {
            llama_free(context)
            throw LlamaEngineError.grammarRejected
        }
        return LlamaStream(context: context, vocab: vocab, grammar: sampler)
    }

    func close() {
        llama_model_free(model)
    }
}

final class LlamaStream: TokenStream {
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let grammar: UnsafeMutablePointer<llama_sampler>?
    private let vocabularySize: Int

    init(context: OpaquePointer, vocab: OpaquePointer, grammar: UnsafeMutablePointer<llama_sampler>?) {
        self.context = context
        self.vocab = vocab
        self.grammar = grammar
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
    }

    deinit {
        if let grammar { llama_sampler_free(grammar) }
        llama_free(context)
    }

    func prefill(_ tokens: ArraySlice<Int32>) throws {
        var batch = Array(tokens)
        let status = batch.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
        guard status == 0 else { throw LlamaEngineError.decodeFailed(status) }
    }

    func next() throws -> Int32? {
        guard let logits = llama_get_logits_ith(context, -1) else { throw LlamaEngineError.decodeFailed(-1) }
        var token = Self.argmax(UnsafeBufferPointer(start: logits, count: vocabularySize))
        if let grammar {
            if !Self.allows(grammar, token, logit: logits[Int(token)]) { token = constrained(grammar, logits) }
            llama_sampler_accept(grammar, token)
        }
        return llama_vocab_is_eog(vocab, token) ? nil : token
    }

    func append(_ token: Int32) throws -> [UInt8] {
        var token = token
        let status = llama_decode(context, llama_batch_get_one(&token, 1))
        guard status == 0 else { throw LlamaEngineError.decodeFailed(status) }
        var piece = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
        return piece.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) }
    }

    private static func argmax(_ values: UnsafeBufferPointer<Float>) -> Int32 {
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return Int32(best)
    }

    private static func allows(_ grammar: UnsafeMutablePointer<llama_sampler>, _ token: Int32, logit: Float) -> Bool {
        var candidate = llama_token_data(id: token, logit: logit, p: 0)
        return withUnsafeMutablePointer(to: &candidate) { pointer in
            var array = llama_token_data_array(data: pointer, size: 1, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            return pointer.pointee.logit.isFinite
        }
    }

    private func constrained(_ grammar: UnsafeMutablePointer<llama_sampler>, _ logits: UnsafeMutablePointer<Float>) -> Int32 {
        var candidates = (0..<vocabularySize).map { llama_token_data(id: Int32($0), logit: logits[$0], p: 0) }
        return candidates.withUnsafeMutableBufferPointer { buffer in
            var array = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, selected: -1, sorted: false)
            llama_sampler_apply(grammar, &array)
            return buffer.max { $0.logit < $1.logit }?.id ?? llama_vocab_eos(vocab)
        }
    }
}
