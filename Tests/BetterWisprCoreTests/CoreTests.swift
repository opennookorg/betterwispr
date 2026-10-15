import Foundation
import Testing
@testable import BetterWisprCore

@Test func vocabularyUsesWholeWordsAndNeverCascades() {
    let entries = [VocabularyEntry(phrase: "better whisper", replacement: "BetterWispr"),
                   VocabularyEntry(phrase: "BetterWispr", replacement: "wrong"),
                   VocabularyEntry(phrase: "café", replacement: "Café"),
                   VocabularyEntry(phrase: "cat", replacement: "$1\\dog")]
    #expect(VocabularyProcessor.apply(entries, to: "better whisper at café, not cafés. cat scatter")
            == "BetterWispr at Café, not cafés. $1\\dog scatter")
    #expect(VocabularyProcessor.apply([.init(phrase: "ह", replacement: "wrong")], to: "हिंदी") == "हिंदी")
}

@Test func workspaceRoundTripsAndRefusesCorruptData() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    #expect(try store.load() == SavedState())
    var state = SavedState()
    state.settings.showInDock = true
    state.history = [Transcript(text: "Hello", rawText: "hello", duration: 2, modelName: "Test", language: "en")]
    try store.save(state)
    #expect(try store.load() == state)
    try Data("broken".utf8).write(to: store.stateURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try String(contentsOf: store.stateURL, encoding: .utf8) == "broken")
}

@Test func settingsSavedBeforeDictationModesStillLoad() throws {
    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
    #expect(settings.selectedModelID == "parakeet-v3")
    #expect(settings.dictationMode == .hold)
    #expect(settings.unloadModelWhenIdle == .never)
    #expect(!settings.copyToClipboard)
    #expect(settings.soundEffects)
    #expect(!settings.pauseMediaWhileDictating)
    #expect(!settings.showInDock)
    #expect(settings.theme == .dark)
    #expect(settings.shortcut == .optionSpace)
    #expect(settings.cancelShortcut == nil)
    #expect(settings.selectedTextShortcut == nil)
    #expect(settings.microphone == nil)
    #expect(settings.completedOnboardingVersion == 0)
    #expect(settings.onboardingStep == 0)
    var toggled = settings
    toggled.dictationMode = .toggle
    toggled.unloadModelWhenIdle = .fifteenMinutes
    toggled.completedOnboardingVersion = 1
    toggled.onboardingStep = 2
    toggled.copyToClipboard = true
    toggled.soundEffects = false
    toggled.pauseMediaWhileDictating = true
    toggled.showInDock = true
    toggled.theme = .system
    toggled.microphone = AudioInputDevice(id: "AppleUSBAudioEngine:Shure:MV7:1", name: "Shure MV7")
    toggled.cancelShortcut = DictationShortcut(keyCode: 53, modifiers: .control, key: "Esc")
    toggled.selectedTextShortcut = DictationShortcut(keyCode: 8, modifiers: [.control, .option], key: "C")
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(toggled)) == toggled)
}

