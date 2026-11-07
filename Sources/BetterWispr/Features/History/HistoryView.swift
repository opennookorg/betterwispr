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
        Form {
            if query.isEmpty, !model.failedDictations.isEmpty {
                Section {
                    let action = model.transcriptionModel.recordingAction(onDevice: (L10n.tr("Transcribe"), L10n.tr("Transcribe this recording on the Transcribe page")))
                    ForEach(model.failedDictations) { item in
                        HStack(spacing: 6) {
                            Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            Spacer()
                            Button(action.title) { model.transcribeFailedDictation(item) }
                                .help(action.help)
                            Button { model.revealFailedDictation(item) } label: { Image(systemName: "folder") }
                                .help(L10n.tr("Show in Finder"))
                                .accessibilityLabel(L10n.tr("Show in Finder"))
                            Button { model.deleteFailedDictation(item) } label: { Image(systemName: "trash") }
                                .help(L10n.tr("Delete recording"))
                                .accessibilityLabel(L10n.tr("Delete recording"))
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text(L10n.tr("Not transcribed"))
                } footer: {
                    Text(L10n.tr("When a dictation can’t be transcribed, BetterWispr keeps its audio on this Mac for up to 7 days, or less if Keep history is shorter. It keeps the newest 20, up to 1 GB, and leaves them out of backups."))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                } header: {
                    Text(L10n.tr("%ld dictations", filteredHistory.count))
                } footer: {
                    if model.settings.learnCorrections {
                        Text(L10n.tr("Fix a misheard word with the pencil and BetterWispr adds it to Vocabulary, so it is spelled right next time."))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if filteredHistory.isEmpty {
                if query.isEmpty, !model.failedDictations.isEmpty {
                    EmptyView()
                } else if query.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("No Dictations"),
                        systemImage: "clock",
                        description: Text(L10n.tr("Your saved dictations will appear here. Start speaking with %@.", String(model.settings.shortcut.displayName)))
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: L10n.tr("Search dictations"))
        .alert(L10n.tr("Delete this dictation?"), isPresented: Binding(
            get: { transcriptToDelete != nil },
            set: { if !$0 { transcriptToDelete = nil } }
        )) {
            Button(L10n.tr("Cancel"), role: .cancel) { transcriptToDelete = nil }
            Button(L10n.tr("Delete"), role: .destructive) {
                if let transcriptToDelete { model.deleteTranscript(transcriptToDelete) }
                transcriptToDelete = nil
            }
        } message: {
            Text(L10n.tr("This removes the saved text from this Mac. It cannot be undone."))
        }
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
                    Text(transcript.language == "auto" ? L10n.tr("Auto language") : transcript.language.uppercased())
                }
                Spacer()
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .help(L10n.tr("Copy dictation"))
                    .accessibilityLabel(L10n.tr("Copy dictation"))
                if onEdit != nil, draft == nil {
                    Button { draft = transcript.text } label: { Image(systemName: "pencil") }
                        .help(L10n.tr("Fix dictation"))
                        .accessibilityLabel(L10n.tr("Fix dictation"))
                }
                if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .help(L10n.tr("Delete dictation"))
                        .accessibilityLabel(L10n.tr("Delete dictation"))
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
                    .accessibilityLabel(L10n.tr("Dictation text"))
                HStack {
                    Spacer()
                    Button(L10n.tr("Cancel")) { draft = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.tr("Save")) {
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
                DisclosureGroup(L10n.tr("Original transcription")) {
                    Text(transcript.rawText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onRestore, transcript.text != transcript.rawText.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Button(L10n.tr("Use Original"), action: onRestore)
                            .help(L10n.tr("Replace the cleaned-up text with exactly what was transcribed"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
