import Foundation
import Testing
@testable import BetterWisprCore

@Test func personalTonesMatchTheirSamples() {
    let spoken = "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
    #expect(StyleFormatter.apply(.formal, to: spoken) == spoken)
    #expect(StyleFormatter.apply(.casual, to: spoken) == "Hey are you free for lunch tomorrow? Let's do 12 if that works for you")
    #expect(StyleFormatter.apply(.veryCasual, to: spoken) == "hey are you free for lunch tomorrow? let's do 12 if that works for you")
}

@Test func workAndEmailTonesMatchTheirSamples() {
    let work = "Hey, if you're free, let's chat about the great results."
    #expect(StyleFormatter.apply(.casual, to: work) == "Hey if you're free let's chat about the great results")
    #expect(StyleFormatter.apply(.excited, to: work) == "Hey, if you're free, let's chat about the great results!")
    let email = "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary"
    #expect(StyleFormatter.apply(.formal, to: email) == email)
    #expect(StyleFormatter.apply(.casual, to: email) == "Hi Alex, it was great talking with you today. Looking forward to our next chat.\n\nBest,\nMary")
    #expect(StyleFormatter.apply(.excited, to: email) == "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat!\n\nBest,\nMary")
    let other = "So far, I am enjoying the new workout routine.\n\nI am excited for tomorrow's workout, especially after a full night of rest."
    #expect(StyleFormatter.apply(.casual, to: other) == "So far I am enjoying the new workout routine.\n\nI am excited for tomorrow's workout especially after a full night of rest")
    #expect(StyleFormatter.apply(.excited, to: other).hasSuffix("full night of rest!"))
}

@Test func tonesKeepNumbersNamesAndEllipses() {
    #expect(StyleFormatter.apply(.casual, to: "It costs 1,200 dollars, sadly.") == "It costs 1,200 dollars sadly")
    #expect(StyleFormatter.apply(.veryCasual, to: "I met iPhone fans. NASA called. Kartik said hi") == "i met iPhone fans. NASA called. kartik said hi")
    #expect(StyleFormatter.apply(.excited, to: "Wait for it...") == "Wait for it...")
    #expect(StyleFormatter.apply(.excited, to: "Is it done?") == "Is it done?")
    #expect(StyleFormatter.apply(.casual, to: "See you at 5 p.m.") == "See you at 5 p.m.")
    #expect(StyleFormatter.apply(.excited, to: "Version 2.0") == "Version 2.0")
    #expect(StyleFormatter.apply(.casual, to: "Hi team,\n\nI shipped it.") == "Hi team, I shipped it")
}

@Test func vocabularyCountsOnlyChangedSpellings() {
    let entries = [VocabularyEntry(phrase: "cardic", replacement: "Kartik"), VocabularyEntry(phrase: "BetterWispr", replacement: "")]
    let result = VocabularyProcessor.corrected(entries, in: "cardic uses betterwispr and BetterWispr")
    #expect(result.text == "Kartik uses BetterWispr and BetterWispr")
    #expect(result.fixes == 2)
}

@Test func englishDetectionFollowsTheChosenLanguage() {
    #expect(TranscriptCleaner.isEnglish("Bonjour tout le monde", language: "en-US"))
    #expect(!TranscriptCleaner.isEnglish("Hello there", language: "fr"))
    #expect(!TranscriptCleaner.isEnglish("Bonjour à tous, je voudrais réserver une table pour ce soir.", language: nil))
}

@Test func styleSettingsDefaultToFormalAndLightCleanup() throws {
    let saved = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"parakeet-v3","showCapsule":true,"silenceThreshold":0.002}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
    #expect(settings.cleanup == .light)
    #expect(StyleContext.allCases.allSatisfy { settings.tone(for: $0) == .formal })
    settings.cleanup = .medium
    settings.styles[.personal] = .veryCasual
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.cleanup == .medium)
    #expect(restored.tone(for: .personal) == .veryCasual)
    #expect(restored.tone(for: .email) == .formal)
}

@Test func cleanupProviderFollowsNotesUntilChosenAndResetsWithItsConnection() throws {
    let legacy = #"{"autoPaste":true,"language":"auto","launchAtLogin":false,"saveHistory":true,"selectedModelID":"apple","showCapsule":true,"silenceThreshold":0.002,"notesModel":"llama3.1:8b"}"#
    var settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    #expect(settings.cleanupSelection == nil)
    settings.askSelection = .apple
    #expect(settings.cleanupSettings.notesSelection == .ollama("llama3.1:8b"))

    settings.cleanupSelection = .ollama("qwen3:4b")
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored == settings)
    #expect(restored.cleanupSettings.notesModelName == "Ollama · qwen3:4b")
    #expect(restored.notesSelection == .ollama("llama3.1:8b"))
    #expect(restored.askSettings.notesSelection == .apple)

    let unknown = legacy.dropLast() + #","cleanupSelection":{"telepathy":{}}}"#
    let fallback = try JSONDecoder().decode(AppSettings.self, from: Data(unknown.utf8))
    #expect(fallback.cleanupSelection == nil)
    #expect(fallback.notesSelection == .ollama("llama3.1:8b"))

    let removed = UUID()
    settings.cleanupSelection = .connection(removed)
    settings.deselectNotesConnection(removed)
    #expect(settings.cleanupSelection == nil)
    #expect(settings.notesSelection == .ollama("llama3.1:8b"))
}