@Test func microphoneIsTheChosenDeviceWhileConnectedOtherwiseTheMacOSDefaultIncludingBluetooth() {
    let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    let airPods = AudioInputDevice(id: "AA-BB-CC:input", name: "Kartik AirPods Pro")
    let headset = AudioInputDevice(id: "DD-EE-FF:input", name: "Sony WH-1000XM5")
    let usb = AudioInputDevice(id: "AppleUSBAudioEngine:Shure:MV7:1", name: "Shure MV7")
    let iPhone = AudioInputDevice(id: "iPhone-continuity", name: "iPhone Microphone")
    let renamed = AudioInputDevice(id: airPods.id, name: "Kartik’s AirPods")
    func resolve(_ choice: AudioInputDevice?, _ connected: [AudioInputDevice], default systemDefault: AudioInputDevice?) -> AudioInputDevice? {
        AudioInputs.resolve(choice, inputs: connected.map { AudioInputs.Input(device: $0) }, systemDefault: systemDefault)
    }
    #expect(resolve(nil, [iPhone, usb, airPods, builtIn], default: airPods) == airPods)
    #expect(resolve(nil, [builtIn, airPods, headset], default: headset) == headset)
    #expect(resolve(nil, [builtIn, airPods, usb], default: usb) == usb)
    #expect(resolve(nil, [builtIn, airPods, iPhone], default: iPhone) == iPhone)
    #expect(resolve(airPods, [builtIn, headset], default: headset) == headset)
    #expect(resolve(usb, [builtIn, airPods], default: airPods) == airPods)
    #expect(resolve(airPods, [builtIn], default: builtIn) == builtIn)
    #expect(resolve(airPods, [builtIn, airPods], default: builtIn) == airPods)
    #expect(resolve(airPods, [builtIn, airPods, headset], default: headset) == airPods)
    #expect(resolve(builtIn, [builtIn, airPods], default: airPods) == builtIn)
    #expect(resolve(airPods, [builtIn, renamed], default: builtIn) == renamed)
    #expect(resolve(nil, [builtIn, airPods], default: nil) == nil)
    #expect(resolve(usb, [builtIn, airPods], default: nil) == nil)
}

@Test func shortcutsValidateKeysAndRoundTripThroughSettings() throws {
    #expect(DictationShortcut.optionSpace.displayName == "⌥ Space")
    #expect(DictationShortcut.optionSpace.spokenName == "Option Space")
    let everything = try #require(DictationShortcut(keyCode: 40, modifiers: [.command, .shift, .option, .control], key: "K"))
    #expect(everything.displayName == "⌃⌥⇧⌘ K")
    #expect(everything.spokenName == "Control Option Shift Command K")
    #expect(DictationShortcut(keyCode: 2, modifiers: .shift, key: "D") == nil)
    #expect(DictationShortcut(keyCode: 2, modifiers: [], key: "D") == nil)
    #expect(DictationShortcut(keyCode: 2, modifiers: .control, key: "") == nil)
    #expect(DictationShortcut(keyCode: 96, modifiers: [], key: "F5")?.displayName == "F5")
    #expect(DictationShortcut(keyCode: 96, modifiers: .shift, key: "F5")?.spokenName == "Shift F5")
    #expect(ShortcutModifiers([.option, .control]).symbols == "⌃⌥")

    var settings = AppSettings()
    settings.shortcut = try #require(DictationShortcut(keyCode: 2, modifiers: [.control, .shift], key: "D"))
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.shortcut == settings.shortcut)
    #expect(decoded.shortcut.displayName == "⌃⇧ D")
    let functionKey = try JSONDecoder().decode(DictationShortcut.self, from: Data(#"{"keyCode":96,"modifiers":0,"key":"F5"}"#.utf8))
    #expect(functionKey.displayName == "F5")
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(DictationShortcut.self, from: Data(#"{"keyCode":2,"modifiers":512,"key":"D"}"#.utf8))
    }
}

@Test(arguments: [54, 55, 56, 58, 59, 60, 61, 62, 63])
func standaloneModifiersRoundTripThroughSettings(keyCode: UInt32) throws {
    var settings = AppSettings()
    settings.shortcut = try #require(DictationShortcut(keyCode: keyCode, modifiers: [], key: "Modifier"))
    #expect(settings.shortcut.isModifierOnly)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    #expect(DictationShortcut(keyCode: keyCode, modifiers: .option, key: "Modifier") == nil)
    #expect(!DictationShortcut.optionSpace.isModifierOnly)
}

@Test func cleanerDropsMidSentenceFillersAndKeepsPrecedingPunctuation() {
    #expect(TranscriptCleaner.clean("The tests passed, uh, so merge it um now", language: "en")
            == "The tests passed, so merge it now")
    #expect(TranscriptCleaner.clean("Rename the file uh, then reload the hmm window", language: "en")
            == "Rename the file then reload the window")
    #expect(TranscriptCleaner.clean("and uh uh we can build um the export", language: "en") == "and we can build the export")
}

