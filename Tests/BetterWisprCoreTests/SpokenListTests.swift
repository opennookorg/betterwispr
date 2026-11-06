import Foundation
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
    #expect(layout.render(in: text) == "I need:\n\n- Milk.\n- Bread.\n- Eggs.\n- Flour.\n- Donuts.")
    let ordinal = "First of all send the invoice. Second of all book the room. Third of all call Alex."
    #expect(TranscriptListLayout(kind: .bullets, items: ["send the invoice", "book the room", "call Alex"]).render(in: ordinal)
            == "1. Send the invoice.\n2. Book the room.\n3. Call Alex.")
}

@Test func semanticLayoutPreservesIntroductionsAndClosingWords() {
    let text = "We need to send the invoice, book the room and call Alex. Thanks everyone."
    let layout = TranscriptListLayout(kind: .bullets, items: ["send the invoice", "book the room", "call Alex"], closing: "Thanks everyone.")
    #expect(layout.render(in: text) == "We need to:\n\n- Send the invoice.\n- Book the room.\n- Call Alex.\n\nThanks everyone.")
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

private struct ScriptedModel: NotesLanguageModel {
    let reply: @Sendable () async throws -> String

    func respond(to prompt: String) async throws -> String { try await reply() }

    func draft(_ prompt: String) -> NotesDraft { NotesDraft(title: "", overview: "", keyPoints: [], decisions: [], actionItems: []) }
}

private actor CallCount {
    private(set) var value = 0

    func increment() { value += 1 }
}

private let spokenList = "send the invoice, book the room and call Alex"
private let editedList = "Send the invoice, book the room and call Alex."

private func polished(editor: @escaping @Sendable () async throws -> String, formatter: @escaping @Sendable () async throws -> String,
                      instructions: String = "", timeout: Duration = .seconds(5)) async -> String? {
    await TranscriptPolisher.polish(spokenList, request: "", instructions: instructions, editor: ScriptedModel(reply: editor),
                                    formatter: ScriptedModel(reply: formatter), attempts: 3, timeout: timeout)
}

@Test func aFailedLayoutKeepsTheEditAndNeverRepeatsIt() async {
    let replies = ["not json", "Here it is: {\"kind\":\"bullets\",\"items\":[]}", "{\"kind\":\"prose\"}", ""]
    for reply in replies {
        let edits = CallCount()
        let result = await polished(editor: { await edits.increment(); return editedList }, formatter: { reply })
        #expect(result == editedList)
        #expect(await edits.value == 1)
    }
    #expect(await polished(editor: { editedList }, formatter: { throw URLError(.timedOut) }) == editedList)
    let stalled = await polished(editor: { editedList }, formatter: {
        try await Task.sleep(for: .seconds(30))
        return "{\"kind\":\"prose\",\"items\":[]}"
    }, timeout: .milliseconds(100))
    #expect(stalled == editedList)
}

@Test func aSuccessfulLayoutFormatsTheEdit() async {
    let result = await polished(editor: { editedList }, formatter: { "{\"kind\":\"bullets\",\"items\":[\"Send the invoice\",\"book the room\",\"call Alex\"]}" })
    #expect(result == "- Send the invoice.\n- Book the room.\n- Call Alex.")
}

@Test func aFailedOrRejectedEditKeepsTheLightCleanupWithoutALayout() async {
    let layouts = CallCount()
    let formatter: @Sendable () async throws -> String = { await layouts.increment(); return "{\"kind\":\"prose\",\"items\":[]}" }
    #expect(await polished(editor: { throw MeetingNotesError.unavailable("off") }, formatter: formatter) == nil)
    #expect(await polished(editor: { "You should ask your accountant about quarterly invoices tomorrow morning instead." }, formatter: formatter) == nil)
    #expect(await layouts.value == 0)
}

@Test func modeInstructionsSkipTheLayoutThatCouldOverrideThem() async {
    let layouts = CallCount()
    let formatter: @Sendable () async throws -> String = { await layouts.increment(); return "{\"kind\":\"bullets\",\"items\":[\"Send the invoice\",\"book the room\",\"call Alex\"]}" }
    #expect(await polished(editor: { editedList }, formatter: formatter, instructions: "Write one paragraph.") == editedList)
    #expect(await layouts.value == 0)
    #expect(await polished(editor: { editedList }, formatter: formatter, instructions: "  ") != editedList)
    #expect(await layouts.value == 1)
}

@Test func textWithoutSpacesNeverReachesAModel() async {
    #expect(await TranscriptPolisher.polish("牛乳とパンと卵を買ってください", settings: AppSettings(), vocabulary: [], context: nil) == nil)
    #expect(!TranscriptCleaner.isEnglish("牛乳とパンと卵を買ってください", language: nil))
    #expect(!TranscriptCleaner.isEnglish("Necesito comprar leche, pan y huevos por favor.", language: nil))
}

@Test func alternativesAndNegationsStayProse() {
    let cases: [(String, [String])] = [
        ("Do you want tea, coffee or juice with your breakfast?", ["tea", "coffee", "juice with your breakfast"]),
        ("Pick up milk or bread or eggs.", ["milk", "bread", "eggs"]),
        ("I cannot call Sam, email Priya and book the room today.", ["I cannot call Sam", "email Priya", "book the room today"]),
        ("You can't buy milk and bread here.", ["buy milk", "bread here"]),
        ("I won’t send the invoice and book the room.", ["send the invoice", "book the room"]),
    ]
    for (text, items) in cases {
        #expect(TranscriptListLayout(kind: .bullets, items: items).render(in: text) == text)
    }
    #expect(TranscriptListLayout(kind: .bullets, items: ["Buy milk", "don't buy bread"]).render(in: "Buy milk, don't buy bread.") == "Buy milk, don't buy bread.")
}

@Test func aLayoutKeepsEveryQuantityAndOrdinalWord() {
    #expect(TranscriptListLayout(kind: .bullets, items: ["two eggs", "banana", "apple"]).render(in: "We ate two eggs, one banana and one apple.")
            == "We ate two eggs, one banana and one apple.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["one", "two", "three"]).render(in: "I want one, two and three.")
            == "I want:\n\n- One.\n- Two.\n- Three.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["Milk", "bread", "eggs are on the table"]).render(in: "I got here first. Milk, bread and eggs are on the table.")
            == "I got here first.\n\n- Milk.\n- Bread.\n- Eggs are on the table.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["send the invoice", "call Alex", "book the room"]).render(in: "One thing, send the invoice. One more thing, call Alex. And book the room.")
            == "- Send the invoice.\n- Call Alex.\n- Book the room.")
}

