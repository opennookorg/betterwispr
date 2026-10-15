import AppKit
import BetterWisprCore
import SwiftUI
import UniformTypeIdentifiers

struct TranscribeView: View {
    @Bindable var model: AppModel
    @State private var transcriptToDelete: UUID?

    private var transcriptions: TranscriptionModel { model.transcriptions }

    var body: some View {
        VStack(spacing: 0) {
            if let error = transcriptions.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { transcriptions.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss transcription message")
                }
                .font(.callout)
                .padding(12)
                .background(.orange.opacity(0.1))
            }
            if let transcript = transcriptions.selectedID.flatMap(transcriptions.transcript) {
                TranscriptDetail(transcriptions: transcriptions, transcript: transcript) { transcriptToDelete = $0 }
                    .id(transcript.id)
            } else {
                TranscribeHome(model: model) { transcriptToDelete = $0 }
            }
        }
        .background(.pageFill)
        .alert("Delete this transcript?", isPresented: Binding(
            get: { transcriptToDelete != nil },
            set: { if !$0 { transcriptToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { transcriptToDelete = nil }
            Button("Delete", role: .destructive) {
                if let transcriptToDelete { transcriptions.delete(id: transcriptToDelete) }
                transcriptToDelete = nil
            }
        } message: {
            Text("This removes the transcript from this Mac. It cannot be undone.")
        }
    }
}

private struct TranscribeHome: View {
    @Bindable var model: AppModel
    let onDelete: (UUID) -> Void
    @State private var link = ""
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var javaScriptRuntime = YTDLP.javaScriptRuntime

    private var transcriptions: TranscriptionModel { model.transcriptions }
    private var busy: Bool { transcriptions.job != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let job = transcriptions.job { JobCard(job: job) { transcriptions.cancel() } }
                VStack(alignment: .leading, spacing: 12) {
                    dropZone
                    linkField
                    ytDLPStatus
                }
                transcriptList
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(.ui, value: transcriptions.job == nil)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Transcribe").font(.system(size: 26, weight: .semibold))
            Spacer(minLength: 8)
            Menu {
                Picker("Transcription model", selection: Binding(
                    get: { model.transcriptionModel.id },
                    set: { transcriptions.modelID = $0 }
                )) {
                    ForEach(model.models.filter(model.isModelInstalled)) { speechModel in
                        Text(speechModel.name).tag(speechModel.id)
                    }
                }
                .pickerStyle(.inline)
                Text(model.transcriptionModel.engine == .api ? "Audio sent to your selected endpoint" : "On-device transcription")
                Button("Manage models…") { model.selectedPage = .models }
            } label: {
                Label(model.transcriptionModel.name, systemImage: model.transcriptionModel.engine == .api ? "network" : "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .help("Speech model for files and links")
            .accessibilityLabel("Transcription model, \(model.transcriptionModel.name)")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Drop an audio or video file").font(.system(size: 15, weight: .medium))
            Button("Choose File…") { importing = true }
                .disabled(busy)
            Text(MediaAudioError.formats)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(dropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.cardFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .animation(.ui, value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard !busy, let file = urls.first(where: \.isFileURL) else { return false }
            model.transcribe(file: file)
            return true
        } isTargeted: { dropTargeted = $0 && !busy }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let file): model.transcribe(file: file)
            case .failure(let error): transcriptions.error = error.localizedDescription
            }
        }
    }

    private var linkField: some View {
        HStack(spacing: 8) {
            TextField("Paste a video link", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(transcribeLink)
                .accessibilityLabel("Video link")
            Button("Transcribe", action: transcribeLink)
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || transcriptions.ytDLP == nil || busy)
        }
    }

    private var ytDLPStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let ytDLP = transcriptions.ytDLP {
                HStack(spacing: 8) {
                    Text("Links use yt-dlp at \(ytDLP.path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if ytDLP == YTDLP.installed {
                        Button(transcriptions.isInstallingYTDLP ? "Updating…" : "Update") { transcriptions.installYTDLP() }
                            .buttonStyle(.link)
                            .disabled(transcriptions.isInstallingYTDLP || busy)
                    }
                }
                if javaScriptRuntime == nil {
                    Text("If YouTube links fail, install Deno with brew install deno so yt-dlp can read YouTube fully.")
                        .textSelection(.enabled)
                }
            } else {
                Text("Links need yt-dlp, a free open-source downloader. BetterWispr downloads it from GitHub and checks it against the published checksum only when you install it.")
                    .fixedSize(horizontal: false, vertical: true)
                Button(transcriptions.isInstallingYTDLP ? "Installing yt-dlp…" : "Install yt-dlp") { transcriptions.installYTDLP() }
                    .disabled(transcriptions.isInstallingYTDLP)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var transcriptList: some View {
        if transcriptions.transcripts.isEmpty {
            Text("Your transcripts appear here.")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        } else {
            ForEach(MeetingSection.group(transcriptions.transcripts), id: \.title) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .padding(.bottom, 6)
                    ForEach(section.meetings) { transcript in
                        TranscriptionRow(transcriptions: transcriptions, transcript: transcript, onDelete: onDelete)
                    }
                }
            }
        }
    }

    private func transcribeLink() {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty, transcriptions.ytDLP != nil, !busy else { return }
        model.transcribe(link: link)
        if transcriptions.job != nil { link = "" }
    }
}

private struct JobCard: View {
    let job: TranscriptionJob
    let onCancel: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: fraction)
                        .accessibilityLabel(status)
                    Text("\(status) · \(job.modelName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Cancel", action: onCancel)
            }
        }
    }

    private var fraction: Double? {
        switch job.stage {
        case .downloading(let done): done
        case .transcribing(let done): done
        case .reading, .findingSpeakers, nil: nil
        }
    }

    private var status: String {
        switch job.stage {
        case nil: "Loading the speech model…"
        case .downloading(let done): "Downloading audio…" + (done.map { " \(Int($0 * 100))%" } ?? "")
        case .reading: "Reading audio…"
        case .transcribing(let done): "Transcribing… \(Int(done * 100))%"
        case .findingSpeakers: "Telling the voices apart…"
        }
    }
}