@Test func cleanerCapitalizesAfterSentenceInitialFiller() {
    #expect(TranscriptCleaner.clean("Can you check the logs? um yes, and the tests too.", language: "en")
            == "Can you check the logs? Yes, and the tests too.")
    #expect(TranscriptCleaner.clean("uh iPhone builds are slow", language: "en") == "iPhone builds are slow")
}

@Test func cleanerMovesTerminalPunctuationFromFiller() {
    #expect(TranscriptCleaner.clean("We are done for today uh.", language: "en") == "We are done for today.")
    #expect(TranscriptCleaner.clean("Is the build ready um?", language: "en") == "Is the build ready?")
}

@Test func cleanerDropsMmFillers() {
    #expect(TranscriptCleaner.clean("mm I think so", language: "en") == "I think so")
    #expect(TranscriptCleaner.clean("Mm, that works.", language: "en") == "That works.")
    #expect(TranscriptCleaner.clean("We could, mmm, try it", language: "en") == "We could, try it")
    #expect(TranscriptCleaner.clean("mm-hmm, that sounds right", language: "en") == "mm-hmm, that sounds right")
    #expect(TranscriptCleaner.clean("Cut it to 5 mm, mm, thanks", language: "en") == "Cut it to 5 mm, thanks")
}

@Test func cleanerDropsYouKnowOnlyWhenSetOffOnBothSides() {
    #expect(TranscriptCleaner.clean("It was, you know, fine.", language: "en") == "It was fine.")
    #expect(TranscriptCleaner.clean("You know, I think so.", language: "en") == "I think so.")
    #expect(TranscriptCleaner.clean("That is what I want, you know.", language: "en") == "That is what I want.")
    #expect(TranscriptCleaner.clean("It works. You know, it is fast.", language: "en") == "It works. It is fast.")
    #expect(TranscriptCleaner.clean("That is what I want, you know", language: "en") == "That is what I want")
}

@Test func cleanerKeepsYouKnowThatIsNotSetOff() {
    #expect(TranscriptCleaner.clean("You know the answer.", language: "en") == "You know the answer.")
    #expect(TranscriptCleaner.clean("Do you know, honestly?", language: "en") == "Do you know, honestly?")
    #expect(TranscriptCleaner.clean("If you know, tell me.", language: "en") == "If you know, tell me.")
    #expect(TranscriptCleaner.clean("Well, you know what I mean.", language: "en") == "Well, you know what I mean.")
    #expect(TranscriptCleaner.clean("It is hard, you know?", language: "en") == "It is hard, you know?")
    #expect(TranscriptCleaner.clean("Do you know?", language: "en") == "Do you know?")
    #expect(TranscriptCleaner.clean("Tuesday, I mean, Wednesday", language: "en") == "Tuesday, I mean, Wednesday")
    #expect(TranscriptCleaner.clean("Du weißt, you know, es ist gut.", language: "de") == "Du weißt, you know, es ist gut.")
}