@Test func twoUnnumberedItemsStayProse() {
    let cases: [(String, [String])] = [
        ("Pick up milk, bread and eggs.", ["Pick up milk", "bread and eggs"]),
        ("I visited Paris and Tokyo last year.", ["Paris", "Tokyo"]),
        ("We flew to Paris and then to Tokyo for the conference.", ["Paris", "Tokyo"]),
        ("One thing, send the invoice. One more thing, call Alex.", ["send the invoice", "call Alex"]),
    ]
    for (text, items) in cases {
        #expect(TranscriptListLayout(kind: .bullets, items: items).render(in: text) == text)
        #expect(TranscriptListLayout(kind: .numbered, items: items).render(in: text) == text)
    }
}

@Test func twoExplicitlyNumberedItemsFormAList() {
    #expect(TranscriptListLayout(kind: .bullets, items: ["open the app", "sign in"]).render(in: "First open the app, second sign in.")
            == "1. Open the app.\n2. Sign in.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["Number one call Sam", "Number two email Priya"]).render(in: "Number one call Sam. Number two email Priya.")
            == "1. Call Sam.\n2. Email Priya.")
}

@Test func theWordNextStaysUnlessItSeparatesItems() {
    let tuesday = "Call Sam next Tuesday, email Priya and book the room."
    #expect(TranscriptListLayout(kind: .bullets, items: ["Call Sam", "Tuesday"]).render(in: "Call Sam next Tuesday.") == "Call Sam next Tuesday.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["Call Sam", "Tuesday", "email Priya", "book the room"]).render(in: tuesday) == tuesday)
    #expect(TranscriptListLayout(kind: .bullets, items: ["Call Sam next Tuesday", "email Priya", "book the room"]).render(in: tuesday)
            == "- Call Sam next Tuesday.\n- Email Priya.\n- Book the room.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["send the invoice", "book the room", "call Alex"]).render(in: "Send the invoice. Next, book the room. Next, call Alex.")
            == "- Send the invoice.\n- Book the room.\n- Call Alex.")
}

