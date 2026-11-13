import BetterWisprCore
import Foundation
import Testing
@testable import BetterWispr

private let frenchStylePreview = StylePreview(locale: Locale(identifier: "fr_FR"))
private let englishStylePreview = StylePreview(locale: Locale(identifier: "en_US"))

@Test func frenchCleanupPreviewKeepsNonEnglishInputUnchanged() {
    let spoken = "euh bonjour Sam, je je pense que nous nous retrouvons demain. Non, non, ne supprime rien."
    #expect(frenchStylePreview.spokenSample == spoken)
    #expect(frenchStylePreview.cleanedSample(for: .none) == spoken)
    #expect(frenchStylePreview.cleanedSample(for: .light) == spoken)
    #expect(frenchStylePreview.cleanedSample(for: .light) == TranscriptCleaner.clean(spoken, language: "fr"))
    #expect(frenchStylePreview.cleanedSample(for: .medium) == spoken)
    #expect(frenchStylePreview.frenchCleanupNote == "Les nettoyages Léger et Moyen ne modifient que les dictées en anglais. Cet exemple français reste inchangé.")
    #expect(frenchStylePreview.lightCleanupDetail.contains("dictées en anglais"))
    #expect(frenchStylePreview.lightCleanupDetail.contains("« um »"))
    #expect(frenchStylePreview.spokenTitle == "Vous dites (exemple français)")
    #expect(frenchStylePreview.cleanedTitle == "BetterWispr écrit (exemple français)")
}

@Test func englishCleanupPreviewsKeepTheirExistingBehavior() {
    let spoken = "um hey Sam are we are we still on for lunch? I think uh we should leave early to beat the traffic."
    #expect(englishStylePreview.spokenSample == spoken)
    #expect(englishStylePreview.cleanedSample(for: .none) == spoken)
    #expect(englishStylePreview.cleanedSample(for: .light) == TranscriptCleaner.clean(spoken, language: "en"))
    #expect(englishStylePreview.cleanedSample(for: .light) == "Hey Sam are we still on for lunch? I think we should leave early to beat the traffic.")
    #expect(englishStylePreview.cleanedSample(for: .medium) == "Hey Sam, are we still on for lunch? I think we should leave early to beat the traffic.")
    #expect(englishStylePreview.spokenTitle == "You say")
    #expect(englishStylePreview.cleanedTitle == "BetterWispr types")
}

@Test func frenchToneSamplesCoverEveryContextAndKeepTheirLimitsVisible() {
    let samples: [(StyleContext, String)] = [
        (.personal, "Salut, tu es disponible pour dîner ce soir ? On se retrouve à 19 h si ça te convient."),
        (.work, "Bonjour, quand tu as un moment, faisons le point sur les résultats du lancement."),
        (.email, "Bonjour Sam,\n\nMerci pour notre échange aujourd’hui. Au plaisir de travailler ensemble.\n\nCordialement,\nAlex"),
        (.other, "Pour le moment, le nouveau plan fonctionne bien.\n\nDemain, je veux terminer le brouillon, surtout le résumé."),
    ]
    for (context, sample) in samples {
        #expect(frenchStylePreview.toneSample(for: context, tone: .formal) == sample)
        for tone in context.tones {
            let output = frenchStylePreview.toneSample(for: context, tone: tone)
            #expect(!output.contains("—") && !output.contains("–"))
            #expect(frenchStylePreview.accessibilityLabel(for: output) == "Exemple français : \(output)")
        }
    }
    #expect(frenchStylePreview.toneSample(for: .personal, tone: .casual) == "Salut tu es disponible pour dîner ce soir ? On se retrouve à 19 h si ça te convient")
    #expect(frenchStylePreview.toneSample(for: .personal, tone: .veryCasual) == "salut tu es disponible pour dîner ce soir ? on se retrouve à 19 h si ça te convient")
    #expect(frenchStylePreview.toneSample(for: .work, tone: .excited) == "Bonjour, quand tu as un moment, faisons le point sur les résultats du lancement !")
    #expect(frenchStylePreview.frenchToneNote == "Ces exemples français illustrent la présentation. Les tons ne modifient que les dictées en anglais.")
}

@Test func englishToneSamplesStayCanonicalAndUnsupportedLocalesFallBackToEnglish() {
    let samples: [(StyleContext, String)] = [
        (.personal, "Hey, are you around for dinner tonight? Let's do 7 if that works for you."),
        (.work, "Hey, when you have a minute, let's go over the launch numbers."),
        (.email, "Hi Sam,\n\nThanks for the quick call today. Looking forward to working together.\n\nBest,\nAlex"),
        (.other, "So far, the new plan is working well.\n\nTomorrow I want to finish the draft, especially the summary."),
    ]
    let unsupported = StylePreview(locale: Locale(identifier: "zz_ZZ"))
    for (context, sample) in samples {
        for tone in context.tones {
            let expected = StyleFormatter.apply(tone, to: sample)
            #expect(englishStylePreview.toneSample(for: context, tone: tone) == expected)
            #expect(unsupported.toneSample(for: context, tone: tone) == expected)
        }
    }
    #expect(StylePreview(locale: Locale(identifier: "fr_CA")).spokenSample == frenchStylePreview.spokenSample)
    #expect(unsupported.spokenSample == englishStylePreview.spokenSample)
    #expect(englishStylePreview.accessibilityLabel(for: "Hello") == "Example: Hello")
}
