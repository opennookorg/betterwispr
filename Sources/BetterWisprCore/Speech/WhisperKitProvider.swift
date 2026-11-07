import CoreML
import Foundation
@preconcurrency import WhisperKit

@MainActor
public final class WhisperKitProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    /// Language codes automatic detection chooses from; empty allows every language the model knows.
    public var detectionLanguages: Set<String> = []
    public nonisolated static var defaultModelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "BetterWispr/Models", directoryHint: .isDirectory)
    }
    private let modelsDirectory: URL
    private var runtime: WhisperKit?
    private var loadedModelID: String?
    private var preparing = false
    private var transcriptionTask: Task<String, any Error>?
    private var transcriptionID: UUID?

    public init(modelsDirectory: URL = WhisperKitProvider.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    public static func isInstalled(_ model: SpeechModel, modelsDirectory: URL = defaultModelsDirectory) -> Bool {
        guard model.engine == .whisperKit, let tokenizerName = model.tokenizerName else { return false }
        let hub = HubApiWrapper(downloadBase: modelsDirectory)
        let modelFolder = hub.localRepoLocation(.init(id: "argmaxinc/whisperkit-coreml")).appending(path: model.modelName)
        let tokenizerFolder = hub.localRepoLocation(.init(id: tokenizerName))
        guard FileManager.default.fileExists(atPath: modelFolder.appending(path: ".betterwispr-installed").path) else { return false }
        let assets = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        return assets.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { FileManager.default.fileExists(atPath: modelFolder.appending(path: "\(name).\($0)").path) }
        } && ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: tokenizerFolder.appending(path: $0).path)
        }
    }

    /// Replaces a downloader error that carries no description, such as a failed Hugging Face request, with a readable one.
    nonisolated static func readableDownloadError(_ error: any Error) -> any Error {
        let undescribed = !(error is LocalizedError || error is CancellationError)
            && (error as NSError).domain == String(reflecting: type(of: error))
        return undescribed ? SpeechError.downloadFailed : error
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard model.engine == .whisperKit, let tokenizerName = model.tokenizerName else { throw SpeechError.invalidModel }
        guard !preparing, transcriptionTask == nil else { throw SpeechError.busy }
        if loadedModelID == model.id, runtime != nil { onProgress?(1); return }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        let hub = HubApiWrapper(downloadBase: modelsDirectory)
        var modelFolder = hub.localRepoLocation(.init(id: "argmaxinc/whisperkit-coreml")).appending(path: model.modelName)
        var tokenizerFolder = hub.localRepoLocation(.init(id: tokenizerName))
        if download && !Self.isInstalled(model, modelsDirectory: modelsDirectory) {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            onProgress?(0)
            let progress = onProgress
            do {
                modelFolder = try await WhisperKit.download(variant: model.modelName, downloadBase: modelsDirectory) { value in
                    let fraction = value.fractionCompleted * 0.9
                    Task { @MainActor in progress?(fraction) }
                }
                try Task.checkCancellation()
                tokenizerFolder = try await hub.snapshot(from: .init(id: tokenizerName), matching: ["tokenizer.json", "tokenizer_config.json", "config.json"])
            } catch {
                throw Self.readableDownloadError(error)
            }
        }
        guard download || Self.isInstalled(model, modelsDirectory: modelsDirectory) else { throw SpeechError.modelNotInstalled(model.name) }
        onProgress?(0.95)
        // Load strictly from disk before creating WhisperKit. Its default tokenizer loader
        // can silently fetch assets from Hugging Face, including after a local parse error.
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: tokenizerFolder)
        let localTokenizer = try LocalWhisperTokenizer(tokenizer: tokenizer)
        try Task.checkCancellation()
        runtime = nil
        loadedModelID = nil
        let pipeline = try await WhisperKit(WhisperKitConfig(
            model: model.modelName, modelFolder: modelFolder.path, tokenizerFolder: tokenizerFolder,
            verbose: false, prewarm: false, load: false, download: false
        ))
        pipeline.tokenizer = localTokenizer
        // All catalog models are multilingual. Injecting a tokenizer skips WhisperKit's
        // metadata detection; this flag must still be set for language detection.
        pipeline.textDecoder.isModelMultilingual = true
        try await pipeline.loadModels()
        try Task.checkCancellation()
        // A partial download must remain installable instead of appearing ready in the dashboard.
        if download {
            try Data(model.modelName.utf8).write(to: modelFolder.appending(path: ".betterwispr-installed"), options: .atomic)
        }
        runtime = pipeline
        loadedModelID = model.id
        onProgress?(1)
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard let runtime, !preparing else { throw SpeechError.notPrepared }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        guard audioURL.isFileURL, FileManager.default.fileExists(atPath: audioURL.path) else { throw SpeechError.audioUnavailable }
        try Task.checkCancellation()
        let prompt = vocabulary.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(64).map { String($0.prefix(100)) }.joined(separator: ", ")
        let promptTokens = prompt.isEmpty ? nil : runtime.tokenizer.map { Array($0.encode(text: " " + prompt).prefix(160)) }
        let languageCode = SpeechModel.engineLanguage(language)
        let options = DecodingOptions(
            language: languageCode, temperature: 0, temperatureFallbackCount: 2,
            detectLanguage: languageCode == nil, skipSpecialTokens: true, withoutTimestamps: true,
            promptTokens: promptTokens, suppressBlank: true,
            compressionRatioThreshold: 2.4, logProbThreshold: -1, noSpeechThreshold: 0.6,
            concurrentWorkerCount: 1, chunkingStrategy: .vad
        )
        let candidates = languageCode == nil ? detectionLanguages : []
        let id = UUID()
        transcriptionID = id
        let task = Task {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            try Task.checkCancellation()
            // Whisper can invent words for digital silence even with its no-speech filter.
            guard Self.containsSignal(in: samples) else { return "" }
            var options = options
            if let detected = try await Self.detectLanguage(in: samples, among: candidates, using: runtime) {
                options.language = detected
                options.detectLanguage = false
            }
            try Task.checkCancellation()
            let results = try await runtime.transcribe(audioArray: samples, decodeOptions: options) { [weak self] progress in
                if Task.isCancelled { return false }
                let text = progress.text
                Task { @MainActor [weak self] in
                    guard let self, self.transcriptionID == id else { return }
                    self.onPartialTranscript?(text)
                }
                return nil
            }
            try Task.checkCancellation()
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        transcriptionTask = task
        defer { transcriptionTask = nil; transcriptionID = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func cancel() {
        transcriptionID = nil
        transcriptionTask?.cancel()
    }

    nonisolated static func containsSignal(in samples: [Float]) -> Bool {
        samples.contains { $0.isFinite && abs($0) > 0.00001 }
    }

    private static func detectLanguage(in samples: [Float], among codes: Set<String>, using pipeline: WhisperKit) async throws -> String? {
        guard let tokenizer = pipeline.tokenizer else { throw SpeechError.notPrepared }
        let languageTokens = Set(codes.compactMap { code -> Int? in
            let token = "<|\(code)|>"
            return tokenizer.convertTokenToId(token).flatMap { tokenizer.convertIdToToken($0) == token ? $0 : nil }
        })
        guard !languageTokens.isEmpty else { return nil }
        let window = pipeline.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard let audio = pipeline.audioProcessor.padOrTrim(fromArray: samples, startAt: 0, toLength: window),
              let features = try await pipeline.featureExtractor.logMelSpectrogram(fromAudio: audio),
              let encoded = try await pipeline.audioEncoder.encodeFeatures(features)
        else { throw WhisperError.transcriptionFailed(L10n.tr("Language detection failed")) }
        let inputs = try pipeline.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        let result = try await pipeline.textDecoder.detectLanguage(
            from: encoded, using: inputs, sampler: AllowedLanguageSampler(languageTokens: languageTokens),
            options: DecodingOptions(), temperature: 0
        )
        return result.language
    }
}

struct AllowedLanguageSampler: TokenSampling {
    let languageTokens: Set<Int>

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        let likeliest = languageTokens.max { logits[[0, 0, NSNumber(value: $0)]].floatValue < logits[[0, 0, NSNumber(value: $1)]].floatValue }
        guard let likeliest else { return finalize(tokens: tokens, logProbs: logProbs) }
        return SamplingResult(tokens: tokens + [likeliest], logProbs: logProbs + [0], completed: true)
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        SamplingResult(tokens: tokens, logProbs: logProbs, completed: true)
    }
}
