import AppKit
import BetterWisprCore
import Observation

/// The file or link being transcribed; `stage` is nil while the speech model loads.
struct TranscriptionJob: Equatable {
    let id = UUID()
    var title: String
    let modelName: String
    var stage: MediaStage?
}

/// Transcribes one media file or web link at a time and keeps the saved transcripts.
@MainActor @Observable
final class TranscriptionModel {
    var transcripts: [Meeting] = []
    /// The transcript open on the page; nil shows the list.
    var selectedID: UUID?
    private(set) var job: TranscriptionJob?
    var error: String?
    /// The speech model picked on the page; nil follows the dictation model.
    var modelID: String?
    private(set) var ytDLP = YTDLP.executable
    private(set) var isInstallingYTDLP = false

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    @ObservationIgnored private var provider: (any SpeechProvider)?

    init(store: MeetingStore? = nil) {
        self.store = store ?? MeetingStore(directory: URL.applicationSupportDirectory.appending(path: "BetterWispr/Transcriptions"))
        if store == nil { Self.removeLeftovers() }
        let loaded = self.store.load()
        transcripts = loaded.meetings
        if !loaded.unreadable.isEmpty {
            let count = loaded.unreadable.count
            error = L10n.tr("Unreadable transcript files in %@: %@. They were left untouched.", self.store.directory.path, String(count))
        }
    }

    func transcript(_ id: UUID) -> Meeting? { transcripts.first { $0.id == id } }

    func transcribe(file: URL, with model: SpeechModel, provider: any SpeechProvider, language: String?, vocabulary: [VocabularyEntry], onSaved: @escaping () -> Void = {}) {
        start(file.deletingPathExtension().lastPathComponent, model: model, provider: provider, language: language, onSaved: onSaved) { [weak self] id in
            try await MediaTranscriber.transcribe(file, with: provider, language: language, vocabulary: vocabulary) { self?.update(id, stage: $0) }
        }
    }

    func transcribe(link text: String, with model: SpeechModel, provider: any SpeechProvider, language: String?, vocabulary: [VocabularyEntry]) {
        let link: MediaLink
        do { link = try MediaLink(text) } catch {
            self.error = error.localizedDescription
            return
        }
        start(link.url.absoluteString, model: model, provider: provider, language: language) { [weak self] id in
            try await YTDLP.download(link, progress: { self?.update(id, stage: .downloading($0)) }) { audio, title in
                self?.update(id, title: title, stage: .reading)
                return try await MediaTranscriber.transcribe(audio, with: provider, language: language, vocabulary: vocabulary) { self?.update(id, stage: $0) }
            }
        }
    }

    func cancel() {
        guard job != nil else { return }
        job = nil
        work?.cancel()
        work = nil
        provider?.cancel()
        provider = nil
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
        } catch {
            self.error = L10n.tr("Couldn’t delete the transcript. %@", String(error.localizedDescription))
            return
        }
        transcripts.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func copy(_ id: UUID) {
        guard let text = transcript(id)?.transcriptionText else { return }
        Task {
            do { ToastWindow.shared.show(Toast(try await ClipboardIntegration().deliver(text, to: nil))) }
            catch { ToastWindow.shared.show(Toast(failure: L10n.tr("Couldn’t copy"), error)) }
        }
    }

    /// Installs or updates BetterWispr's own copy of yt-dlp; runs only when the user asks.
    func installYTDLP() {
        guard !isInstallingYTDLP else { return }
        isInstallingYTDLP = true
        error = nil
        Task {
            defer { isInstallingYTDLP = false }
            do {
                try await YTDLP.install()
                ytDLP = YTDLP.executable
            } catch {
                self.error = L10n.tr("Couldn’t install yt-dlp. %@", String(error.localizedDescription))
            }
        }
    }

    func endForQuit() {
        YTDLP.running?.terminate()
        cancel()
        Self.removeLeftovers()
    }