@Test func listItemsReadConsistently() {
    #expect(TranscriptListLayout(kind: .bullets, items: ["iPhone cases", "example.com renewals", "more time"]).render(in: "We need iPhone cases, example.com renewals and more time.")
            == "We need:\n\n- iPhone cases.\n- example.com renewals.\n- More time.")
    #expect(TranscriptListLayout(kind: .bullets, items: ["Did you send the invoice", "did you book the room", "did you call Alex"]).render(in: "Did you send the invoice? Did you book the room? Did you call Alex?")
            == "- Did you send the invoice?\n- Did you book the room?\n- Did you call Alex?")
}

@Test func numberedItemsDropOnlyTheOrdinalForTheirPosition() {
    #expect(TranscriptListLayout(kind: .numbered, items: ["First open the app", "second sign in", "third press export"]).render(in: "First open the app, second sign in, third press export.")
            == "1. Open the app.\n2. Sign in.\n3. Press export.")
    #expect(TranscriptListLayout(kind: .numbered, items: ["Step one open the app", "Step two sign in", "Step three press export"]).render(in: "Step one open the app. Step two sign in. Step three press export.")
            == "1. Open the app.\n2. Sign in.\n3. Press export.")
    #expect(TranscriptListLayout(kind: .numbered, items: ["Second hand shops", "third party tools", "first aid kits"]).render(in: "Second hand shops, third party tools and first aid kits.")
            == "1. Second hand shops.\n2. Third party tools.\n3. First aid kits.")
}

@Test(arguments: [
    "I bought milk after work, then went home because it was raining.",
    "The first room is upstairs and the second room is downstairs.",
    "First I was annoyed and then I was relieved when it finally worked.",
    "We flew to Paris and then to Tokyo for the conference.",
    "I visited Paris and Tokyo last year.",
    "Call Sam next Tuesday about the renewal.",
    "Do you want tea, coffee or juice with your breakfast?",
    "We processed 20,000 records in 35 files and stopped.",
])
func proseMakesNoLayoutCall(_ text: String) async {
    #expect(!TranscriptListFormatter.isLikelyList(text))
    let layouts = CallCount()
    let result = await TranscriptPolisher.polish(text, request: "", instructions: "", editor: ScriptedModel(reply: { text }),
                                                 formatter: ScriptedModel(reply: { await layouts.increment(); return "{\"kind\":\"prose\",\"items\":[]}" }), attempts: 1, timeout: .seconds(5))
    #expect(result == text)
    #expect(await layouts.value == 0)
}

@Test(arguments: [
    "We need to update the website, send the invoices and book the room.",
    "Open the app, sign in, choose the report and press export.",
    "I need milk, bread, eggs, flour and donuts.",
    "I need to buy milk I need to buy bread and I need to buy eggs.",
    "One thing is we need more time. Another thing is we need more people. One more thing is we need more space.",
    "First of all send the invoice. Second of all book the room. Third of all call Alex.",
    "First open the app, second sign in.",
    "Open the app and then sign in and then press export.",
])
func aLikelyListIsWorthALayoutCall(_ text: String) {
    #expect(TranscriptListFormatter.isLikelyList(text))
}

private func polishedBreaks(_ text: String, editor: String, instructions: String = "", layouts: CallCount) async -> String? {
    await TranscriptPolisher.polish(text, request: "", instructions: instructions, editor: ScriptedModel(reply: { editor }),
                                    formatter: ScriptedModel(reply: { await layouts.increment(); return "{\"kind\":\"bullets\",\"items\":[\"a\",\"b\",\"c\"]}" }), attempts: 1, timeout: .seconds(5))
}

@Test func spokenBreakCuesAreConvertedBeforeTheModelAndOrdinaryUsesAreNot() {
    #expect(VoiceCommands.apply("Send the report to Sam today new line call the vendor") == "Send the report to Sam today\nCall the vendor")
    #expect(VoiceCommands.apply("Thanks for the update new paragraph I will review the draft") == "Thanks for the update\n\nI will review the draft")
    #expect(VoiceCommands.apply("We launched a new line of products last spring.") == "We launched a new line of products last spring.")
}

@Test func dictatedBreaksSurviveTheEditWithoutALayoutCall() async {
    let layouts = CallCount()
    let lines = "Send the report to Sam today\nCall the vendor about the date"
    #expect(await polishedBreaks(lines, editor: "Send the report to Sam today.  \nCall the vendor about the date.", layouts: layouts)
            == "Send the report to Sam today.\nCall the vendor about the date.")
    let paragraphs = "Thanks for the update\n\nI will review the draft today"
    #expect(await polishedBreaks(paragraphs, editor: "Thanks for the update.\nI will review the draft today.", layouts: layouts)
            == "Thanks for the update.\n\nI will review the draft today.")
    #expect(await layouts.value == 0)
}

