import FluidAudio
import Foundation

@MainActor
public final class CohereProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private let modelsDirectory: URL
    private var loaded: (pipeline: CoherePipeline, models: CoherePipeline.LoadedModels)?
    private var preparing = false
    private var transcriptionTask: Task<String, any Error>?

    nonisolated static let repo = Repo.cohereTranscribeCoreml
    nonisolated static let requiredFiles = ModelNames.CohereTranscribe.requiredModels

    public init(modelsDirectory: URL = WhisperKitProvider.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    /// Whether this Mac's Core ML can load the INT8 encoder, which needs macOS 15.
    public nonisolated static var runsOnThisMac: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    nonisolated static func folder(modelsDirectory: URL) -> URL {
        modelsDirectory.appending(path: "Cohere/\(repo.folderName)", directoryHint: .isDirectory)
    }

    public static func isInstalled(_ model: SpeechModel, modelsDirectory: URL = WhisperKitProvider.defaultModelsDirectory) -> Bool {
        guard model.engine == .cohere else { return false }
        let folder = folder(modelsDirectory: modelsDirectory)
        return (requiredFiles + [".betterwispr-installed"]).allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// The model's language for a saved setting; Cohere cannot detect one, so automatic or unsupported settings use the first supported system language, else English.
    nonisolated static func language(for identifier: String?, preferred: [String] = Locale.preferredLanguages) -> CohereAsrConfig.Language {
        ([identifier] + preferred).lazy.compactMap { SpeechModel.engineLanguage($0).flatMap(CohereAsrConfig.Language.init(rawValue:)) }.first ?? .english
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard model.engine == .cohere else { throw SpeechError.invalidModel }
        guard !preparing, transcriptionTask == nil else { throw SpeechError.busy }
        if loaded != nil { onProgress?(1); return }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        let folder = Self.folder(modelsDirectory: modelsDirectory)
        if download && !Self.isInstalled(model, modelsDirectory: modelsDirectory) {
            let base = modelsDirectory.appending(path: "Cohere", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            onProgress?(0)
            let progress = onProgress
            try await ModelHub.download(Self.repo, to: base) { value in
                let fraction = ParakeetProvider.downloadedFraction(value) * 0.9
                Task { @MainActor in progress?(fraction) }
            }
            try Task.checkCancellation()
        }
        guard download || Self.isInstalled(model, modelsDirectory: modelsDirectory) else { throw SpeechError.modelNotInstalled(model.name) }
        onProgress?(0.95)
        let models = try await CoherePipeline.loadModels(encoderDir: folder, decoderDir: folder, vocabDir: folder)
        try Task.checkCancellation()
        if download {
            try Data(model.modelName.utf8).write(to: folder.appending(path: ".betterwispr-installed"), options: .atomic)
        }
        loaded = (CoherePipeline(), models)
        onProgress?(1)
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard audioURL.isFileURL, FileManager.default.fileExists(atPath: audioURL.path) else { throw SpeechError.audioUnavailable }
        guard let (pipeline, models) = loaded, !preparing else { throw SpeechError.notPrepared }
        if let cancelled = transcriptionTask, cancelled.isCancelled {
            _ = try? await cancelled.value
            if transcriptionTask == cancelled { transcriptionTask = nil }
        }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        try Task.checkCancellation()
        let cohereLanguage = Self.language(for: language)
        let task = Task { () async throws -> String in
            let samples = try await Self.samples(of: audioURL)
            let result = try await pipeline.transcribeLong(audio: samples, models: models, language: cohereLanguage)
            try Task.checkCancellation()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        transcriptionTask = task
        defer { if transcriptionTask == task { transcriptionTask = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    @concurrent
    private nonisolated static func samples(of audioURL: URL) async throws -> [Float] {
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw SpeechError.emptyAudio }
        return samples
    }

    public func cancel() {
        transcriptionTask?.cancel()
    }
}