@Test func cleanerResolvesSelfCorrectionsThatRepeatAWord() {
    #expect(TranscriptCleaner.clean("So let's say I say this sentence uh I want to go to uh Mdabad, sorry, no to Dilli. Are we processing this properly", language: "en")
            == "So let's say I say this sentence I want to go to Dilli. Are we processing this properly")
    #expect(TranscriptCleaner.clean("I want to go to Ahmedabad, sorry, no, to Delhi.", language: "en") == "I want to go to Delhi.")
    #expect(TranscriptCleaner.clean("Let's meet at 5, no wait, at 6", language: "en") == "Let's meet at 6")
    #expect(TranscriptCleaner.clean("Let's meet at 5, no, at 6 pm.", language: "en") == "Let's meet at 6 pm.")
    #expect(TranscriptCleaner.clean("Send it to Sam, no, send it to Alex.", language: "en") == "Send it to Alex.")
    #expect(TranscriptCleaner.clean("Book the window seat, I mean, the aisle seat", language: "en") == "Book the aisle seat")
    #expect(TranscriptCleaner.clean("I live in Ahmedabad, sorry, in Delhi.", language: "en") == "I live in Delhi.")
    #expect(TranscriptCleaner.clean("I live in Ahmedabad sorry in Delhi", language: "en") == "I live in Delhi")
    #expect(TranscriptCleaner.clean("Let's meet at 5 sorry at 6.", language: "en") == "Let's meet at 6.")
    #expect(TranscriptCleaner.clean("Hey, I live in Delhi uh no sorry I live in Ahmedabad.", language: "en") == "Hey, I live in Ahmedabad.")
    #expect(TranscriptCleaner.clean("I live in Pune, sorry, no, I live in Delhi.", language: "en") == "I live in Delhi.")
}

@Test func cleanerKeepsCorrectionLookalikes() {
    #expect(TranscriptCleaner.clean("I said yes to the plan, no to the budget.", language: "en") == "I said yes to the plan, no to the budget.")
    #expect(TranscriptCleaner.clean("I can't make it, sorry, I have a meeting.", language: "en") == "I can't make it, sorry, I have a meeting.")
    #expect(TranscriptCleaner.clean("Should we go, no, we should stay.", language: "en") == "Should we go, no, we should stay.")
    #expect(TranscriptCleaner.clean("I said no sorry I can't come.", language: "en") == "I said no sorry I can't come.")
    #expect(TranscriptCleaner.clean("We booked at noon and had no wait at all.", language: "en") == "We booked at noon and had no wait at all.")
    #expect(TranscriptCleaner.clean("Is it at 5? No, at 6.", language: "en") == "Is it at 5? No, at 6.")
    #expect(TranscriptCleaner.clean("We read it in the last book, no, the whole thing with the houses was different.", language: "en")
            == "We read it in the last book, no, the whole thing with the houses was different.")
    #expect(TranscriptCleaner.clean("It was the closest to like, I mean, the first one was obviously very close, but not the second.", language: "en")
            == "It was the closest to like, I mean, the first one was obviously very close, but not the second.")
    #expect(TranscriptCleaner.clean("Thanks for coming, sorry for the wait.", language: "en") == "Thanks for coming, sorry for the wait.")
    #expect(TranscriptCleaner.clean("Go to Ahmedabad, sorry, no, Delhi", language: "en") == "Go to Ahmedabad, sorry, no, Delhi")
    #expect(TranscriptCleaner.clean("Thanks for coming sorry for the wait.", language: "en") == "Thanks for coming sorry for the wait.")
    #expect(TranscriptCleaner.clean("We need to talk, sorry to interrupt.", language: "en") == "We need to talk, sorry to interrupt.")
    #expect(TranscriptCleaner.clean("I asked about it sorry about that.", language: "en") == "I asked about it sorry about that.")
    #expect(TranscriptCleaner.clean("I'm in the office so sorry in advance.", language: "en") == "I'm in the office so sorry in advance.")
    #expect(TranscriptCleaner.clean("I'll be in the office late sorry in advance.", language: "en") == "I'll be in the office late sorry in advance.")
    #expect(TranscriptCleaner.clean("I missed the call, sorry, the train was late.", language: "en") == "I missed the call, sorry, the train was late.")
    #expect(TranscriptCleaner.clean("Thanks for the help everyone sorry the call ran late.", language: "en") == "Thanks for the help everyone sorry the call ran late.")
}

@Test func cleanerRemovesRepeatedPhrases() {
    #expect(TranscriptCleaner.clean("Then we can we can deploy the app", language: "en") == "Then we can deploy the app")
    #expect(TranscriptCleaner.clean("I want to I want to fix the login bug", language: nil) == "I want to fix the login bug")
    #expect(TranscriptCleaner.clean("and then and then we shipped it", language: "en") == "and then we shipped it")
}