@Test func transcriptsSavedBeforeAppTrackingStillLoad() throws {
    let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":0,"text":"Hi","rawText":"hi","duration":1,"modelName":"Parakeet","language":"auto"}"#
    let transcript = try JSONDecoder().decode(Transcript.self, from: Data(saved.utf8))
    #expect(transcript.appBundleID == nil)
    #expect(transcript.vocabularyFixes == nil)
}

@Test func appsMapToStyleContexts() {
    #expect(AppCategory(bundleID: "com.tinyspeck.slackmacgap").style == .work)
    #expect(AppCategory(bundleID: "net.whatsapp.WhatsApp").style == .personal)
    #expect(AppCategory(bundleID: "com.apple.mail").style == .email)
    #expect(AppCategory(bundleID: "com.openai.chat") == .aiPrompts)
    #expect(AppCategory(bundleID: "com.openai.chat").style == .other)
    #expect(AppCategory(bundleID: "com.apple.Safari") == .other)
    #expect(AppCategory(bundleID: nil) == .other)
}

@Test func insightsSummarizeHistory() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
    func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now) ?? now }
    let history = [
        Transcript(createdAt: daysAgo(1), text: "Kartik said hello there", rawText: "um cardic said hello hello there",
                   duration: 60, modelName: "m", language: "en", appBundleID: "com.tinyspeck.slackmacgap", vocabularyFixes: 1),
        Transcript(createdAt: daysAgo(2), text: "one two three four", rawText: "one two three four",
                   duration: 60, modelName: "m", language: "en", appBundleID: "com.openai.chat"),
        Transcript(createdAt: daysAgo(5), text: "a b c d e f", rawText: "a b c d e f", duration: 60, modelName: "m", language: "en", appBundleID: "com.openai.chat"),
        Transcript(createdAt: daysAgo(6), text: "a b", rawText: "a b", duration: 60, modelName: "m", language: "en"),
        Transcript(createdAt: daysAgo(7), text: "a b", rawText: "a b", duration: 60, modelName: "m", language: "en"),
    ]
    let insights = UsageInsights(history, calendar: calendar, now: now)
    #expect(insights.current == UsageTotals(words: 18, dictations: 5, speakingTime: 300))
    #expect(insights.current.wordsPerMinute == 4)
    #expect(insights.previous == nil)
    #expect(insights.wordsCleaned == 3)
    #expect(insights.mostRemoved.map(\.word) == ["cardic", "hello", "um"])
    #expect(insights.vocabularyFixes == 1)
    #expect(insights.apps.map(\.bundleID) == ["com.openai.chat", "com.tinyspeck.slackmacgap"])
    #expect(insights.apps.map(\.words) == [10, 4])
    #expect(insights.dictationsWithoutApp == 2)
    #expect(insights.wordsByHour[12] == 18)
    #expect(insights.granularity == .day)
    #expect(insights.activity.count == 8)
    #expect(insights.currentStreak == 2)
    #expect(insights.longestStreak == 3)

    let week = UsageInsights(history, period: .week, calendar: calendar, now: now)
    #expect(week.current == UsageTotals(words: 16, dictations: 4, speakingTime: 240))
    #expect(week.previous == UsageTotals(words: 2, dictations: 1, speakingTime: 60))
    #expect(week.activity.map(\.words) == [2, 6, 0, 0, 4, 4, 0])
    #expect(week.activeDays == 4)
    #expect(week.dictationsWithoutApp == 1)

    let old = Transcript(createdAt: daysAgo(200), text: "a", rawText: "a", duration: 1, modelName: "m", language: "en")
    #expect(UsageInsights(history + [old], calendar: calendar, now: now).granularity == .month)
    #expect(UsageTotals(words: 520, dictations: 1, speakingTime: 60).timeSaved == 540)
    #expect(UsageInsights(history, calendar: calendar, now: daysAgo(-2)).currentStreak == 0)
    #expect(UsageInsights([], calendar: calendar, now: now) == UsageInsights([], calendar: calendar, now: now))
}

@Test func polishRejectsRepliesThatAreNotEdits() {
    let question = "So um what time does the the meeting start tomorrow?"
    #expect(TranscriptPolisher.accepted("What time does the meeting start tomorrow?", for: question) == "What time does the meeting start tomorrow?")
    #expect(TranscriptPolisher.accepted("“What time does the meeting start tomorrow?”", for: question) == "What time does the meeting start tomorrow?")
    #expect(TranscriptPolisher.accepted("The meeting starts at 10 AM.", for: question) == nil)
    #expect(TranscriptPolisher.accepted("I can't tell you what time the meeting starts because I don't have access to your calendar, but you could check it.", for: question) == nil)
    #expect(TranscriptPolisher.accepted("Paris is the capital of France.", for: "what is the capital of France") == nil)
    #expect(TranscriptPolisher.accepted("What is the capital of France?", for: "what is the capital of France") == "What is the capital of France?")
    let plan = "okay so for the launch on Friday Priya is going to send the checklist by 5 pm and I think we need to double check the pricing page"
    #expect(TranscriptPolisher.accepted("For the Friday launch, Priya will send the checklist by 5 PM. We need to double-check the pricing page.", for: plan) != nil)
    #expect(TranscriptPolisher.accepted("Here's the edited text:\n\nPriya sends the checklist at 6 PM, and we should review the pricing page.", for: plan) == nil)
}