private struct TranscriptionRow: View {
    let transcriptions: TranscriptionModel
    let transcript: Meeting
    let onDelete: (UUID) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(transcript.displayTitle).font(.system(size: 15)).lineLimit(1)
                Text("\(transcript.createdAt.formatted(date: .omitted, time: .shortened)) • \(durationLabel(transcript.duration)) • \(transcript.modelName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { transcriptions.selectedID = transcript.id }
        .contextMenu {
            Button("Open") { transcriptions.selectedID = transcript.id }
            Button("Copy transcript") { transcriptions.copy(transcript.id) }
            Divider()
            Button("Delete transcript…", role: .destructive) { onDelete(transcript.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { transcriptions.selectedID = transcript.id }
    }
}

private struct TranscriptDetail: View {
    let transcriptions: TranscriptionModel
    let transcript: Meeting
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(transcript.displayTitle)
                            .font(.system(size: 34, weight: .regular, design: .serif))
                            .textSelection(.enabled)
                        Text("\(transcript.createdAt.noteDay) · \(durationLabel(transcript.duration)) · \(transcript.modelName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help(transcript.createdAt.formatted(date: .long, time: .shortened))
                    }
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(transcript.segments) { segment in
                            SegmentRow(segment: segment, label: transcript.voiceLabel(segment), isCited: false, canChangeSpeaker: false) { EmptyView() }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 26)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Button { transcriptions.selectedID = nil } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("All transcripts")
            .accessibilityLabel("All transcripts")
            Spacer()
            Menu {
                Button("Plain Text (.txt)…") { export(transcript.transcriptionText, as: .plainText) }
                Button("Markdown (.md)…") {
                    export(transcript.transcriptionMarkdown, as: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText)
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            Button { transcriptions.copy(transcript.id) } label: { Label("Copy all", systemImage: "doc.on.doc") }
                .help("Copy the whole transcript")
            Button { onDelete(transcript.id) } label: { Image(systemName: "trash") }
                .frame(width: 30, height: 30)
                .help("Delete transcript…")
                .accessibilityLabel("Delete transcript")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func export(_ text: String, as type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = transcript.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            transcriptions.error = "Couldn’t export the transcript. \(error.localizedDescription)"
        }
    }
}