@Test func cleanerKeepsFirstCopyOfStutteredWord() {
    #expect(TranscriptCleaner.clean("We we should test it", language: "en") == "We should test it")
    #expect(TranscriptCleaner.clean("I I I think so", language: "en") == "I think so")
}

@Test func cleanerKeepsDeliberateRepeats() {
    #expect(TranscriptCleaner.clean("Hello, hello, hello, is this on?", language: "en") == "Hello, hello, hello, is this on?")
    #expect(TranscriptCleaner.clean("I know that that works", language: "en") == "I know that that works")
    #expect(TranscriptCleaner.clean("a long long time ago", language: "en") == "a long long time ago")
    #expect(TranscriptCleaner.clean("call 5 5 5 now", language: "en") == "call 5 5 5 now")
    #expect(TranscriptCleaner.clean("dial one one two", language: "en") == "dial one one two")
    #expect(TranscriptCleaner.clean("in twenty twenty five, a fifty fifty split", language: "en") == "in twenty twenty five, a fifty fifty split")
    #expect(TranscriptCleaner.clean("uh-huh, that sounds right", language: "en") == "uh-huh, that sounds right")
    #expect(TranscriptCleaner.clean("drinking more and more and more", language: "en") == "drinking more and more and more")
    #expect(TranscriptCleaner.clean("we tried again and again and again", language: "en") == "we tried again and again and again")
}

@Test func cleanerLeavesOtherLanguagesAndEmptiesFillerOnlyText() {
    #expect(TranscriptCleaner.clean(" Wir treffen uns um acht Uhr ", language: "de") == "Wir treffen uns um acht Uhr")
    #expect(TranscriptCleaner.clean("uh, um... hmm", language: "en") == "")
    #expect(TranscriptCleaner.clean("Uh, um.", language: nil) == "")
    #expect(TranscriptCleaner.clean("Wir treffen uns um acht Uhr", language: nil) == "Wir treffen uns um acht Uhr")
    #expect(TranscriptCleaner.clean("", language: "en") == "")
}

@Test func emailDictationLaysOutGreetingBodyAndSignOff() {
    #expect(EmailDictation.compose("Write an email to Sarah saying I will be on holiday tomorrow. Thanks. Best regards, Cardic.")
        == "Hi Sarah,\n\nI will be on holiday tomorrow. Thanks.\n\nBest regards,\nCardic")
    #expect(EmailDictation.compose("Draft an email to John that the report is ready, kind regards, cardic.")
        == "Hi John,\n\nThe report is ready.\n\nKind regards,\nCardic")
    #expect(EmailDictation.compose("write an email to priya patel saying that the deploy is done") == "Hi Priya Patel,\n\nThe deploy is done.")
    #expect(EmailDictation.compose("Write an email to the team, saying lunch is at noon. Cheers, Kartik.") == "Hi Team,\n\nLunch is at noon.\n\nCheers,\nKartik")
    #expect(EmailDictation.compose("Write an email to Sam saying I'm out today. Thanks.") == "Hi Sam,\n\nI'm out today.\n\nThanks")
    #expect(EmailDictation.compose("Write an email to Sam saying thanks.") == "Hi Sam,\n\nThanks.")
    #expect(EmailDictation.compose("Write an email to Sam saying I'm out. Thanks, see you soon.") == "Hi Sam,\n\nI'm out. Thanks, see you soon.")
}

@Test func emailDictationIgnoresOrdinaryDictation() {
    #expect(EmailDictation.compose("I will write an email to Sarah saying I'm late.") == nil)
    #expect(EmailDictation.compose("Write an email to Sarah.") == nil)
    #expect(EmailDictation.compose("Send the report to Sarah saying it is done.") == nil)
    #expect(EmailDictation.compose("I live in Delhi.") == nil)
}

