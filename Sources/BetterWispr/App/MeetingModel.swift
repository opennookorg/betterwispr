import AppKit
import BetterWisprCore
import Observation

enum MeetingPhase: Equatable {
    case starting, recording, finishing, findingSpeakers, generating

    var isCapturing: Bool { self == .starting || self == .recording }
}

enum AskThread: Hashable {
    case meeting(UUID), allMeetings
}

/// One meeting's capture or processing, so a finished meeting keeps processing while the next one records.
@MainActor @Observable
final class MeetingRun {
    let meetingID: UUID
    var phase: MeetingPhase
    var pendingChunks = 0
    var generationStep: (Int, Int)?
    @ObservationIgnored var language: String?
    @ObservationIgnored var vocabulary: [VocabularyEntry]
    @ObservationIgnored var hints: [String]
    @ObservationIgnored var eventTitle = ""
    @ObservationIgnored var provider: (any SpeechProvider)?
    @ObservationIgnored var queue: [MeetingAudioChunk] = []
    @ObservationIgnored var drain: Task<Void, Never>?
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored var voices: SpeakerRecording?
    @ObservationIgnored var liveSpeakers: LiveSpeakerLabeller?
    @ObservationIgnored var separatesRoomVoices = false
    @ObservationIgnored var detection: Task<(segments: [MeetingSegment], voices: [Int: [Float]]), Error>?

    init(meetingID: UUID, phase: MeetingPhase, language: String? = nil, vocabulary: [VocabularyEntry] = [], replacements: [VocabularyEntry]? = nil) {
        self.meetingID = meetingID
        self.phase = phase
        self.language = language
        self.vocabulary = replacements ?? vocabulary
        hints = VocabularyProcessor.hints(vocabulary)
    }
}

@MainActor @Observable
final class MeetingModel {
    var meetings: [Meeting] = []
    /// The note open in the dashboard; nil shows the list of notes.
    var selectedID: UUID?
    var runs: [UUID: MeetingRun] = [:]
    var levels: (me: Float, them: Float) = (0, 0)
    var elapsed: TimeInterval = 0
    var message: String?
    var allMeetingsThread: [AskExchange] = []
    var voicesMessage: String?
    private(set) var hasMyVoice = false
    private(set) var isRecordingMyVoice = false
    private(set) var myVoiceMessage: String?
    var systemAudioIssue: String?
    var microphone: AudioInputDevice?
    var microphoneMuted = false {
        didSet { recorder.microphoneMuted = microphoneMuted }
    }
    var showsCallAudioHint = false
    var notesSettings = AppSettings()
    var ollamaModels: [String] = []
    var builtInModelInstalled = false
    var remembersVoices = false {
        didSet { if !remembersVoices { heardVoices = [:] } }
    }
    var notesAvailability: NotesAvailability {
        _ = builtInModelInstalled
        return MeetingNotesGenerator.availability(settings: notesSettings)
    }

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var writableAskStore: AllMeetingsAskStore?
    @ObservationIgnored private let voiceStore: VoiceStore
    private static let myVoiceSample = Duration.seconds(30)
    private var heardVoices: [UUID: HeardVoices] = [:]
    @ObservationIgnored private let recorder = MeetingRecorder()
    /// The run that receives the recorder's chunks, including the last ones a stopped meeting hands off.
    @ObservationIgnored private var recorderOwner: MeetingRun?
    @ObservationIgnored private var releasingRecorder: Task<Void, Never>?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var heard: (me: Bool, them: Bool) = (false, false)
    @ObservationIgnored private var levelsShownAt = ContinuousClock.now

