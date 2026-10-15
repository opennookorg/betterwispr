import BetterWisprCore
import Foundation
import Testing
@testable import BetterWispr

@Test func selectedTextIsRefusedWhenEmptyShortNotEnglishOrTheCleanupProviderIsMissing() {
    var settings = AppSettings()
    settings.cleanupSelection = .ollama("llama3.2")
    let sentence = "  so um we should probably ship it on friday i think  "

    #expect(SelectedTextCleanupOutcome.refusal(of: " \n\t ", settings: settings.cleanupSettings) == .noSelection)
    #expect(SelectedTextCleanupOutcome.refusal(of: "ship it friday", settings: settings.cleanupSettings) == .tooShort)
    #expect(SelectedTextCleanupOutcome.refusal(of: "Bonjour à tous, je voudrais réserver une table pour ce soir.", settings: settings.cleanupSettings) == .notEnglish)
    #expect(SelectedTextCleanupOutcome.refusal(of: sentence, settings: settings.cleanupSettings) == nil)

    settings.cleanupSelection = .connection(UUID())
    #expect(SelectedTextCleanupOutcome.refusal(of: sentence, settings: settings.cleanupSettings)
        == .unavailable("The selected notes connection is missing. Choose a notes model in Models."))
}

@Test func replacementKeepsTheWhitespaceAroundTheSelectionAndSkipsAnUnchangedEdit() {
    let selected = "\n  so um we ship it friday \n"

    #expect(SelectedTextCleanupOutcome.replacement(keepingWhitespaceOf: selected, ifChangedTo: "We ship it Friday.") == "\n  We ship it Friday. \n")
    #expect(SelectedTextCleanupOutcome.replacement(keepingWhitespaceOf: selected, ifChangedTo: "so um we ship it friday") == nil)
    #expect(SelectedTextCleanupOutcome.replacement(keepingWhitespaceOf: "We ship it Friday.", ifChangedTo: "We ship it on Friday.") == "We ship it on Friday.")
    #expect(SelectedTextCleanupOutcome.replacement(keepingWhitespaceOf: "so um we ship it friday\u{200B}", ifChangedTo: "so um we ship it friday") == nil)
    #expect(SelectedTextCleanupOutcome.replacement(keepingWhitespaceOf: "so um we ship it friday\u{200B}", ifChangedTo: "We ship it Friday.") == "We ship it Friday.\u{200B}")
}