@Test func voiceCommandsInsertPunctuationAndBacktrack() {
    #expect(VoiceCommands.apply("hello comma world") == "hello, world")
    #expect(VoiceCommands.apply("Hello, comma, how are you") == "Hello, how are you")
    #expect(VoiceCommands.apply("thanks add a comma see you soon") == "thanks, see you soon")
    #expect(VoiceCommands.apply("is it done question mark") == "is it done?")
    #expect(VoiceCommands.apply("first new line second") == "first\nSecond")
    #expect(VoiceCommands.apply("Send it Monday. Sorry, remove that. Send it Tuesday.") == "Send it Tuesday.")
    #expect(VoiceCommands.apply("Let's meet at 5, sorry, remove that, let's meet at 6") == "Let's meet at 6")
    #expect(VoiceCommands.apply("Hi team. Ship it today scratch that tomorrow") == "Hi team. Tomorrow")
    #expect(VoiceCommands.apply("Please remove that file") == "Please remove that file")
    #expect(VoiceCommands.apply("I love the Oxford comma") == "I love the Oxford comma")
    #expect(VoiceCommands.apply("the period ended") == "the period ended")
    #expect(VoiceCommands.apply("Exclamatory mark.") == "!")
    #expect(VoiceCommands.apply("Hyphen.") == "-")
    #expect(VoiceCommands.apply("colon") == ":")
    #expect(VoiceCommands.apply("dash") == "–")
}

@Test func vocabularyTeachesMisheardVoiceCommands() {
    let entries = [VocabularyEntry(phrase: "Kocia Mark", replacement: "question mark"),
                   VocabularyEntry(phrase: "Hai fun", replacement: "hyphen"),
                   VocabularyEntry(phrase: "Coma", replacement: "comma"),
                   VocabularyEntry(phrase: "at the Red", replacement: "at the rate"),
                   VocabularyEntry(phrase: "twenty one pilots", replacement: "Twenty One Pilots"),
                   VocabularyEntry(phrase: "jurassic pyramid", replacement: "Jurassic Period"),
                   VocabularyEntry(phrase: "better whisper", replacement: "BetterWispr"),
                   VocabularyEntry(phrase: "Kubernetes", replacement: "")]
    let dictated = [
        "Kocia Mark.": "?",
        "Hai fun.": "-",
        "Hi, Coma, how are you doing?": "Hi, how are you doing?",
        "Hey, at the Red Harsh Gupta.": "Hey, @Harsh Gupta.",
        "I love the jurassic pyramid": "I love the jurassic pyramid",
    ]
    for (heard, written) in dictated {
        #expect(VoiceCommands.apply(VocabularyProcessor.correctedCommands(entries, in: heard).text) == written)
    }
    #expect(VocabularyProcessor.correctedCommands(entries, in: "Hi, Coma, Kocia Mark").fixes == 2)
    #expect(VocabularyProcessor.hints(entries) == ["Twenty One Pilots", "Jurassic Period", "BetterWispr", "Kubernetes"])
    #expect(!VoiceCommands.isSpokenCommand("") && !VoiceCommands.isSpokenCommand("42") && !VoiceCommands.isSpokenCommand("BetterWispr"))
    #expect(VoiceCommands.isSpokenCommand("new line") && VoiceCommands.isSpokenCommand("hash forty two"))
}

@Test func voiceCommandsTurnAtTheRateIntoMentions() {
    #expect(VoiceCommands.apply("ping at the rate KV about it") == "ping @KV about it")
    #expect(VoiceCommands.apply("ask at sign Sam") == "ask @Sam")
    #expect(VoiceCommands.apply("growing at the rate of 5 percent") == "growing at the rate of 5%")
}