    init(store: MeetingStore? = nil) {
        self.store = store ?? MeetingStore()
        voiceStore = VoiceStore(url: self.store.directory.deletingLastPathComponent().appendingPathComponent("Voices.json"))
        hasMyVoice = (try? voiceStore.myVoice()) != nil
        if store == nil { Self.removeLeftoverAudio() }
        let loaded = self.store.load()
        meetings = loaded.meetings
        if !loaded.unreadable.isEmpty {
            let count = loaded.unreadable.count
            message = L10n.tr("Unreadable meeting files in %@: %@. They were left untouched.", self.store.directory.path, String(count))
        }
        let askStore = AllMeetingsAskStore(url: self.store.directory.deletingLastPathComponent().appendingPathComponent("ask.json"))
        do {
            allMeetingsThread = try askStore.load()
            writableAskStore = askStore
        } catch {
            let unreadable = L10n.tr("%@ couldn’t be read and was left untouched, so new questions about all meetings won’t be saved.", String(askStore.url.path))
            message = [message, unreadable].compactMap { $0 }.joined(separator: " ")
        }
        recorder.onChunk = { [weak self] in self?.enqueue($0) }
        recorder.onLevels = { [weak self] in self?.receive($0) }
        recorder.onMicrophone = { [weak self] in self?.microphone = $0 }
        recorder.onError = { [weak self] in self?.message = L10n.tr("Part of the recording couldn’t be saved: %@", String($0.localizedDescription)) }
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func isActive(_ id: UUID) -> Bool { runs[id] != nil }

    var capturing: MeetingRun? { runs.values.first { $0.phase.isCapturing } }

    var capturingID: UUID? { capturing?.meetingID }

    /// The meeting being recorded, otherwise the newest one still processing.
    var activeMeetingID: UUID? { meetings.first { runs[$0.id] != nil }?.id }

    func start(model: SpeechModel, language: String?, vocabulary: [VocabularyEntry], replacements: [VocabularyEntry]? = nil, usesPhraseBooster: Bool = true,
               silenceThreshold: Float, microphone: AudioInputDevice?,
               event: CalendarEvent? = nil, separateRoomVoices: Bool = false) {
        guard capturing == nil else { return }
        var meeting = Meeting(title: event?.title ?? "", modelName: model.name, language: language ?? "auto")
        meeting.attendees = event?.attendees
        meeting.eventID = event?.id
        let run = MeetingRun(meetingID: meeting.id, phase: .starting, language: language, vocabulary: vocabulary, replacements: replacements)
        run.hints += (event?.attendees ?? []).filter { !$0.contains("@") }
        run.eventTitle = event?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        meetings.insert(meeting, at: 0)
        saveNow(meeting.id)
        runs[meeting.id] = run
        message = nil
        systemAudioIssue = nil
        showsCallAudioHint = false
        heard = (false, false)
        run.voices = SpeakerDetection.isInstalled() ? try? SpeakerRecording() : nil
        run.liveSpeakers = run.voices == nil ? nil : LiveSpeakerLabeller()
        run.separatesRoomVoices = separateRoomVoices
        elapsed = 0
        let releasing = releasingRecorder
        run.work = Task { [weak self] in
            do {
                if model.engine == .apple { try AppleSpeechProvider.checkAvailability(language: language) }
                try model.connection?.validateLanguage(language)
                let provider = model.makeProvider()
                (provider as? ParakeetProvider)?.usesPhraseBooster = usesPhraseBooster
                await releasing?.value
                guard let self, self.owns(run) else { return }
                self.recorderOwner = run
                self.microphoneMuted = false
                try await self.recorder.start(silenceThreshold: silenceThreshold, microphone: microphone)
                guard self.owns(run) else { return }
                self.systemAudioIssue = self.recorder.systemAudioIssue
                self.startedAt = Date()
                run.phase = .recording
                self.startTicker(run)
                try await provider.prepare(model: model, download: false)
                try Task.checkCancellation()
                guard self.owns(run) else { return }
                run.provider = provider
                self.drainQueue(run)
            } catch {
                guard let self, self.owns(run) else { return }
                self.discard(run)
                if !(error is CancellationError) { self.message = L10n.tr("Couldn’t start the meeting. %@", String(error.localizedDescription)) }
            }
        }
    }

    /// Hands the recorder's last chunks to this meeting and processes it in the background, so the next meeting can start right away.
    func stop() {
        guard let run = capturing else { return }
        guard run.phase == .recording else { return discard(run) }
        let id = run.meetingID
        let loading = run.work
        ticker?.cancel()
        let duration = Date().timeIntervalSince(startedAt)
        elapsed = duration
        edit(id, save: false) { $0.duration = duration }
        saveNow(id)
        run.phase = .finishing
        let releasing = Task { [weak self] in
            await self?.recorder.stop()
            if self?.recorderOwner === run { self?.recorderOwner = nil }
        }
        releasingRecorder = releasing
        run.work = Task { [weak self] in
            await releasing.value
            await loading?.value
            await run.drain?.value
            guard let self, self.owns(run) else { return }
            self.saveNow(id)
            if let voices = run.voices {
                run.voices = nil
                run.liveSpeakers = nil
                await self.findSpeakers(for: run, from: voices)
                guard self.owns(run) else { return }
            }
            run.provider = nil
            if self.notesAvailability == .available, self.meeting(id)?.hasContent == true {
                await self.writeNotes(for: run)
            }
            guard self.owns(run) else { return }
            self.runs[id] = nil
            if self.selectedID == nil, self.capturing == nil { self.selectedID = id }
        }
    }

    func useMicrophone(_ choice: AudioInputDevice?) { recorder.use(choice) }

    func refreshOllamaModels() async {
        ollamaModels = (try? await Ollama.installedModels()) ?? []
    }

    func skipSpeakers(_ id: UUID) { runs[id]?.detection?.cancel() }

    func generateNotes(_ id: UUID) {
        guard runs[id] == nil else { return }
        let run = MeetingRun(meetingID: id, phase: .generating)
        runs[id] = run
        message = nil
        run.work = Task { [weak self] in
            await self?.writeNotes(for: run)
            if let self, self.owns(run) { self.runs[id] = nil }
        }
    }

    func cancelNotes(_ id: UUID) {
        guard let run = runs[id], run.phase == .generating else { return }
        runs[id] = nil
        run.work?.cancel()
        run.generationStep = nil
        saveNow(id)
        if selectedID == nil { selectedID = id }
    }

    func edit(_ id: UUID, save: Bool = true, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        if save { scheduleSave(id) }
    }

    func toggleActionItem(_ itemID: UUID, in id: UUID) {
        edit(id) { meeting in
            guard let index = meeting.summary?.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meeting.summary?.actionItems[index].isDone.toggle()
        }
    }

    func thread(_ thread: AskThread) -> [AskExchange] {
        switch thread {
        case .meeting(let id): meeting(id)?.askThread ?? []
        case .allMeetings: allMeetingsThread
        }
    }

    func append(_ exchange: AskExchange, to thread: AskThread) {
        switch thread {
        case .meeting(let id): edit(id) { $0.askThread = ($0.askThread ?? []) + [exchange] }
        case .allMeetings:
            guard exchange.answer.citations.allSatisfy({ meeting($0.line.meetingID) != nil }) else { return }
            allMeetingsThread.append(exchange)
            saveAllMeetingsThread()
        }
    }

    func clear(_ thread: AskThread) {
        switch thread {
        case .meeting(let id): edit(id) { $0.askThread = nil }
        case .allMeetings:
            allMeetingsThread = []
            saveAllMeetingsThread()
        }
    }

    func delete(_ id: UUID) {
        guard !isActive(id) else {
            message = L10n.tr("Stop this meeting before deleting it.")
            return
        }
        saves.removeValue(forKey: id)?.cancel()
        do {
            try store.delete(id: id)
        } catch {
            message = L10n.tr("Couldn’t delete the meeting. %@", String(error.localizedDescription))
            return
        }
        heardVoices[id] = nil
        do {
            try voiceStore.replaceVoices(from: id, with: [])
            for meetingID in Array(heardVoices.keys) { heardVoices[meetingID]?.forgetSuggestions(from: id) }
        } catch { voicesMessage = voicesError(error) }
        meetings.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        let kept = allMeetingsThread.filter { !$0.answer.citations.contains { $0.line.meetingID == id } }
        if kept.count != allMeetingsThread.count {
            allMeetingsThread = kept
            saveAllMeetingsThread()
        }
    }

    func copy(_ id: UUID, transcriptOnly: Bool = false) {
        guard let meeting = meeting(id) else { return }
        let text = transcriptOnly ? meeting.transcript : meeting.markdown
        Task {
            do { ToastWindow.shared.show(Toast(try await ClipboardIntegration().deliver(text, to: nil))) }
            catch { ToastWindow.shared.show(Toast(failure: L10n.tr("Couldn’t copy"), error)) }
        }
    }

    func endForQuit() {
        let id = capturingID
        if capturing?.phase == .recording { elapsed = Date().timeIntervalSince(startedAt) }
        recorder.cancel()
        recorderOwner = nil
        ticker?.cancel()
        let ended = Array(runs.values)
        runs = [:]
        for run in ended {
            run.work?.cancel()
            run.drain?.cancel()
            run.detection?.cancel()
            run.voices?.discard()
            run.provider?.cancel()
        }
        Self.removeLeftoverAudio()
        if let id, meeting(id)?.duration == 0 { edit(id, save: false) { $0.duration = elapsed } }
        for pending in Array(saves.keys) { saveNow(pending) }
        for run in ended { saveNow(run.meetingID) }
    }

    private func owns(_ run: MeetingRun) -> Bool { runs[run.meetingID] === run }

    /// Ends a meeting that never finished starting, stopping the recorder only if this meeting still holds it.
    private func discard(_ run: MeetingRun) {
        guard owns(run) else { return }
        runs[run.meetingID] = nil
        run.work?.cancel()
        if recorderOwner === run {
            recorder.cancel()
            recorderOwner = nil
            ticker?.cancel()
        }
        for chunk in run.queue { try? FileManager.default.removeItem(at: chunk.url) }
        run.queue = []
        run.pendingChunks = 0
        run.detection?.cancel()
        run.voices?.discard()
        run.voices = nil
        run.provider = nil
        discardIfEmpty(run)
    }

    private func findSpeakers(for run: MeetingRun, from voices: SpeakerRecording) async {
        defer { voices.discard() }
        let id = run.meetingID
        run.phase = .findingSpeakers
        let segments = meeting(id)?.segments ?? []
        let provider = run.provider
        let myVoice = try? voiceStore.myVoice()
        let detection = Task {
            try await SpeakerDetection.label(segments, voices: voices, myVoice: myVoice) { audio, start, duration in
                guard let provider else { return nil }
                return try await self.segment(of: audio, speaker: .them, start: start, duration: duration, with: provider, for: run)
            }
        }
        run.detection = detection
        do {
            let labelled = try await detection.value
            guard owns(run) else { return }
            applySpeakers(labelled, to: id)
        } catch {
            guard owns(run) else { return }
            if !(error is CancellationError), !detection.isCancelled {
                message = L10n.tr("Couldn’t tell the speakers on the call apart. %@", String(error.localizedDescription))
            }
        }
        run.detection = nil
    }

    func applySpeakers(_ labelled: (segments: [MeetingSegment], voices: [Int: [Float]]), to id: UUID) {
        if remembersVoices {
            do { heardVoices[id] = HeardVoices(labelled.voices, among: try voiceStore.load()) } catch { voicesMessage = voicesError(error) }
        }
        edit(id, save: false) { $0.segments = labelled.segments }
        saveNow(id)
    }

    private func writeNotes(for run: MeetingRun) async {
        let id = run.meetingID
        guard owns(run), !Task.isCancelled, let meeting = meeting(id) else { return }
        run.phase = .generating
        run.generationStep = nil
        let sourceFingerprint = meeting.summarySourceFingerprint
        let modelName = notesSettings.notesModelName
        do {
            let notes = try await MeetingNotesGenerator.generate(segments: meeting.segments, names: meeting.participantNames, userNotes: meeting.notes, invite: meeting.calendarInvite, language: meeting.language, settings: notesSettings) { [weak self] step, total in
                guard let self, self.owns(run) else { return }
                run.generationStep = (step, total)
            }
            try Task.checkCancellation()
            guard owns(run) else { return }
            edit(id, save: false) { meeting in
                meeting.summary = notes.summary
                if meeting.summary?.modelName == nil { meeting.summary?.modelName = modelName }
                meeting.summary?.sourceFingerprint = sourceFingerprint
                if meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { meeting.title = notes.title }
            }
            saveNow(id)
        } catch {
            guard owns(run) else { return }
            if !(error is CancellationError) { message = L10n.tr("Couldn’t write notes. %@", String(error.localizedDescription)) }
        }
        run.generationStep = nil
    }

    /// Queues speech while the model may still be loading, so the first words of a meeting are kept.
    private func enqueue(_ chunk: MeetingAudioChunk) {
        guard chunk.hasSpeech, let run = recorderOwner, owns(run) else {
            try? FileManager.default.removeItem(at: chunk.url)
            return
        }
        run.queue.append(chunk)
        run.pendingChunks += 1
        drainQueue(run)
    }

    private func drainQueue(_ run: MeetingRun) {
        guard run.drain == nil, run.provider != nil, !run.queue.isEmpty, owns(run) else { return }
        run.drain = Task { [weak self] in await self?.transcribeQueue(run) }
    }

    private func transcribeQueue(_ run: MeetingRun) async {
        let id = run.meetingID
        while owns(run), let provider = run.provider, !run.queue.isEmpty {
            let chunk = run.queue.removeFirst()
            defer {
                try? FileManager.default.removeItem(at: chunk.url)
                run.pendingChunks = max(0, run.pendingChunks - 1)
            }
            do {
                let segment = try await segment(of: chunk.url, speaker: chunk.speaker, start: chunk.start, duration: chunk.duration, with: provider, for: run)
                guard owns(run) else { return }
                guard let segment else { continue }
                edit(id, save: false) { $0.insert(segment) }
                saveNow(id)
                if chunk.speaker == .them || run.separatesRoomVoices, let voices = run.voices { try? await voices.append(chunk.url, for: segment.id) }
                if chunk.speaker == .them, let live = run.liveSpeakers {
                    await live.add(chunk.url, for: segment.id)
                    Task { [weak self] in
                        guard let numbers = await live.speakers(), let self, self.owns(run), run.liveSpeakers != nil else { return }
                        self.edit(id) { $0.number(numbers) }
                    }
                }
            } catch {
                guard owns(run) else { return }
                if !(error is CancellationError) {
                    message = L10n.tr("A few seconds from %@ couldn’t be transcribed. %@", String(chunk.speaker.localizedLabel), String(error.localizedDescription))
                }
            }
        }
        run.drain = nil
    }

    private func segment(of audio: URL, speaker: Speaker, start: TimeInterval, duration: TimeInterval, with provider: any SpeechProvider, for run: MeetingRun) async throws -> MeetingSegment? {
        let raw = try await provider.transcribe(audioURL: audio, language: run.language, vocabulary: run.hints)
        let text = VocabularyProcessor.apply(run.vocabulary, to: TranscriptCleaner.clean(raw, language: run.language))
        return text.isEmpty ? nil : MeetingSegment(speaker: speaker, start: start, duration: duration, text: text, rawText: raw)
    }

    private func receive(_ levels: (me: Float, them: Float)) {
        if levelsShownAt.duration(to: .now) >= .milliseconds(33) {
            self.levels = levels
            levelsShownAt = .now
        }
        if levels.me > 0.05 { heard.me = true }
        if levels.them > 0.01 {
            heard.them = true
            showsCallAudioHint = false
        }
    }

    private func startTicker(_ run: MeetingRun) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.owns(run), run.phase == .recording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.showsCallAudioHint = self.elapsed >= 20 && self.heard.me && !self.heard.them && self.systemAudioIssue == nil
            }
        }
    }

    private func scheduleSave(_ id: UUID) {
        saves[id]?.cancel()
        saves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow(id)
        }
    }

    func saveNow(_ id: UUID) {
        saves.removeValue(forKey: id)?.cancel()
        guard let meeting = meeting(id) else { return }
        do { try store.save(meeting) } catch { message = L10n.tr("This meeting couldn’t be saved. %@", String(error.localizedDescription)) }
        rememberNamedVoices(in: meeting)
    }

    func forgetVoices() throws {
        heardVoices = [:]
        try voiceStore.forget()
        hasMyVoice = false
    }

    /// Records the sample the user asked for, keeps only a profile of the voice in it and deletes the audio.
    func recordMyVoice() async {
        guard !isRecordingMyVoice else { return }
        isRecordingMyVoice = true
        defer { isRecordingMyVoice = false }
        let recorder = AudioRecorder()
        do {
            try await recorder.start()
            try await Task.sleep(for: Self.myVoiceSample)
            let sample = try await recorder.finish()
            defer { try? FileManager.default.removeItem(at: sample.url) }
            guard let voice = try await SpeakerDetection.voice(inRecording: sample.url) else {
                myVoiceMessage = L10n.tr("Not enough of your voice was heard. Try again and keep talking for the whole 30 seconds.")
                return
            }
            try voiceStore.setMyVoice(voice)
            hasMyVoice = true
            myVoiceMessage = nil
        } catch {
            recorder.cancel()
            myVoiceMessage = L10n.tr("Your voice couldn’t be saved. %@", String(error.localizedDescription))
        }
    }

    func forgetMyVoice() {
        do {
            try voiceStore.setMyVoice(nil)
            hasMyVoice = false
            myVoiceMessage = nil
        } catch { myVoiceMessage = voicesError(error) }
    }

    func suggestedName(for number: Int, in meeting: Meeting) -> String? {
        heardVoices[meeting.id]?.suggestion(for: number, in: meeting)
    }

    func merge(_ source: Int, into target: Int, in id: UUID) {
        heardVoices[id]?.drop(source)
        edit(id) { $0.mergeParticipant(source, into: target) }
    }

    /// Forgets the remembered voice behind a speaker's suggestion once the user commits another name, including from the meeting it was remembered in.
    func commitName(of number: Int, in id: UUID) {
        guard let meeting = meeting(id) else { return }
        do {
            guard let rejected = try heardVoices[id]?.reject(number, in: meeting, from: voiceStore) else { return }
            heardVoices[rejected.meetingID]?.drop(rejected.participant)
            for meetingID in Array(heardVoices.keys) {
                heardVoices[meetingID]?.forgetSuggestions(from: rejected.meetingID, participant: rejected.participant)
            }
        } catch { voicesMessage = voicesError(error) }
    }

    private func rememberNamedVoices(in meeting: Meeting) {
        guard remembersVoices else { return }
        do { try heardVoices[meeting.id]?.remember(in: meeting, to: voiceStore) } catch { voicesMessage = voicesError(error) }
    }

    private func voicesError(_ error: any Error) -> String {
        L10n.tr("Remembered voices in %@ couldn’t be used and were left as they were. %@", String(voiceStore.url.path), String(error.localizedDescription))
    }

    private func saveAllMeetingsThread() {
        guard let writableAskStore else { return }
        do { try writableAskStore.save(allMeetingsThread) } catch { message = L10n.tr("Questions about all meetings couldn’t be saved. %@", String(error.localizedDescription)) }
    }

    private func discardIfEmpty(_ run: MeetingRun) {
        guard let meeting = meeting(run.meetingID), !meeting.hasContent,
              ["", run.eventTitle].contains(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        delete(run.meetingID)
    }

    /// Deletes meeting chunk files a crash or a quit mid-transcription left in the temporary folder.
    private static func removeLeftoverAudio() {
        let folder = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("betterwispr-meeting-") && file.pathExtension == "caf" {
            try? FileManager.default.removeItem(at: file)
        }
    }

}
