import BetterWisprCore
import Foundation

/// Presentation examples only. The interface language never selects a dictation language.
struct StylePreview {
    let locale: Locale

    init(locale: Locale = L10n.locale) {
        self.locale = locale
    }

    var isFrench: Bool { locale.language.languageCode?.identifier == "fr" }

    var spokenSample: String {
        localized("um hey Sam are we are we still on for lunch? I think uh we should leave early to beat the traffic.")
    }

    var spokenTitle: String { localized("You say") }
    var cleanedTitle: String { localized("BetterWispr types") }

    var lightCleanupDetail: String {
        localized("Removes filler words like “um” and “you know”, stutters like “we we”, and corrections like “at 5, no, at 6”.")
    }

    var frenchCleanupNote: String {
        localized("Light and Medium cleanup only edit English dictation. This French example is left unchanged.")
    }

    var frenchToneNote: String {
        localized("French examples illustrate the presentation. Tones only change English dictation.")
    }

    func cleanedSample(for level: CleanupLevel) -> String {
        switch level {
        case .none: spokenSample
        case .light: TranscriptCleaner.clean(spokenSample, language: isFrench ? "fr" : "en")
        case .medium:
            isFrench ? TranscriptCleaner.clean(spokenSample, language: "fr")
                : "Hey Sam, are we still on for lunch? I think we should leave early to beat the traffic."
        }
    }

    func toneSample(for context: StyleContext, tone: StyleTone) -> String {
        let source = switch context {
        case .personal: "Hey, are you around for dinner tonight? Let's do 7 if that works for you."
        case .work: "Hey, when you have a minute, let's go over the launch numbers."
        case .email: "Hi Sam,\n\nThanks for the quick call today. Looking forward to working together.\n\nBest,\nAlex"
        case .other: "So far, the new plan is working well.\n\nTomorrow I want to finish the draft, especially the summary."
        }
        let sample = StyleFormatter.apply(tone, to: localized(source))
        return isFrench && tone == .excited ? sample.replacingOccurrences(of: "!", with: " !") : sample
    }

    func accessibilityLabel(for sample: String) -> String {
        L10n.localized("Example: %@", locale: locale, table: "StyleExamples", arguments: [sample])
    }

    private func localized(_ key: String) -> String {
        L10n.localized(key, locale: locale, table: "StyleExamples")
    }
}
