import Testing
@testable import BetterWisprCore

struct SemanticListExample: Sendable {
    let name: String
    let spoken: String
    let formatted: String
    let numbered: Bool
    let items: Int

    static let all: [Self] = [
        .init(name: "mixed-shopping", spoken: "Okay, let's do my shopping list. I need to buy milk, I need to buy bread, another thing, buy eggs, then buy flour, then buy donuts.",
              formatted: "Okay, let's do my shopping list.\n\n- I need to buy milk.\n- I need to buy bread.\n- Buy eggs.\n- Buy flour.\n- Buy donuts.", numbered: false, items: 5),
        .init(name: "no-introduction", spoken: "I need to buy milk I need to buy bread and I need to buy eggs.",
              formatted: "- I need to buy milk.\n- I need to buy bread.\n- I need to buy eggs.", numbered: false, items: 3),
        .init(name: "parallel-tasks", spoken: "We need to update the website, send the invoices and book the room.",
              formatted: "We need to:\n\n- Update the website.\n- Send the invoices.\n- Book the room.", numbered: false, items: 3),
        .init(name: "ordered-actions", spoken: "Open the app, sign in, choose the report and press export.",
              formatted: "1. Open the app.\n2. Sign in.\n3. Choose the report.\n4. Press export.", numbered: true, items: 4),
        .init(name: "unseen-groceries", spoken: "I need milk, bread, eggs, flour and donuts.",
              formatted: "- Milk.\n- Bread.\n- Eggs.\n- Flour.\n- Donuts.", numbered: false, items: 5),
        .init(name: "unseen-requirements", spoken: "The release needs a keyboard shortcut that works, a history that survives restarts, and a way to copy the result.",
              formatted: "The release needs:\n\n- A keyboard shortcut that works.\n- A history that survives restarts.\n- A way to copy the result.", numbered: false, items: 3),
        .init(name: "unseen-tomorrow", spoken: "For tomorrow please call Sam, renew the insurance, pick up the parcel and water the plants.",
              formatted: "For tomorrow:\n\n- Please call Sam.\n- Renew the insurance.\n- Pick up the parcel.\n- Water the plants.", numbered: false, items: 4),
        .init(name: "unseen-past-purchase", spoken: "I put the milk next to the bread and realised I had forgotten the eggs.",
              formatted: "I put the milk next to the bread and realised I had forgotten the eggs.", numbered: false, items: 0),
        .init(name: "explicit-ordinals", spoken: "First of all send the invoice. Second of all book the room. Third of all call Alex.",
              formatted: "1. Send the invoice.\n2. Book the room.\n3. Call Alex.", numbered: true, items: 3),
        .init(name: "unordered-transitions", spoken: "One thing is we need more time. Another thing is we need more people. One more thing is we need more space.",
              formatted: "We need:\n\n- More time.\n- More people.\n- More space.", numbered: false, items: 3),
        .init(name: "ordinary-narrative", spoken: "I bought milk after work, then went home because it was raining.",
              formatted: "I bought milk after work, then went home because it was raining.", numbered: false, items: 0),
        .init(name: "ordinal-comparison", spoken: "The first room is upstairs and the second room is downstairs.",
              formatted: "The first room is upstairs and the second room is downstairs.", numbered: false, items: 0),
        .init(name: "people-in-prose", spoken: "I met Alex, Sam and Jo at the station.",
              formatted: "I met Alex, Sam and Jo at the station.", numbered: false, items: 0),
    ]
}

@Test(arguments: SemanticListExample.all)
func semanticListEditsPassTheExistingSafetyChecks(_ example: SemanticListExample) {
    #expect(TranscriptPolisher.accepted(example.formatted, for: example.spoken) == example.formatted)
}

@Test(arguments: SemanticListExample.all)
func lightCleanupLeavesListDecisionsToTheLanguageModel(_ example: SemanticListExample) {
    #expect(TranscriptCleaner.clean(example.spoken, language: "en") == example.spoken)
}

@Test func semanticFormattingStillRejectsAnswersAndUnspokenItems() {
    let spoken = "I need to buy milk I need to buy bread and I need to buy eggs."
    #expect(TranscriptPolisher.accepted("- I need to buy milk.\n- I need to buy bread.\n- I need to buy eggs.\n- Add chocolate, butter, lemons and orange juice.", for: spoken) == nil)
    #expect(TranscriptPolisher.accepted("You should visit the supermarket tomorrow morning.", for: spoken) == nil)
}

@Test func semanticLayoutRendersNaturalRequestsWithoutCueWords() {
    let text = "I need milk, bread, eggs, flour and donuts."
    let layout = TranscriptListLayout(kind: .bullets, items: ["milk", "bread", "eggs", "flour", "donuts"])
    #expect(layout.render(in: text) == "I need:\n\n- milk\n- bread\n- eggs\n- flour\n- donuts.")
    let ordinal = "First of all send the invoice. Second of all book the room. Third of all call Alex."
    #expect(TranscriptListLayout(kind: .bullets, items: ["send the invoice", "book the room", "call Alex"]).render(in: ordinal)
            == "1. send the invoice.\n2. book the room.\n3. call Alex.")
}

@Test func semanticLayoutPreservesIntroductionsAndClosingWords() {
    let text = "We need to send the invoice, book the room and call Alex. Thanks everyone."
    let layout = TranscriptListLayout(kind: .bullets, items: ["send the invoice", "book the room", "call Alex"], closing: "Thanks everyone.")
    #expect(layout.render(in: text) == "We need to:\n\n- send the invoice\n- book the room\n- call Alex.\n\nThanks everyone.")
}

@Test func semanticLayoutRejectsInventedReorderedOrMissingContent() {
    let text = "I need milk, two loaves of bread, and eggs."
    #expect(TranscriptListLayout(kind: .bullets, items: ["milk", "bread", "eggs"]).render(in: text) == text)
    #expect(TranscriptListLayout(kind: .bullets, items: ["milk", "cheese"]).render(in: text) == text)
    #expect(TranscriptListLayout(kind: .bullets, items: ["eggs", "milk"]).render(in: text) == text)
    let negated = "Do not buy milk, buy bread."
    #expect(TranscriptListLayout(kind: .bullets, items: ["buy milk", "buy bread"]).render(in: negated) == negated)
    #expect(TranscriptListLayout(kind: .prose, items: []).render(in: text) == text)
}

@Test func semanticLayoutDecodesProviderJSONAndRejectsInvalidShapes() throws {
    let layout = try TranscriptListLayout.decode("```json\n{\"kind\":\"bullets\",\"items\":[\"milk\",\"bread\"]}\n```")
    #expect(layout.items == ["milk", "bread"])
    #expect(throws: (any Error).self) { try TranscriptListLayout.decode("{\"kind\":\"invented\",\"items\":[]}") }
}
