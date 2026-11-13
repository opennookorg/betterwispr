import AppKit
import FluidAudio
import Foundation

@MainActor
public final class ParakeetProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    public private(set) var vocabularyFixes = 0
    public var usesPhraseBooster = true
    private let modelsDirectory: URL
    private var manager: AsrManager?
    private var loadedModelID: String?
    private var preparing = false
    private var transcriptionTask: Task<String, any Error>?
    private var livePass: Task<LivePass, any Error>?
    private var loadedVersion: AsrModelVersion?
    private var phraseBooster: CtcModels?
    private var boostingSession: (terms: [String], session: VocabularyBoostingSession)?

    nonisolated static let maximumBoostingTerms = ContextBiasingConstants.extraLargeVocabThreshold
    nonisolated static let boostingMinSimilarity: Float = 0.65
    nonisolated static let minimumRespellingResemblance = 0.75

    public init(modelsDirectory: URL = WhisperKitProvider.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
    }

    nonisolated static let phraseBoosterMegabytes = 100.0

    nonisolated static func source(for model: SpeechModel) -> (version: AsrModelVersion, repo: Repo, megabytes: Double)? {
        guard model.engine == .parakeet else { return nil }
        return switch model.modelName {
        case "parakeet-tdt-0.6b-v3": (.v3, .parakeetV3, 471)
        case "parakeet-tdt-0.6b-v2": (.v2, .parakeetV2, 460)
        case "parakeet-ultra": (.ultra, .parakeetUltra, 630)
        case "parakeet-tdt-ctc-110m": (.tdtCtc110m, .parakeetTdtCtc110m, 230)
        case "parakeet-ja": (.tdtJa, .parakeetJa, 620)
        default: nil
        }
    }

    nonisolated static func folder(for model: SpeechModel, modelsDirectory: URL) -> URL {
        modelsDirectory.appending(path: "Parakeet/\(model.modelName)", directoryHint: .isDirectory)
    }

    public static func isInstalled(_ model: SpeechModel, modelsDirectory: URL = WhisperKitProvider.defaultModelsDirectory) -> Bool {
        guard let source = source(for: model) else { return false }
        let folder = folder(for: model, modelsDirectory: modelsDirectory)
        return FileManager.default.fileExists(atPath: folder.appending(path: ".betterwispr-installed").path)
            && AsrModels.modelsExist(at: folder, version: source.version)
    }

    public nonisolated static var phraseBoosterDirectory: URL { CtcModels.defaultCacheDirectory(for: .ctc110m) }

    public nonisolated static func isPhraseBoosterInstalled(at directory: URL = phraseBoosterDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: ".betterwispr-installed").path)
            && CtcModels.modelsExist(at: directory)
    }

    nonisolated static func boostingTerms(_ vocabulary: [String]) -> [String] {
        let minimumLength = CustomVocabularyContext(terms: []).minTermLength
        var seen = Set<String>()
        var terms: [String] = []
        for entry in vocabulary {
            let term = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= minimumLength, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maximumBoostingTerms { break }
        }
        return terms
    }

    private nonisolated static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func alreadySaysTerm(_ replacement: (original: String, replacement: String)) -> Bool {
        let spoken = letters(replacement.original)
        let term = letters(replacement.replacement)
        return !term.isEmpty && spoken != term && spoken.contains(term)
    }

    /// Keeps the spoken words when they already hold the term, or are correctly spelled English that only loosely resembles it or that a term read from the screen would replace.
    nonisolated static func keepsOriginal(_ replacement: (original: String, replacement: String), spelledCorrectly: Bool, readFromScreen: Bool = false) -> Bool {
        let spoken = letters(replacement.original)
        let term = letters(replacement.replacement)
        let resemblance = 1 - Double(StringUtils.levenshteinDistance(spoken, term)) / Double(max(1, spoken.count, term.count))
        return alreadySaysTerm(replacement) || (spelledCorrectly && (readFromScreen || resemblance < minimumRespellingResemblance))
    }

    nonisolated static func restoringPunctuation(original: String, rescored: String,
                                                 replacements: [(original: String, replacement: String, keepsOriginal: Bool)]) -> String {
        let originalWords = original.split(separator: " ")
        let rescoredWords = rescored.split(separator: " ")
        let spans = replacements
            .map { (original: $0.original.split(separator: " "), replacement: $0.replacement.split(separator: " "), keepsOriginal: $0.keepsOriginal) }
            .filter { !$0.original.isEmpty && !$0.replacement.isEmpty }
        var words: [String] = []
        var originalIndex = 0
        var rescoredIndex = 0
        while originalIndex < originalWords.count, rescoredIndex < rescoredWords.count {
            if let span = spans.first(where: {
                originalWords[originalIndex...].starts(with: $0.original) && rescoredWords[rescoredIndex...].starts(with: $0.replacement)
            }) {
                if span.keepsOriginal {
                    words += span.original.map(String.init)
                } else {
                    let first = originalWords[originalIndex]
                    let last = originalWords[originalIndex + span.original.count - 1]
                    let leading = first.firstIndex { $0.isLetter || $0.isNumber }.map { String(first[..<$0]) } ?? ""
                    let trailing = last.lastIndex { $0.isLetter || $0.isNumber }.map { String(last[last.index(after: $0)...]) } ?? ""
                    var replaced = span.replacement.map(String.init)
                    if !replaced[0].hasPrefix(leading) { replaced[0] = leading + replaced[0] }
                    if !replaced[replaced.count - 1].hasSuffix(trailing) { replaced[replaced.count - 1] += trailing }
                    words += replaced
                }
                originalIndex += span.original.count
                rescoredIndex += span.replacement.count
            } else if originalWords[originalIndex] == rescoredWords[rescoredIndex] {
                words.append(String(originalWords[originalIndex]))
                originalIndex += 1
                rescoredIndex += 1
            } else {
                return spans.contains(where: \.keepsOriginal) ? original : rescored
            }
        }
        guard originalIndex == originalWords.count, rescoredIndex == rescoredWords.count else {
            return spans.contains(where: \.keepsOriginal) ? original : rescored
        }
        return words.joined(separator: " ")
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard let source = Self.source(for: model) else { throw SpeechError.invalidModel }
        guard !preparing, transcriptionTask == nil, livePass == nil else { throw SpeechError.busy }
        if loadedModelID == model.id, manager != nil { onProgress?(1); return }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        let folder = Self.folder(for: model, modelsDirectory: modelsDirectory)
        if download && !Self.isInstalled(model, modelsDirectory: modelsDirectory) {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            onProgress?(0)
            try await Self.download(source, to: folder, withBooster: !Self.isPhraseBoosterInstalled(), progress: onProgress)
            try Task.checkCancellation()
        }
        guard download || Self.isInstalled(model, modelsDirectory: modelsDirectory) else { throw SpeechError.modelNotInstalled(model.name) }
        onProgress?(0.95)
        manager = nil
        loadedModelID = nil
        let models = try await Task.detached { try AsrModels.loadLocal(from: folder, version: source.version) }.value
        let asr = AsrManager()
        try await asr.loadModels(models)
        try Task.checkCancellation()
        if download {
            try Data(model.modelName.utf8).write(to: folder.appending(path: ".betterwispr-installed"), options: .atomic)
        }
        await loadPhraseBoosterIfInstalled()
        manager = asr
        loadedModelID = model.id
        loadedVersion = source.version
        onProgress?(1)
    }

    /// Fetches the model in one pass while the phrase booster downloads beside it; a booster failure leaves the model usable.
    private static func download(
        _ source: (version: AsrModelVersion, repo: Repo, megabytes: Double), to folder: URL, withBooster: Bool,
        progress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws {
        let shares = DownloadShares(megabytes: [source.megabytes, withBooster ? phraseBoosterMegabytes : 0]) { progress?($0 * 0.9) }
        let variant = source.version == .v3 ? ParakeetEncoderPrecision.int8.rawValue : nil
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await ModelHub.download(source.repo, to: folder.deletingLastPathComponent(), variant: variant) { value in
                    let fraction = downloadedFraction(value)
                    Task { @MainActor in shares.update(0, to: fraction) }
                }
            }
            if withBooster {
                group.addTask {
                    do {
                        try await installPhraseBooster { fraction in Task { @MainActor in shares.update(1, to: fraction) } }
                    } catch {
                        await shares.update(1, to: 1)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// `ModelHub.download` reports file bytes in the first half of its range and reserves the rest for compilation it skips.
    nonisolated static func downloadedFraction(_ progress: DownloadProgress) -> Double {
        min(1, max(0, progress.fractionCompleted * 2))
    }

    /// Downloads and verifies the CTC phrase booster after an explicit installation action.
    public nonisolated static func installPhraseBooster(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let directory = phraseBoosterDirectory
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ModelHub.download(CtcModelVariant.ctc110m.repo, to: directory.deletingLastPathComponent()) { progress?(downloadedFraction($0)) }
        try Task.checkCancellation()
        _ = try await CtcModels.loadDirect(from: directory)
        _ = try await CtcTokenizer.load(from: directory)
        try Task.checkCancellation()
        try Data(directory.lastPathComponent.utf8).write(to: directory.appending(path: ".betterwispr-installed"), options: .atomic)
    }

    private func loadPhraseBoosterIfInstalled() async {
        guard phraseBooster == nil, Self.isPhraseBoosterInstalled() else { return }
        phraseBooster = try? await CtcModels.loadDirect(from: Self.phraseBoosterDirectory)
    }

    nonisolated static func hint(for language: String?) -> Language? {
        language.flatMap { Locale(identifier: $0).language.languageCode?.identifier }.flatMap(Language.init(rawValue:))
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        try await transcribe(audioURL: audioURL, language: language, vocabulary: vocabulary, screenTerms: [])
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String], screenTerms: [String]) async throws -> String {
        guard let manager, !preparing else { throw SpeechError.notPrepared }
        if let livePass { _ = try? await livePass.value }
        guard transcriptionTask == nil else { throw SpeechError.busy }
        guard audioURL.isFileURL, FileManager.default.fileExists(atPath: audioURL.path) else { throw SpeechError.audioUnavailable }
        try Task.checkCancellation()
        let hint = Self.hint(for: language)
        let terms = usesPhraseBooster && loadedVersion != .tdtJa && (hint == nil || hint == .english) ? Self.boostingTerms(vocabulary + screenTerms) : []
        vocabularyFixes = 0
        let task = Task {
            let text: String
            if let session = await self.boostingSession(for: terms) {
                (text, self.vocabularyFixes) = try await Self.boostedTranscript(of: audioURL, language: hint, manager: manager, session: session, vocabulary: vocabulary)
            } else {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                text = try await manager.transcribe(audioURL, decoderState: &state, language: hint).text
            }
            try Task.checkCancellation()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        transcriptionTask = task
        defer { transcriptionTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// One recognizer pass for the live preview; word timings are relative to `samples`.
    public func liveTranscribe(_ samples: [Float], language: String?) async throws -> LivePass {
        guard let manager, !preparing else { throw SpeechError.notPrepared }
        guard transcriptionTask == nil, livePass == nil else { throw SpeechError.busy }
        let hint = Self.hint(for: language)
        let task = Task {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
            try Task.checkCancellation()
            return LivePass(words: TimedWord.words(from: result.tokenTimings ?? []), confidence: result.confidence)
        }
        livePass = task
        defer { livePass = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// 16 kHz mono samples of a file, for feeding recorded audio through the live preview.
    public nonisolated static func samples(of url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }

    public func cancel() {
        transcriptionTask?.cancel()
        livePass?.cancel()
    }

    private func boostingSession(for terms: [String]) async -> VocabularyBoostingSession? {
        guard !terms.isEmpty else { return nil }
        await loadPhraseBoosterIfInstalled()
        guard let phraseBooster else { return nil }
        if let boostingSession, boostingSession.terms == terms { return boostingSession.session }
        let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }, minSimilarity: Self.boostingMinSimilarity)
        guard let session = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: phraseBooster, config: VocabularyBoostingSession.itnDefaultConfig) else { return nil }
        boostingSession = (terms, session)
        return session
    }

    @concurrent
    private nonisolated static func boostedTranscript(
        of audioURL: URL, language: Language?, manager: AsrManager, session: VocabularyBoostingSession, vocabulary: [String]
    ) async throws -> (text: String, fixes: Int) {
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        try Task.checkCancellation()
        let misspelled = await MainActor.run { !isSpelledCorrectly(result.text) }
        guard language != nil || TranscriptCleaner.isEnglish(result.text, language: nil),
              misspelled || !vocabulary.isEmpty,
              let rescored = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples),
              rescored.wasModified else { return (result.text, 0) }
        let candidates = rescored.replacements.compactMap { item in
            item.shouldReplace ? item.replacementWord.map { (original: item.originalWord, replacement: $0) } : nil
        }
        let spelling = await MainActor.run { candidates.map { isSpelledCorrectly($0.original) } }
        let (replacements, fixes) = judging(candidates, spelledCorrectly: spelling, vocabulary: vocabulary)
        let text = restoringPunctuation(original: result.text, rescored: rescored.text, replacements: replacements)
        return (text, text == result.text ? 0 : fixes)
    }

    /// Marks the rescored words to keep, treating a term outside `vocabulary` as read from the screen, and counts the vocabulary terms that replace a word.
    nonisolated static func judging(
        _ candidates: [(original: String, replacement: String)], spelledCorrectly: [Bool], vocabulary: [String]
    ) -> (replacements: [(original: String, replacement: String, keepsOriginal: Bool)], vocabularyFixes: Int) {
        let userTerms = Set(vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let replacements = zip(candidates, spelledCorrectly).map { candidate, spelledCorrectly in
            let readFromScreen = !userTerms.contains(candidate.replacement.lowercased())
            return (original: candidate.original, replacement: candidate.replacement,
                    keepsOriginal: keepsOriginal(candidate, spelledCorrectly: spelledCorrectly, readFromScreen: readFromScreen))
        }
        let fixes = replacements.count { $0.original != $0.replacement && !$0.keepsOriginal && userTerms.contains($0.replacement.lowercased()) }
        return (replacements, fixes)
    }

    @MainActor
    static func isSpelledCorrectly(_ words: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: words, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

/// Combines parallel downloads into one monotonic fraction weighted by their sizes.
@MainActor
final class DownloadShares {
    private let megabytes: [Double]
    private var fractions: [Double]
    private let report: @MainActor (Double) -> Void

    init(megabytes: [Double], report: @escaping @MainActor (Double) -> Void) {
        self.megabytes = megabytes
        fractions = megabytes.map { _ in 0 }
        self.report = report
    }

    var total: Double {
        let size = megabytes.reduce(0, +)
        return size > 0 ? zip(fractions, megabytes).map { $0 * $1 }.reduce(0, +) / size : 0
    }

    func update(_ index: Int, to fraction: Double) {
        fractions[index] = max(fractions[index], min(1, fraction))
        report(total)
    }
}
