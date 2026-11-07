import BetterWisprCore
import Foundation

// Presentation stays separate from the canonical values used by prompts, exports and saved data.
extension SpeechModel {
    var localizedName: String {
        guard engine != .api else { return name }
        switch id {
        case "apple": return L10n.tr("Apple on-device")
        case "codex": return L10n.tr("Codex · Subscription")
        case "parakeet-ja": return L10n.tr("Parakeet Japanese")
        case "whisper-turbo-compressed": return L10n.tr("Whisper Large v3 Turbo (compressed)")
        default: return name
        }
    }

    var localizedDetail: String {
        // Connection names and endpoints are user data, even when they match a built-in label.
        if let connection { return "\(connection.api.localizedName) · \(connection.endpoint)" }
        switch id {
        case "apple": return L10n.tr("Uses an available macOS language pack. No cloud fallback.")
        case "codex": return L10n.tr("Transcribes with your Codex subscription through an unofficial ChatGPT endpoint. Requires internet access.")
        case "parakeet-ultra": return L10n.tr("Parakeet TDT v3 further trained by Moondream for fewer mistakes, with punctuation, the same 25 European languages and the same speed.")
        case "parakeet-v3": return L10n.tr("NVIDIA's multilingual model for 25 European languages, with punctuation. Fast on the Neural Engine.")
        case "parakeet-v2": return L10n.tr("NVIDIA's English-only model, tuned for English accuracy, with punctuation.")
        case "parakeet-110m": return L10n.tr("A small English-only model for Macs with less memory to spare.")
        case "parakeet-ja": return L10n.tr("NVIDIA's Parakeet model for Japanese speech.")
        case "whisper-turbo": return L10n.tr("Broadest language coverage, including languages Parakeet does not support.")
        case "whisper-turbo-compressed": return L10n.tr("The languages of Whisper Large v3 Turbo in a compressed build that takes less disk space.")
        case "whisper-small": return L10n.tr("A lighter multilingual Whisper model with a smaller download.")
        default: return detail
        }
    }

    var localizedSizeLabel: String {
        if engine == .api { return L10n.tr("Uses your endpoint") }
        switch id {
        case "apple": return L10n.tr("System managed")
        case "codex": return L10n.tr("ChatGPT subscription")
        case "parakeet-ultra": return L10n.tr("~730 MB")
        case "parakeet-v3": return L10n.tr("~580 MB")
        case "parakeet-v2": return L10n.tr("~560 MB")
        case "parakeet-110m": return L10n.tr("~330 MB")
        case "parakeet-ja": return L10n.tr("~720 MB")
        case "whisper-turbo": return L10n.tr("~1.6 GB")
        case "whisper-turbo-compressed": return L10n.tr("~650 MB")
        case "whisper-small": return L10n.tr("~490 MB")
        default: return sizeLabel
        }
    }

    var localizedLanguageNames: [String]? {
        languages?.map { L10n.locale.localizedString(forLanguageCode: $0) ?? $0 }.sorted()
    }
}

extension BuiltInModel {
    static var localizedSizeLabel: String { L10n.tr("1.28 GB") }
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
        // Resolve only labels whose provenance is known. A missing source keeps the saved citation.
        guard let meeting, let segment = meeting.segments.first(where: { $0.id == segmentID }) else { return label }
        return "\(segment.timestamp) \(segment.localizedLabel(names: meeting.participantNames))"
    }
}

extension MeetingQuestion {
    static var localizedCatchUpQuestion: String {
        L10n.tr("What did I miss in the last %@ minutes? Give the main points, decisions, and anything I was asked.", String(Int(catchUpWindow / 60)))
    }
}