@Test func voiceCommandsWriteSpokenNumbersAsDigits() {
    let expected = [
        "The budget is two hundred and fifty thousand dollars.": "The budget is 250,000 dollars.",
        "We have one hundred people and two hundred chairs.": "We have 100 people and 200 chairs.",
        "one hundred or two hundred": "100 or 200",
        "one hundred and two hundred": "100 and 200",
        "from zero to twenty seven": "from zero to 27",
        "twenty-seven": "27",
        "Two hundred people came.": "200 people came.",
        "It cost two hundred.": "It cost 200.",
        "I waited ten minutes": "I waited 10 minutes",
        "one thousand two hundred": "1200",
        "two thousand twenty six": "2026",
        "one million two hundred thousand": "1,200,000",
        "five million": "5 million",
        "two point five million": "2.5 million",
        "The value is three point five.": "The value is 3.5.",
        "Update the changelog for zero point one point one.": "Update the changelog for 0.1.1.",
        "a hundred and fifty": "150",
        "It has one hundred K views.": "It has 100K views.",
        "Growth was ten percent this year, almost twenty five percentage.": "Growth was 10% this year, almost 25%.",
        "five percent": "5%",
        "5 percent": "5%",
        "5 per cent": "5%",
        "fifty percent.": "50%.",
        "twenty, thirty": "20, 30",
        "I have one lakh followers.": "I have 1 lakh followers.",
        "The flat costs fifty lakhs.": "The flat costs 50 lakhs.",
        "We raised two lakh fifty thousand rupees.": "We raised 2,50,000 rupees.",
        "The budget is one crore twenty lakh.": "The budget is 1,20,00,000.",
        "Revenue was two point five crore.": "Revenue was 2.5 crore.",
        "It costs twelve hundred dollars.": "It costs 1200 dollars.",
        "twenty five hundred": "2500",
        "I have over ten thousand hundred followers.": "I have over 10,000 hundred followers.",
        "Ten thousand one lakh.": "10,000 1 lakh.",
        "five thousand million": "5000 million",
    ]
    for (spoken, written) in expected {
        #expect(VoiceCommands.apply(spoken) == written)
    }
    let unchanged = [
        "one of them", "no one", "at one point we", "two or three", "give me five minutes", "at one point we left",
        "a hundred times", "a thousand thanks", "what percentage of users", "nineteen ninety nine", "fifty fifty",
        "eleven thirty", "twenty first century", "call 5 5 5 now",
    ]
    for text in unchanged {
        #expect(VoiceCommands.apply(text) == text)
    }
}

@Test func voiceCommandsWriteSpokenSymbols() {
    let expected = [
        "Ping at the rate K V about it.": "Ping @KV about it.",
        "At the rate k v.": "@kv.",
        "At the rate.": "@",
        "at sign": "@",
        "at symbol": "@",
        "Send it to kartik at the rate gmail dot com.": "Send it to kartik@gmail.com.",
        "Send it to Kardich at the rategmail.com.": "Send it to Kardich@gmail.com.",
        "Send it to Kardak at the rategmail. com": "Send it to Kardak@gmail.com",
        "visit example dot com": "visit example.com",
        "Book it on mysite dot in.": "Book it on mysite.in.",
        "Post it with hashtag launch day.": "Post it with #launch day.",
        "hash tag launch": "#launch",
        "Check issue hash forty two.": "Check issue #42.",
        "Hash.": "#",
        "Hashtag.": "#",
        "hash sign": "#",
        "hash symbol": "#",
        "Percentage.": "%",
        "Percent.": "%",
        "percent sign": "%",
        "percentage sign": "%",
    ]
    for (spoken, written) in expected {
        #expect(VoiceCommands.apply(spoken) == written)
    }
    for text in [
        "the interest at the rate is high", "the dot com bubble", "a red dot in the corner",
        "Sales fell. Net income rose.",
        "We need to hash out a plan using a hash map.",
    ] {
        #expect(VoiceCommands.apply(text) == text)
    }
}

