import Testing
@testable import BetterWisprCore

@Test(arguments: [
    "First of all, send the invoice. Second of all, book the room. Third of all, call Alex.",
    "Firstly, send the invoice. Secondly, book the room. Thirdly, call Alex.",
    "FIRST OF ALL: send the invoice. SECOND OF ALL: book the room. THIRD OF ALL: call Alex.",
    "First of all, send the invoice. Second of all, book the room. And third of all, call Alex.",
])
func explicitSpokenListsBecomeBullets(_ spoken: String) {
    #expect(TranscriptCleaner.clean(spoken, language: "en") == "- send the invoice.\n- book the room.\n- call Alex.")
}

@Test func spokenListsKeepIntroductionsWordingAndExistingFormatting() {
    let spoken = "Here is the plan: um first of all send the invoice, second of all book the room; third of all call Alex"
    let expected = "Here is the plan:\n\n- send the invoice\n- book the room\n- call Alex"
    #expect(TranscriptCleaner.clean(spoken, language: "en-GB") == expected)
    #expect(TranscriptCleaner.clean(expected, language: "en") == expected)
    #expect(TranscriptCleaner.clean("First of all: NASA uses iPhone. Second of all: is it ready?", language: "en")
            == "- NASA uses iPhone.\n- is it ready?")
    let bullets = TranscriptCleaner.clean("First of all buy milk second of all buy eggs", language: "en")
    #expect(bullets == "- buy milk\n- buy eggs")
    for tone in StyleTone.allCases {
        #expect(StyleFormatter.apply(tone, to: VoiceCommands.apply(bullets)).split(separator: "\n").count == 2)
    }
}

@Test(arguments: [
    "First of all, thank you for coming.",
    "The first invoice and the second invoice are ready.",
    "First of all send it. Third of all book it.",
    "Second of all send it. Third of all book it.",
    "First of all send it. First of all book it.",
    "First of all, second of all.",
    "First of all send it. Second of all.",
    "First of all-time records. Second of all-time records.",
])
func ambiguousOrIncompleteListsStayAsSpoken(_ spoken: String) {
    #expect(TranscriptCleaner.clean(spoken, language: "en") == spoken)
}

@Test func spokenListsRespectTheSelectedLanguage() {
    let spoken = "First of all send it. Second of all book it."
    #expect(TranscriptCleaner.clean(spoken, language: "fr") == spoken)
}

@Test func spokenListsRequireOneConsecutiveSequence() {
    let ordinals = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]
    let spoken = ordinals.map { "\($0) of all keep this item." }.joined(separator: " ")
    #expect(TranscriptCleaner.clean(spoken, language: "en") == Array(repeating: "- keep this item.", count: 10).joined(separator: "\n"))
    let restarted = spoken + " First of all keep another item."
    #expect(TranscriptCleaner.clean(restarted, language: "en") == restarted)
}