    private func start(_ title: String, model: SpeechModel, provider: any SpeechProvider, language: String?, onSaved: @escaping () -> Void = {},
                       transcribe: @escaping (UUID) async throws -> MediaTranscript) {
        guard job == nil else { return }
        let started = TranscriptionJob(title: title, modelName: model.localizedName)
        job = started
        error = nil
        self.provider = provider
        work = Task { [weak self] in
            do {
                if model.engine == .apple { try AppleSpeechProvider.checkAvailability(language: language) }
                try model.connection?.validateLanguage(language)
                try await provider.prepare(model: model, download: false)
                try Task.checkCancellation()
                guard self?.job?.id == started.id else { return }
                let transcript = try await transcribe(started.id)
                guard let self, let job = self.job, job.id == started.id else { return }
                self.finish(job.title, transcript: transcript, model: model, language: language, onSaved: onSaved)
            } catch {
                guard let self, self.job?.id == started.id else { return }
                self.cancel()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func update(_ id: UUID, title: String? = nil, stage: MediaStage) {
        guard job?.id == id else { return }
        job?.stage = stage
        if let title { job?.title = title }
    }

    private func finish(_ title: String, transcript: MediaTranscript, model: SpeechModel, language: String?, onSaved: () -> Void) {
        job = nil
        work = nil
        provider = nil
        guard !transcript.segments.isEmpty else {
            error = L10n.tr("No speech was found in “%@”.", String(title))
            return
        }
        let record = Meeting(title: title, duration: transcript.duration, segments: transcript.segments, modelName: model.name, language: language ?? "auto")
        transcripts.insert(record, at: 0)
        if selectedID == nil { selectedID = record.id }
        do {
            try store.save(record)
        } catch {
            self.error = L10n.tr("The transcript is open but couldn’t be saved, so copy or export it before quitting. %@", String(error.localizedDescription))
            return
        }
        onSaved()
        if let speakerError = transcript.speakerError {
            error = L10n.tr("Couldn’t tell the speakers apart. %@", String(speakerError.localizedDescription))
        }
    }

    /// Deletes chunk files and download folders a crash or a quit mid-transcription left in the temporary folder.
    private static func removeLeftovers() {
        let folder = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("betterwispr-media-") {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

extension Meeting {
    /// The voice name speaker detection gave this segment; nil when it found none, so no transcript ever says "Them".
    func voiceLabel(_ segment: MeetingSegment) -> String? {
        segment.participant == nil ? nil : segment.label(names: participantNames)
    }

    var transcriptionText: String {
        segments.map { segment in
            "[\(segment.timestamp)] " + (voiceLabel(segment).map { "\($0): " } ?? "") + segment.text
        }.joined(separator: "\n") + "\n"
    }

    var transcriptionMarkdown: String {
        let details = "\(createdAt.formatted(date: .long, time: .shortened)) · \(durationLabel(duration)) · \(modelName)"
        let lines = segments.map { segment in
            "**\(segment.timestamp)** " + (voiceLabel(segment).map { "\($0): " } ?? "") + segment.text
        }
        return (["# \(displayTitle)", details] + lines).joined(separator: "\n\n") + "\n"
    }
}

extension AppModel {
    /// The model picked on the Transcribe page, else the dictation model.
    var transcriptionModel: SpeechModel {
        models.first { $0.id == transcriptions.modelID } ?? selectedModel
    }

    func transcribe(file: URL, onSaved: @escaping () -> Void = {}) {
        guard let (speechModel, language) = transcriptionSettings() else { return }
        transcriptions.transcribe(file: file, with: speechModel, provider: speechModel.makeProvider(), language: language, vocabulary: vocabulary, onSaved: onSaved)
    }

    func transcribe(link: String) {
        guard let (speechModel, language) = transcriptionSettings() else { return }
        transcriptions.transcribe(link: link, with: speechModel, provider: speechModel.makeProvider(), language: language, vocabulary: vocabulary)
    }

    private func transcriptionSettings() -> (SpeechModel, String?)? {
        let speechModel = transcriptionModel
        guard isModelInstalled(speechModel) else {
            selectedPage = .models
            statusMessage = L10n.tr("Download %@ in Models before transcribing.", String(speechModel.localizedName))
            return nil
        }
        return (speechModel, settings.language == "auto" ? nil : settings.language)
    }
}
