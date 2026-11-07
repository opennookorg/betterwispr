import BetterWisprCore
import SwiftUI

struct AskQuestion: Identifiable {
    let id = UUID()
    let text: String
    let about: [Meeting]
    var failure: String?
    var displayText: String?
}

struct AskPanel: View {
    let model: AppModel
    let thread: AskThread
    let placeholder: String
    @Binding var asking: AskQuestion?
    let onCite: (MeetingLine) -> Void
    @State private var draft = ""
    @State private var confirmsClear = false
    @State private var filter = MeetingFilter()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(ask)
                        .disabled(unavailable != nil)
                        .accessibilityLabel(placeholder)
                    Button(L10n.tr("Ask"), action: ask)
                        .disabled(!canAsk)
                    if !exchanges.isEmpty || asking != nil, !isWaiting {
                        Button(L10n.tr("Clear")) {
                            asking = nil
                            if !exchanges.isEmpty { confirmsClear = true }
                        }
                        .help(L10n.tr("Clear these questions and answers"))
                    }
                }
                if let unavailable {
                    Text(unavailable).font(.callout).foregroundStyle(.secondary)
                }
                if thread == .allMeetings {
                    filters
                }
                if let recording {
                    Button(L10n.tr("What did I miss?"), systemImage: "clock.arrow.circlepath") { catchUp(on: recording) }
                        .disabled(unavailable != nil || isWaiting)
                        .help(L10n.tr("Answer from the last %ld minutes of the transcript", Self.catchUpMinutes))
                }
            }
            if let asking {
                pending(asking)
            }
            ForEach(exchanges.reversed(), content: row)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(L10n.tr("Clear these questions and answers?"), isPresented: $confirmsClear) {
            Button(L10n.tr("Clear"), role: .destructive) { model.meetings.clear(thread) }
        } message: {
            Text(L10n.tr("They’re removed from this Mac. This can’t be undone."))
        }
    }

    private var filters: some View {
        let attendees = MeetingFilter.attendees(in: model.meetings.meetings)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Picker(L10n.tr("When"), selection: $filter.days) {
                    Text(L10n.tr("Any time")).tag(Int?.none)
                    Text(L10n.tr("Today")).tag(Int?.some(1))
                    Text(L10n.tr("Past 7 days")).tag(Int?.some(7))
                    Text(L10n.tr("Past 30 days")).tag(Int?.some(30))
                }
                if !attendees.isEmpty {
                    Picker(L10n.tr("With"), selection: $filter.attendee) {
                        Text(L10n.tr("Anyone")).tag(String?.none)
                        ForEach(attendees, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if noMatch {
                Text(L10n.tr("No meetings match these filters.")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var exchanges: [AskExchange] { model.meetings.thread(thread) }

    private var showsMeetingTitles: Bool { thread == .allMeetings }

    private var meetings: [Meeting] {
        switch thread {
        case .meeting(let id): model.meetings.meeting(id).map { [$0] } ?? []
        case .allMeetings: filter.apply(to: model.meetings.meetings)
        }
    }

    private var noMatch: Bool { thread == .allMeetings && !model.meetings.meetings.isEmpty && meetings.isEmpty }

    private var recording: Meeting? {
        guard case .meeting(let id) = thread, model.meetings.runs[id]?.phase == .recording else { return nil }
        return model.meetings.meeting(id)
    }

    private static let catchUpMinutes = Int(MeetingQuestion.catchUpWindow / 60)

    private var settings: AppSettings { model.meetings.notesSettings.askSettings }

    private var unavailable: String? {
        if case .unavailable(let reason) = MeetingNotesGenerator.availability(settings: settings) { reason } else { nil }
    }

    private var isWaiting: Bool { asking != nil && asking?.failure == nil }

    private var question: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAsk: Bool { unavailable == nil && !isWaiting && !noMatch && !question.isEmpty }

    private func ask() {
        guard canAsk else { return }
        asking = AskQuestion(text: question, about: meetings)
        draft = ""
    }

    private func catchUp(on meeting: Meeting) {
        let recent = MeetingQuestion.catchUp(meeting, at: model.meetings.elapsed)
        asking = AskQuestion(text: MeetingQuestion.catchUpQuestion, about: [recent],
                             failure: recent.hasContent ? nil : L10n.tr("Nothing was transcribed in the last %ld minutes.", Self.catchUpMinutes),
                             displayText: MeetingQuestion.localizedCatchUpQuestion)
    }

    private func pending(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionText(question.displayText ?? question.text)
            if let failure = question.failure {
                Text(failure).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Asking %@…", String(settings.localizedNotesModelName))).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(L10n.tr("Cancel")) { asking = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ exchange: AskExchange) -> some View {
        let answer = exchange.answer
        return VStack(alignment: .leading, spacing: 10) {
            questionText(exchange.question)
            Text((try? AttributedString(markdown: answer.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(answer.text))
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
            if !answer.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(answer.citations, id: \.self, content: citation)
                }
            }
            Text(L10n.tr("Answered with %@", String(answer.modelName)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .textSelection(.enabled)
    }

    private func citation(_ citation: MeetingAnswer.Citation) -> some View {
        let line = citation.line
        let meeting = model.meetings.meeting(line.meetingID)
        let title = showsMeetingTitles ? meeting?.localizedDisplayTitle : nil
        let label = line.localizedLabel(in: meeting)
        return Button { onCite(line) } label: {
            HStack(spacing: 6) {
                Text("[\(citation.number)] \(label)").fontWeight(.medium).monospacedDigit().layoutPriority(1)
                if let title { Text(title) }
                Text(line.text).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .font(.callout)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(line.text)
        .accessibilityLabel([L10n.tr("Line %@", String(citation.number)), label, title].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(line.text)
    }
}

extension View {
    func answering(_ question: Binding<AskQuestion?>, in thread: AskThread, model: AppModel) -> some View {
        task(id: question.wrappedValue?.id) {
            guard let asked = question.wrappedValue, asked.failure == nil else { return }
            do {
                let answer = try await MeetingQuestion.ask(asked.text, about: asked.about, settings: model.meetings.notesSettings.askSettings)
                guard question.wrappedValue?.id == asked.id else { return }
                model.meetings.append(AskExchange(question: asked.text, answer: answer), to: thread)
                question.wrappedValue = nil
            } catch {
                guard !Task.isCancelled, question.wrappedValue?.id == asked.id else { return }
                question.wrappedValue?.failure = error.localizedDescription
            }
        }
    }
}
