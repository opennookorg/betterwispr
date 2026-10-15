import BetterWisprCore
import SwiftUI

struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var meetingToDelete: UUID?
    @State private var asking: AskQuestion?
    @State private var citation: MeetingLine?

    private var meetings: MeetingModel { model.meetings }

    var body: some View {
        VStack(spacing: 0) {
            banner(\.message, dismissal: "Dismiss meeting message")
            banner(\.voicesMessage, dismissal: "Dismiss remembered voices message")
            if let meeting = meetings.selectedID.flatMap(meetings.meeting) {
                noteBar(meeting)
                MeetingDetailView(model: model, id: meeting.id, citation: $citation).id(meeting.id)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        NotesHome(model: model, onDelete: { meetingToDelete = $0 }, asking: $asking, onCite: cite).frame(minWidth: 460)
                        Divider()
                        CurrentNote(model: model).frame(width: 300)
                    }
                    NotesHome(model: model, onDelete: { meetingToDelete = $0 }, asking: $asking, onCite: cite)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .answering($asking, in: .allMeetings, model: model)
        .alert("Delete this meeting?", isPresented: Binding(
            get: { meetingToDelete != nil },
            set: { if !$0 { meetingToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { meetingToDelete = nil }
            Button("Delete", role: .destructive) {
                if let meetingToDelete { meetings.delete(meetingToDelete) }
                meetingToDelete = nil
            }
        } message: {
            Text("This removes the meeting, its notes and transcript from this Mac\(meetings.remembersVoices ? " and forgets the voices named in it" : ""). It cannot be undone.")
        }
    }

    @ViewBuilder private func banner(_ field: ReferenceWritableKeyPath<MeetingModel, String?>, dismissal: String) -> some View {
        if let message = meetings[keyPath: field] {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { meetings[keyPath: field] = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(dismissal)
            }
            .font(.callout)
            .padding(12)
            .background(.orange.opacity(0.1))
        }
    }

    private func cite(_ line: MeetingLine) {
        citation = line
        meetings.selectedID = line.meetingID
    }

    private func noteBar(_ meeting: Meeting) -> some View {
        let index = meetings.meetings.firstIndex { $0.id == meeting.id }
        return HStack(spacing: 4) {
            Button { meetings.selectedID = nil } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("All notes")
            .accessibilityLabel("All notes")
            Spacer()
            Menu {
                Button { meetings.generateNotes(meeting.id) } label: {
                    Label(meeting.summary == nil ? "Generate summary" : "Regenerate summary", systemImage: "sparkles")
                }
                .disabled(!meeting.hasContent || meetings.isActive(meeting.id) || meetings.notesAvailability != .available)
                Button { meetings.copy(meeting.id, transcriptOnly: true) } label: {
                    Label("Copy transcript", systemImage: "text.quote")
                }
                .disabled(meeting.segments.isEmpty)
                Divider()
                Button(role: .destructive) { meetingToDelete = meeting.id } label: {
                    Label("Delete meeting…", systemImage: "trash")
                }
                .disabled(meetings.isActive(meeting.id))
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .help("More meeting actions")
            .accessibilityLabel("More meeting actions")
            Button { meetings.copy(meeting.id) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy notes and transcript")
            Group {
                Button { meetings.selectedID = index.map { meetings.meetings[$0 - 1].id } } label: { Image(systemName: "chevron.left") }
                    .disabled(index.map { $0 == 0 } ?? true)
                    .help("Newer note")
                    .accessibilityLabel("Newer note")
                Button { meetings.selectedID = index.map { meetings.meetings[$0 + 1].id } } label: { Image(systemName: "chevron.right") }
                    .disabled(index.map { $0 + 1 == meetings.meetings.count } ?? true)
                    .help("Older note")
                    .accessibilityLabel("Older note")
                Button { model.onShowNotetaker?(meeting.id) } label: { Image(systemName: "rectangle.righthalf.inset.filled") }
                    .help("Open beside your call")
                    .accessibilityLabel("Open beside your call")
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }
}

private struct NotesHome: View {
    @Bindable var model: AppModel
    let onDelete: (UUID) -> Void
    @Binding var asking: AskQuestion?
    let onCite: (MeetingLine) -> Void
    @State private var query = ""
    @State private var searching = false

    private var meetings: MeetingModel { model.meetings }
    private var filtered: [Meeting] {
        query.isEmpty ? meetings.meetings : meetings.meetings.filter { $0.matches(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if searching {
                    TextField("Search notes", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search meeting notes")
                }
                if !meetings.meetings.isEmpty {
                    AskPanel(model: model, thread: .allMeetings, placeholder: "Ask about all your meetings", asking: $asking, onCite: onCite)
                }
                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "Be in the conversation." : "No matching notes")
                            .font(.system(size: 26, design: .serif))
                        Text(query.isEmpty ? "Keep your thoughts, follow the transcript, and leave with a summary." : "Try another title or phrase.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)
                } else {
                    ForEach(MeetingSection.group(filtered), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .tracking(1)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 10)
                                .padding(.bottom, 6)
                            ForEach(section.meetings) { meeting in
                                NoteRow(meetings: meetings, meeting: meeting, onDelete: onDelete)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        let capturing = meetings.capturingID != nil
        return HStack(spacing: 14) {
            Text("Notetaker").font(.system(size: 26, weight: .semibold))
            Spacer(minLength: 8)
            Button { searching.toggle(); query = "" } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Search notes")
                .accessibilityLabel("Search notes")
            NotetakerSettings(model: model)
            Button {
                if capturing { meetings.stop() } else { model.startNotetaker() }
            } label: {
                Label(capturing ? "Stop Notetaker" : "Start Notetaker", systemImage: capturing ? "stop.circle" : "record.circle")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!capturing && model.isBusy)
        }
    }
}

private struct NotetakerSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Transcription model", selection: Binding(
                get: { model.selectedModel.id },
                set: { id in
                    if let speechModel = model.models.first(where: { $0.id == id }) { model.selectModel(speechModel) }
                }
            )) {
                ForEach(model.models) { speechModel in
                    Text(speechModel.name + (model.isModelInstalled(speechModel) ? "" : " · Download in Models"))
                        .tag(speechModel.id)
                        .disabled(!model.isModelInstalled(speechModel))
                }
            }
            .pickerStyle(.inline)
            .disabled(model.isBusy || !model.meetings.runs.isEmpty)
            Text(model.selectedModel.engine == .api ? "Audio sent to your selected endpoint" : "On-device transcription")
            Button("Manage models…") { model.selectedPage = .models }
            Divider()
            MicrophonePicker(model: model) { Text("Microphone") }
                .pickerStyle(.inline)
            Divider()
            NotesModelPicker(model: model)
                .pickerStyle(.inline)
                .disabled(!model.meetings.runs.isEmpty)
            NotesModelPicker(model: model, forAsk: true)
                .pickerStyle(.inline)
            Button("Configure and test notes models…") { model.selectedPage = .models }

        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .task { await model.meetings.refreshOllamaModels() }
        .help("Transcription model, microphone and notes model")
        .accessibilityLabel("Notetaker settings")
    }


}

private struct NoteRow: View {
    let meetings: MeetingModel
    let meeting: Meeting
    let onDelete: (UUID) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.displayTitle).font(.system(size: 15)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                    if let status {
                        Text("•")
                        Text(status).foregroundStyle(meetings.capturingID == meeting.id ? .green : .secondary)
                    } else if canSummarize {
                        Text("•")
                        Button("Generate summary") { meetings.generateNotes(meeting.id) }
                            .buttonStyle(.plain)
                            .underline()
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { meetings.selectedID = meeting.id }
        .contextMenu {
            Button("Open") { meetings.selectedID = meeting.id }
            Button("Copy notes and transcript") { meetings.copy(meeting.id) }
            Divider()
            Button("Delete meeting…", role: .destructive) { onDelete(meeting.id) }
                .disabled(meetings.isActive(meeting.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { meetings.selectedID = meeting.id }
    }

    private var status: String? {
        switch meetings.runs[meeting.id]?.phase {
        case .recording: "Recording"
        case .starting: "Starting"
        case .finishing: "Transcribing"
        case .findingSpeakers: "Finding speakers"
        case .generating: "Writing summary"
        case nil: nil
        }
    }

    private var canSummarize: Bool {
        meeting.summary == nil && meeting.hasContent && !meetings.isActive(meeting.id) && meetings.notesAvailability == .available
    }
}

/// The meeting in progress, or the latest one, shown beside the list of notes.
private struct CurrentNote: View {
    let model: AppModel

    private var meetings: MeetingModel { model.meetings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meeting = (meetings.activeMeetingID ?? meetings.meetings.first?.id).flatMap(meetings.meeting) {
                Button { meetings.selectedID = meeting.id } label: {
                    Text(meeting.displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Open note")
                Text("\(meeting.createdAt.noteDay) • \(meeting.createdAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
                if meetings.capturingID == meeting.id {
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text("Recording · \(durationLabel(meetings.elapsed))").monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.top, 6)
                    Button("Open beside your call") { model.onShowNotetaker?(meeting.id) }
                        .buttonStyle(.link)
                } else if !meeting.snippet.isEmpty {
                    Text(meeting.snippet)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .lineLimit(8)
                        .padding(.top, 6)
                }
            } else {
                Text("Your current note appears here.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Date {
    /// "Today" for today's notes, otherwise a short day such as "Oct 6".
    var noteDay: String {
        Calendar.current.isDateInToday(self) ? "Today"
            : formatted(Calendar.current.isDate(self, equalTo: .now, toGranularity: .year) ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

private extension Meeting {
    func matches(_ query: String) -> Bool {
        let summaryText = summary.map { [$0.overview] + $0.keyPoints + $0.decisions + $0.actionItems.map(\.text) } ?? []
        return ([title, notes] + summaryText + segments.map(\.text)).contains { $0.localizedStandardContains(query) }
    }
}

extension AppModel {
    func startMeeting() async {
        let event = settings.useCalendar ? await calendarEvents.current(excluding: settings.excludedCalendarIDs) : nil
        guard !isBusy, meetings.capturingID == nil else { return }
        let speechModel = selectedModel
        guard isModelInstalled(speechModel) else {
            selectedPage = .models
            statusMessage = "Download \(speechModel.name) in Models before starting meeting notes."
            return
        }
        selectedPage = .meetings
        meetings.start(model: speechModel, language: settings.language == "auto" ? nil : settings.language,
                       vocabulary: vocabulary, silenceThreshold: settings.silenceThreshold, microphone: settings.microphone, event: event,
                       separateRoomVoices: settings.separateRoomVoices)
    }

    /// Starts a meeting and docks its card beside the call.
    func startNotetaker() {
        Task {
            await startMeeting()
            if let id = meetings.capturingID { onShowNotetaker?(id) } else { onShowDashboard?() }
        }
    }
}
