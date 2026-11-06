@testable import BetterWisprCore
import Testing
@testable import BetterWispr

private func catalogModel(_ id: String) throws -> SpeechModel {
    try #require(SpeechModel.catalog.first { $0.id == id })
}

@MainActor @Test func onboardingExplainsAHiddenSelectedModel() throws {
    let apple = try catalogModel("apple")
    let parakeet = try catalogModel("parakeet-ultra")
    let whisper = try catalogModel("whisper-turbo")

    #expect(OnboardingView.selectedModelNote(selected: apple, isInstalled: true, choices: [parakeet, apple]) == nil)
    #expect(OnboardingView.selectedModelNote(selected: parakeet, isInstalled: false, choices: [parakeet]) == nil)
    #expect(OnboardingView.selectedModelNote(selected: apple, isInstalled: true, choices: [parakeet])?.contains("isn’t available") == true)
    #expect(OnboardingView.selectedModelNote(selected: whisper, isInstalled: true, choices: [parakeet])?.contains(whisper.name) == true)
    #expect(OnboardingView.selectedModelNote(selected: whisper, isInstalled: false, choices: [parakeet]) == nil)
}
