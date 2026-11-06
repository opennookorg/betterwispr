@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
public final class AppleSpeechProvider: SpeechProvider {
    public var onProgress: (@MainActor @Sendable (Double) -> Void)?
    public var onPartialTranscript: (@MainActor @Sendable (String) -> Void)?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var requestID: UUID?
    private var prepared = false

    public init() {}

    public static func checkAvailability(language: String?) throws {
        _ = try onDeviceRecognizer(language: language)
    }

    private static func onDeviceRecognizer(language: String?) throws -> SFSpeechRecognizer {
        let locale = language.map { Locale(identifier: $0) } ?? .current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.onDeviceUnavailable(locale.identifier)
        }
        return recognizer
    }

    public func prepare(model: SpeechModel, download: Bool) async throws {
        guard model.engine == .apple else { throw SpeechError.invalidModel }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        try Task.checkCancellation()
        guard status == .authorized else { throw SpeechError.permissionDenied }
        prepared = true
        onProgress?(1)
    }

    public func transcribe(audioURL: URL, language: String?, vocabulary: [String]) async throws -> String {
        guard prepared else { throw SpeechError.notPrepared }
        guard requestID == nil else { throw SpeechError.busy }
        guard audioURL.isFileURL, FileManager.default.fileExists(atPath: audioURL.path) else { throw SpeechError.audioUnavailable }
        try Task.checkCancellation()
        let recognizer = try Self.onDeviceRecognizer(language: language)
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(100).map { String($0.prefix(100)) }
        let audioSeconds = (try? AVAudioFile(forReading: audioURL)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let id = UUID()
        requestID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let transcript = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id else { return }
                        if let transcript { self.onPartialTranscript?(transcript) }
                        if final, let transcript {
                            self.finish(.success(transcript), id: id)
                        } else if let error {
                            self.finish(.failure(error), id: id)
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120 + audioSeconds)) } catch { return }
                    self?.finish(.failure(SpeechError.timedOut), id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), id: id) }
        }
    }

    public func cancel() {
        if let requestID { finish(.failure(CancellationError()), id: requestID) }
    }

    private func finish(_ result: Result<String, any Error>, id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        pending?.resume(with: result)
    }
}