@Test func anEditThatLosesOrAddsLinesKeepsTheLightCleanup() async {
    let layouts = CallCount()
    let lines = "Send the report to Sam today\nCall the vendor about the date"
    #expect(await polishedBreaks(lines, editor: "Send the report to Sam today. Call the vendor about the date.", layouts: layouts) == nil)
    #expect(await polishedBreaks(lines, editor: "- Send the report to Sam today.\n- Call the vendor about the date.", layouts: layouts) == nil)
    #expect(await polishedBreaks(lines, editor: "Send the report to Sam.\nToday.\nCall the vendor about the date.", layouts: layouts) == nil)
    #expect(await layouts.value == 0)
}

@Test func selectedTextCleanupNeverFormsOrDropsAList() async {
    func cleaned(_ text: String, _ reply: String) async -> String? {
        await TranscriptPolisher.polish(text, request: "", instructions: "", editor: ScriptedModel(reply: { reply }), formatter: nil, attempts: 1, timeout: .seconds(5))
    }
    #expect(await cleaned("send the invoice, book the room and call Alex", "Send the invoice, book the room and call Alex.") == "Send the invoice, book the room and call Alex.")
    #expect(await cleaned("send the invoice, book the room and call Alex", "- Send the invoice.\n- Book the room.\n- Call Alex.") == nil)
    #expect(await cleaned("- send the invoice\n- book the room\n- call alex", "- Send the invoice\n- Book the room\n- Call Alex") == "- Send the invoice\n- Book the room\n- Call Alex")
    #expect(await cleaned("- send the invoice\n- book the room\n- call alex", "Send the invoice, book the room and call Alex.") == nil)
    let selection = TranscriptPolisher.exchange("send the invoice", for: .apple, vocabulary: [], context: nil, instructions: "", fixed: TranscriptPolisher.selectionInstructions).instructions
    #expect(selection.contains("Do not turn sentences into a bullet or numbered list"))
    #expect(!selection.contains("is a list") && !selection.contains("- Milk."))
}

@Test(arguments: [TranscriptPolisher.instructions, TranscriptPolisher.selectionInstructions])
func cleanupKeepsItsEditingRules(_ prompt: String) {
    for rule in ["When uncertain, preserve the original wording.", "“wait”, “wait no”, “actually”, “sorry”, “scratch that”, “I mean”, “no”",
                 "“new line”, and “new paragraph”", "Write clear spoken numbers as digits", "about 40 words", "certainty, emotion, and level of formality",
                 "Output: Tell the team we will meet on Friday morning.", "Output: We processed 20,000 records in 35 files."] {
        #expect(prompt.contains(rule))
    }
}

@Test func filteredRepliesLoseSpacesBeforeLineBreaks() {
    #expect(TranscriptPolisher.filtered("1. Update the website.  \n2. Send the invoices.\t\n3. Book the room.") == "1. Update the website.\n2. Send the invoices.\n3. Book the room.")
}

@Test func tonesLeaveListMarkersAlone() {
    let numbered = "1. Open the app\n2. Sign in\n3. Call Alex"
    #expect(StyleFormatter.apply(.excited, to: numbered) == numbered)
    #expect(StyleFormatter.apply(.excited, to: "1. Open the app\n2. Sign in.") == "1. Open the app\n2. Sign in!")
    #expect(StyleFormatter.apply(.excited, to: "See you at 5.") == "See you at 5!")
}

@Test func learningAndWordCountsIgnoreListMarkers() {
    let fixes = CorrectionLearner.corrections(from: "1. Kumr called\n2. Sam left", to: "Kumar called\nSam left")
    #expect(fixes == [LearnedCorrection(heard: "Kumr", corrected: "Kumar")])
    #expect(CorrectionLearner.corrections(from: "1. Call Sam\n2. Email Sam", to: "Call Sam. Email Sam.").isEmpty)
    let transcript = Transcript(text: "1. Call Sam\n- Email Sam", rawText: "call sam email sam", duration: 1, modelName: "test", language: "en")
    #expect(transcript.wordCount == 4)
}
