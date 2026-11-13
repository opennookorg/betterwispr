import BetterWisprCore
import Foundation

extension SpeechModel {
    var localizedName: String { engine == .api ? name : L10n.tr(name) }

    var localizedDetail: String {
        connection.map { "\($0.api.localizedName) · \($0.endpoint)" } ?? L10n.tr(detail)
    }

    var localizedSizeLabel: String { L10n.tr(sizeLabel) }

    var localizedLanguageNames: [String]? {
        languages?.map { L10n.locale.localizedString(forLanguageCode: $0) ?? $0 }.sorted()
    }
}

extension BuiltInModel {
    static var localizedSizeLabel: String { L10n.tr(sizeLabel) }
}

extension SpeechAPI {
    var localizedName: String { self == .openAICompatible ? L10n.tr("OpenAI-compatible") : name }
}

extension AppSettings {
    var localizedNotesModelName: String {
        switch notesSelection {
        case .apple: return "Apple Intelligence"
        case .builtIn: return L10n.tr("Built-in · %@", BuiltInModel.displayName)
        case .ollama(let name): return "Ollama · \(name)"
        case .connection(let id):
            return notesConnections.first { $0.id == id }.map { "\($0.name) · \($0.modelID)" } ?? L10n.tr("Missing notes connection")
        case .cli(let cli):
            return "\(cli.name) · \(cliModel(cli).isEmpty ? L10n.tr("Choose a model") : cliModel(cli))"
        }
    }
}

extension Speaker {
    var localizedLabel: String { self == .me ? L10n.tr("Me") : L10n.tr("Them") }
}

extension MeetingSegment {
    func localizedLabel(names: [Int: String]? = nil) -> String {
        participant == nil ? speaker.localizedLabel : Self.localizedLabel(of: participant, names: names)
    }

    static func localizedLabel(of participant: Int?, names: [Int: String]?) -> String {
        guard let participant else { return Speaker.them.localizedLabel }
        let name = names?[participant]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? L10n.tr("Speaker %@", String(participant)) : name
    }
}

extension Meeting {
    var localizedDisplayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.tr("New Meeting") : title
    }

    func localizedVoiceLabel(_ segment: MeetingSegment) -> String? {
        segment.participant == nil ? nil : segment.localizedLabel(names: participantNames)
    }
}

extension MeetingLine {
    func localizedLabel(in meeting: Meeting?) -> String {
        guard let segmentID else { return L10n.tr("My thoughts") }
        guard let meeting, let segment = meeting.segments.first(where: { $0.id == segmentID }) else { return label }
        return "\(segment.timestamp) \(segment.localizedLabel(names: meeting.participantNames))"
    }
}

extension MeetingQuestion {
    static var localizedCatchUpQuestion: String {
        L10n.tr("What did I miss in the last %@ minutes? Give the main points, decisions, and anything I was asked.", String(Int(catchUpWindow / 60)))
    }
}
