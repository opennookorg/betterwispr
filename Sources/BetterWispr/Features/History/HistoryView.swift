import BetterWisprCore
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var transcriptToDelete: Transcript?

    private var filteredHistory: [Transcript] {
        query.isEmpty ? model.history : model.history.filter { $0.text.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if query.isEmpty, !model.failedDictations.isEmpty {
                Section {
                    let action = model.transcriptionModel.recordingAction(onDevice: ("Transcribe", "Transcribe this recording on the Transcribe page"))
                    ForEach(model.failedDictations) { item in
                        HStack(spacing: 6) {
                            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            Spacer()
                            Button(action.title) { model.transcribeFailedDictation(item) }
                                .help(action.help)
                            Button { model.revealFailedDictation(item) } label: { Image(systemName: "folder") }
                                .help("Show in Finder")
                                .accessibilityLabel("Show in Finder")
                            Button { model.deleteFailedDictation(item) } label: { Image(systemName: "trash") }
                                .help("Delete recording")
                                .accessibilityLabel("Delete recording")
                        }
                        .buttonStyle(.borderless)
                    }
                    footnote("When a dictation can’t be transcribed, BetterWispr keeps its audio on this Mac for up to 7 days, or less if Keep history is shorter. It keeps the newest 20, up to 1 GB, and leaves them out of backups.")
                } header: {
                    Text("Not transcribed")
                }
            }
            if !filteredHistory.isEmpty {
                Section {
                    ForEach(filteredHistory) { transcript in
                        TranscriptRow(
                            transcript: transcript,
                            onCopy: { model.copyTranscript(transcript) },
                            onDelete: { transcriptToDelete = transcript },
                            onEdit: { model.updateTranscript(transcript, text: $0) },
                            onRestore: { model.restoreOriginal(transcript) },
                            expanded: true
                        )
                    }
                    if model.settings.learnCorrections {
                        footnote("Fix a misheard word with the pencil and BetterWispr adds it to Vocabulary, so it is spelled right next time.")
                    }
                } header: {
                    Text("^[\(filteredHistory.count) dictation](inflect: true)")
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredHistory.isEmpty {
                if query.isEmpty, !model.failedDictations.isEmpty {
                    EmptyView()
                } else if query.isEmpty {
                    ContentUnavailableView(
                        "No Dictations",
                        systemImage: "clock",
                        description: Text("Your saved dictations will appear here. Start speaking with \(model.settings.shortcut.displayName).")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "Search dictations")
        .alert("Delete this dictation?", isPresented: Binding(
            get: { transcriptToDelete != nil },
            set: { if !$0 { transcriptToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { transcriptToDelete = nil }
            Button("Delete", role: .destructive) {
                if let transcriptToDelete { model.deleteTranscript(transcriptToDelete) }
                transcriptToDelete = nil
            }
        } message: {
            Text("This removes the saved text from this Mac. It cannot be undone.")
        }
    }

    /// List gives a section footer one line, so explanations go in a last row that can wrap.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct TranscriptRow: View {
    let transcript: Transcript
    let onCopy: () -> Void
    var onDelete: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var onRestore: (() -> Void)?
    var expanded = false
    @State private var draft: String?
    @State private var showsOriginal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(transcript.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(durationLabel(transcript.duration)).monospacedDigit()
                if expanded {
                    Text("·")
                    Text(transcript.modelName)
                    Text("·")
                    Text(transcript.language == "auto" ? "Auto language" : transcript.language.uppercased())
                }
                Spacer()
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .help("Copy dictation")
                    .accessibilityLabel("Copy dictation")
                if onEdit != nil, draft == nil {
                    Button { draft = transcript.text } label: { Image(systemName: "pencil") }
                        .help("Fix dictation")
                        .accessibilityLabel("Fix dictation")
                }
                if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .help("Delete dictation")
                        .accessibilityLabel("Delete dictation")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            if let text = Binding($draft), let onEdit {
                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.visible)
                    .frame(minHeight: 60)
                    .accessibilityLabel("Dictation text")
                HStack {
                    Spacer()
                    Button("Cancel") { draft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        onEdit(text.wrappedValue)
                        draft = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            } else {
                Text(transcript.text)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if expanded && transcript.text != transcript.rawText {
                // List draws a DisclosureGroup as an outline row with no chevron at rest.
                VStack(alignment: .leading, spacing: 6) {
                    Button { showsOriginal.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .rotationEffect(.degrees(showsOriginal ? 90 : 0))
                            Text("Original transcription")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsOriginal ? "Expanded" : "Collapsed")
                    if showsOriginal {
                        Text(transcript.rawText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let onRestore, transcript.text != transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines) {
                            Button("Use Original", action: onRestore)
                                .help("Replace the cleaned-up text with exactly what was transcribed")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
