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

@MainActor @Test func onboardingListsAppleOnlyWhenItIsAvailable() {
    let available = OnboardingView.speechChoices(from: SpeechModel.catalog, appleSpeechAvailable: true)
    let unavailable = OnboardingView.speechChoices(from: SpeechModel.catalog, appleSpeechAvailable: false)

    #expect(available.map(\.id) == ["parakeet-ultra", "apple"])
    #expect(unavailable.map(\.id) == ["parakeet-ultra"])
}

@MainActor @Test func onboardingHoldsContinueOnlyOnTheModelStepWithUnavailableApple() throws {
    let apple = try catalogModel("apple")
    let parakeet = try catalogModel("parakeet-ultra")

    #expect(!OnboardingView.canContinue(from: .model, selected: apple, appleSpeechAvailable: false))
    #expect(OnboardingView.canContinue(from: .model, selected: apple, appleSpeechAvailable: true))
    #expect(OnboardingView.canContinue(from: .model, selected: parakeet, appleSpeechAvailable: false))
    for step in OnboardingStep.allCases where step != .model {
        #expect(OnboardingView.canContinue(from: step, selected: apple, appleSpeechAvailable: false))
    }
}

@Test func onlyAppleSpeechCanBeUnavailable() throws {
    let apple = try catalogModel("apple")
    let others = SpeechModel.catalog.filter { $0.engine != .apple } + [.codex]

    #expect(apple.isUnavailable(appleSpeechAvailable: false))
    #expect(!apple.isUnavailable(appleSpeechAvailable: true))
    #expect(others.allSatisfy { !$0.isUnavailable(appleSpeechAvailable: false) })
}