@Test func correctionLearnerKeepsVocabularyFixesOnly() {
    #expect(CorrectionLearner.corrections(from: "Thanks kumr, see you", to: "Thanks Kumar, see you")
            == [LearnedCorrection(heard: "kumr", corrected: "Kumar")])
    #expect(CorrectionLearner.corrections(from: "try assist able today", to: "try Assistable today")
            == [LearnedCorrection(heard: "assist able", corrected: "Assistable")])
    #expect(CorrectionLearner.corrections(from: "ask kv about it", to: "ask KV about it")
            == [LearnedCorrection(heard: "kv", corrected: "KV")])
    #expect(CorrectionLearner.corrections(from: "why is it late", to: "what is it late").isEmpty)
    #expect(CorrectionLearner.corrections(from: "hello there", to: "hello there!").isEmpty)
    #expect(CorrectionLearner.corrections(from: "send the report today", to: "please call me tomorrow instead").isEmpty)
}

@Test func oneFixToRealParakeetOutputCorrectsTheNextDictation() {
    let heard = "I dictate with better whisper and then paste it into cloud code. Open the superbase dashboard and check the post hog events."
    let fixed = "I dictate with BetterWispr and then paste it into Claude Code. Open the Supabase dashboard and check the PostHog events."
    let learned = CorrectionLearner.corrections(from: heard, to: fixed)
    #expect(learned.map(\.corrected) == ["BetterWispr", "Claude Code", "Supabase", "PostHog"])
    let entries = learned.map { VocabularyEntry(phrase: $0.heard, replacement: $0.corrected, learned: true) }
    #expect(VocabularyProcessor.corrected(entries, in: heard) == (fixed, 4))
    #expect(VocabularyProcessor.apply(entries, to: "Store it in the cloud and review the code.") == "Store it in the cloud and review the code.")
}

@Test func olderWorkspaceDecodesLearningFieldsWithDefaults() throws {
    let entry = try JSONDecoder().decode(VocabularyEntry.self, from: Data(#"{"id":"\#(UUID().uuidString)","phrase":"kv","replacement":"KV"}"#.utf8))
    #expect(entry.learned == false)
    var settings = try jsonDroppingKey(AppSettings(), "learnCorrections")
    #expect(try JSONDecoder().decode(AppSettings.self, from: settings).learnCorrections)
    settings = try JSONEncoder().encode(VocabularyEntry(phrase: "kv", replacement: "KV", learned: true))
    #expect(try JSONDecoder().decode(VocabularyEntry.self, from: settings).learned)
}

@Test func workspaceSavedBeforeTheCancelShortcutDecodesItAsNone() throws {
    let legacy = try jsonDroppingKey(AppSettings(), "cancelShortcut")
    #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).cancelShortcut == nil)
}

private func jsonDroppingKey(_ value: some Encodable, _ key: String) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    object[key] = nil
    return try JSONSerialization.data(withJSONObject: object)
}

@Test func correctionWatcherReadsTheDictationUpToItsUnchangedNeighbours() {
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "Hi. ping kv now", to: "Hi. ping KV now") == "ping KV now")
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "Hi. ping kv now", to: "Hey. ping kv now") == nil)
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "ping kv now", to: "ping kv now please") == "ping kv now please")
}

@Test func correctionWatcherLearnsSettledOrSentTextOnly() {
    var typing = SettledText("cloud code")
    #expect(["Claude Co", "Claude Co", "Claude Co", "Claude Code"].compactMap { typing.observe($0) }.isEmpty)
    #expect(["Claude Code", "Claude Code", "Claude Code"].compactMap { typing.observe($0) }.isEmpty)
    #expect(typing.observe("Claude Code") == "Claude Code")
    #expect(typing.observe("Claude Code") == nil)

    var sent = SettledText("cloud code")
    #expect(sent.observe("Claude Code") == nil)
    #expect(sent.observe("Claude Code") == nil)
    #expect(sent.observe("") == "Claude Code")

    var rushed = SettledText("cloud code")
    #expect(rushed.observe("Claude Cod") == nil)
    #expect(rushed.observe("") == nil)
}
