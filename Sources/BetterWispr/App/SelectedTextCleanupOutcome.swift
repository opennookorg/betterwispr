import BetterWisprCore
import Foundation

enum SelectedTextCleanupOutcome: Equatable {
    case busy, needsAccessibility, noOtherApp, secureInput, noSelection, tooShort, notEnglish
    case unavailable(String)
    case leftAsIs(model: String)
    case alreadyClean
    case copied
    case replaced(in: String)
    case failed(String)

    static func refusal(of selected: String, settings: AppSettings) -> SelectedTextCleanupOutcome? {
        let text = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .noSelection }
        if text.split(whereSeparator: \.isWhitespace).count < TranscriptPolisher.minimumWords { return .tooShort }
        if !TranscriptCleaner.isEnglish(text, language: nil) { return .notEnglish }
        if case .unavailable(let reason) = MeetingNotesGenerator.availability(settings: settings) { return .unavailable(reason) }
        return nil
    }

    static func replacement(keepingWhitespaceOf selected: String, ifChangedTo edited: String) -> String? {
        let text = CharacterSet.whitespacesAndNewlines.inverted
        guard let first = selected.rangeOfCharacter(from: text),
              let last = selected.rangeOfCharacter(from: text, options: .backwards),
              selected[first.lowerBound..<last.upperBound] != edited else { return nil }
        return selected.replacingCharacters(in: first.lowerBound..<last.upperBound, with: edited)
    }

    func toast(allowingAccessibility allow: @escaping @MainActor () -> Void) -> Toast {
        switch self {
        case .busy:
            Toast(title: L10n.tr("Finish dictating first"), message: L10n.tr("Then press the shortcut again."), systemImage: "waveform", isError: true)
        case .needsAccessibility:
            Toast(title: L10n.tr("Allow Accessibility"), message: L10n.tr("BetterWispr needs it to read and replace the selected text."), systemImage: "lock.shield",
                  isError: true, action: Toast.Action(title: L10n.tr("Allow"), perform: allow))
        case .noOtherApp:
            Toast(title: L10n.tr("Select text in another app"), message: L10n.tr("Then press the shortcut to clean it up."), systemImage: "text.cursor", isError: true)
        case .secureInput:
            Toast(title: L10n.tr("Can’t read the selection"), message: L10n.tr("Secure input is on, as in a password field."), systemImage: "lock", isError: true)
        case .noSelection:
            Toast(title: L10n.tr("No selected text found"), message: L10n.tr("Select text and press again. Some apps don’t share their selection."), systemImage: "text.cursor", isError: true)
        case .tooShort:
            Toast(title: L10n.tr("Select at least %@ words", String(TranscriptPolisher.minimumWords)), message: L10n.tr("Shorter text is left as is."), systemImage: "text.cursor", isError: true)
        case .notEnglish:
            Toast(title: L10n.tr("English only"), message: L10n.tr("Cleanup edits English text, like Medium dictation."), systemImage: "character.bubble", isError: true)
        case .unavailable(let reason):
            Toast(title: L10n.tr("Cleanup provider isn’t ready"), message: reason, systemImage: "exclamationmark.triangle.fill", isError: true)
        case .leftAsIs(let model):
            Toast(title: L10n.tr("Left as is"), message: L10n.tr("%@ didn’t return a usable edit.", String(model)), systemImage: "exclamationmark.triangle.fill", isError: true)
        case .alreadyClean:
            Toast(title: L10n.tr("Already clean"), message: L10n.tr("The cleanup provider found nothing to change."), systemImage: "checkmark")
        case .copied:
            Toast(title: L10n.tr("Copied, not pasted"), message: L10n.tr("The app or selection changed. Paste the cleaned text with ⌘V."), systemImage: "doc.on.clipboard")
        case .replaced(let app):
            Toast(title: L10n.tr("Cleaned up"), message: L10n.tr("Replaced the selection in %@.", String(app)), systemImage: "wand.and.stars")
        case .failed(let reason):
            Toast(title: L10n.tr("Couldn’t clean up"), message: reason, systemImage: "exclamationmark.triangle.fill", isError: true)
        }
    }
}
