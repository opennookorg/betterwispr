import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

private let original = "Ask Prakash Joshi Pages to grab the post hog numbers today"
private let edited = "Ask Prakash Joshi Pax to grab the PostHog numbers today"
private let candidates = [LearnedCorrection(heard: "Pages", corrected: "Pax"), LearnedCorrection(heard: "post hog", corrected: "PostHog")]
private let rejectSecond = #"{"candidateID":1,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}"#

private func review(_ reply: String) -> [CorrectionDecision]? {
    CorrectionReviewer.parse(reply: reply, candidates: candidates, original: original, edited: edited)
}

private func replacing(_ heard: String, with corrected: String, action: String = "addReplacementOnly") -> String {
    #"[{"candidateID":0,"learningAction":"\#(action)","incorrectTextToReplace":"\#(heard)","correctedVocabularyTerm":"\#(corrected)"}]"#
}

@Test func correctionWatcherFindsTheDictationBetweenUniqueAnchors() {
    let before = "Dear team, as discussed earlier today: ping kv now. Thanks so much for the help, Sam"
    let after = "Dear crew, as discussed earlier today: ping KV now. Thanks so much for the help, Samantha"
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: before, to: after) == "ping KV now")
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "Status update: ping kv now", to: "Status update: ping KV now. Status update: done") == nil)
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "ping kv now, see you soon", to: "ping KV now, see you soon, see you soon") == nil)
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "left ping kv now right", to: " right then left again") == nil)
}

@Test func correctionWatcherTreatsAMissingSideAsTheFieldBoundary() {
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "ping kv now and then reply to Sam", to: "ping KV now and then reply to Sam") == "ping KV now")
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "ping kv now and then reply to Sam", to: "Hi, ping KV now and then reply to Sam") == "Hi, ping KV now")
    #expect(CorrectionWatcher.edit(of: "ping kv now", from: "Reply to Sam: ping kv now", to: "Reply to Sam: ping KV now") == "ping KV now")
}

@Test func correctionWatcherComparesFieldTextTheWayItWasPasted() {
    let field = CorrectionWatcher.comparable("  ping\u{00A0}kv\r\nnow\u{200B}\u{FEFF}\u{2028} \t\nthen cafe\u{0301}  ")
    #expect(field == "ping kv\nnow\n\nthen café")
    #expect(field.unicodeScalars.last == "\u{00E9}")
    #expect(CorrectionWatcher.comparable("ping\u{00A0}kv now\r") == CorrectionWatcher.comparable("ping kv now"))
}

@Test func correctionReviewKeepsValidDecisionsInCandidateOrder() {
    #expect(review(#"[{"candidateID":1,"learningAction":"addReplacementOnly","incorrectTextToReplace":"post hog","correctedVocabularyTerm":"PostHog"},{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"Prakash Joshi Pages","correctedVocabularyTerm":"Prakash Joshi Pax"}]"#)
        == [.replacementAndVocabulary(heard: "Prakash Joshi Pages", corrected: "Prakash Joshi Pax"), .replacementOnly(heard: "post hog", corrected: "PostHog")])
    #expect(review(#"[{"candidateID":0,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":1,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":" PostHog "}]"#)
        == [.reject, .vocabularyOnly("PostHog")])
}

@Test func correctionReviewReadsAFencedReply() {
    let reply = #"[{"candidateID":0,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":"Pax"},\#(rejectSecond)]"#
    #expect(review("```json\n\(reply)\n```") == [.vocabularyOnly("Pax"), .reject])
    #expect(review("```\n\(reply)\n```") == [.vocabularyOnly("Pax"), .reject])
}

@Test func correctionReviewFallsBackOnMalformedReplies() {
    let first = #"{"candidateID":0,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":"Pax"}"#
    #expect(review("[\(first),\(rejectSecond)]") != nil)
    for reply in [
        "Sure, here is what I would learn.",
        "[\(first),\(rejectSecond)",
        #"{"reviewDecisions":[\#(first),\#(rejectSecond)]}"#,
        "[\(first)]",
        "[\(first),\(first)]",
        "[\(first),\(rejectSecond),\(rejectSecond.replacingOccurrences(of: ":1", with: ":2"))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: ":1", with: ":2"))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: "\"candidateID\":1", with: "\"candidateID\":\"1\""))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: "\"candidateID\":1", with: "\"candidateID\":true"))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: "\"candidateID\":1", with: "\"candidateID\":1.5"))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: "}", with: ",\"reason\":\"ordinary\"}"))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: ",\"correctedVocabularyTerm\":null", with: ""))]",
        "[\(first),\(rejectSecond.replacingOccurrences(of: "rejectCorrection", with: "addEverything"))]",
    ] {
        #expect(review(reply) == nil, "\(reply)")
    }
}

@Test func correctionReviewRefusesTermsOutsideTheEdit() {
    let accepted = #"[{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"Pages","correctedVocabularyTerm":"Pax"},\#(rejectSecond)]"#
    #expect(review(accepted) == [.replacementAndVocabulary(heard: "Pages", corrected: "Pax"), .reject])
    for (heard, corrected) in [("Pages", "Packs"), ("Pagez", "Pax"), ("Pages", "numbers"), ("", "Pax"), ("Pages", ""),
                               ("to grab", "Pax to grab"), ("Pages t", "Pax t"), ("ages", "ax")] {
        let reply = #"[{"candidateID":0,"learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"\#(heard)","correctedVocabularyTerm":"\#(corrected)"},\#(rejectSecond)]"#
        #expect(review(reply) == nil, "\(heard) to \(corrected)")
    }
    #expect(review(#"[{"candidateID":0,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":1,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":"the"}]"#) == nil)
}

@Test func correctionReviewChecksTheActionAndItsNullsFirst() {
    let caseOnly = [LearnedCorrection(heard: "posthog", corrected: "PostHog")]
    #expect(CorrectionReviewer.parse(reply: replacing("posthog", with: "PostHog", action: "addEverything"), candidates: caseOnly,
                                     original: "open posthog now", edited: "open PostHog now") == nil)
    #expect(review(#"[{"candidateID":0,"learningAction":"rejectCorrection","incorrectTextToReplace":"Pages","correctedVocabularyTerm":"Pax"},\#(rejectSecond)]"#) == nil)
    #expect(review(#"[{"candidateID":0,"learningAction":"addVocabularyOnly","incorrectTextToReplace":"Pages","correctedVocabularyTerm":"Pax"},\#(rejectSecond)]"#) == nil)
    #expect(review(#"[{"candidateID":0,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":"Pax"},\#(rejectSecond)]"#)
        == [.vocabularyOnly("Pax"), .reject])
}

@Test func correctionReviewNeverLearnsAnEverydayWord() {
    #expect(CorrectionReviewer.parse(reply: #"[{"candidateID":0,"learningAction":"addVocabularyOnly","incorrectTextToReplace":null,"correctedVocabularyTerm":"THE"}]"#,
                                     candidates: [LearnedCorrection(heard: "the", corrected: "THE")], original: "see the docs", edited: "see THE docs") == [.reject])
}

@Test func correctionReviewRunsOnlyForEnglishAtMediumWithAReadyNotesModel() {
    var settings = AppSettings()
    settings.cleanup = .medium
    settings.notesSelection = .ollama("llama3.1:8b")
    settings.language = "en"
    #expect(CorrectionReviewer.mayReview("Ask Prakash Joshi Pax to grab the numbers", settings: settings))
    settings.language = "auto"
    #expect(CorrectionReviewer.mayReview("Ask Prakash Joshi Pax to grab the PostHog numbers today, please", settings: settings))
    #expect(!CorrectionReviewer.mayReview("Bitte schick Pax morgen früh die Zahlen aus PostHog und die Notizen", settings: settings))
    settings.language = "fr"
    #expect(!CorrectionReviewer.mayReview("Ask Prakash Joshi Pax to grab the numbers", settings: settings))
    settings.language = "en"
    settings.cleanup = .light
    #expect(!CorrectionReviewer.mayReview("Ask Prakash Joshi Pax to grab the numbers", settings: settings))
    settings.cleanup = .medium
    settings.notesSelection = .connection(UUID())
    #expect(!CorrectionReviewer.mayReview("Ask Prakash Joshi Pax to grab the numbers", settings: settings))
}

@Test func correctionReviewRefusesCommaSources() {
    let candidates = [LearnedCorrection(heard: "Pages", corrected: "Pax")]
    #expect(CorrectionReviewer.parse(reply: replacing("Pages", with: "Pax"), candidates: candidates, original: "Thanks, Pages", edited: "Thanks, Pax")
        == [.replacementOnly(heard: "Pages", corrected: "Pax")])
    #expect(CorrectionReviewer.parse(reply: replacing("Thanks, Pages", with: "Thanks, Pax"), candidates: candidates, original: "Thanks, Pages", edited: "Thanks, Pax") == nil)
}

@Test func correctionReviewTurnsCaseOnlyReplacementsIntoVocabulary() {
    let candidates = [LearnedCorrection(heard: "posthog", corrected: "PostHog")]
    for action in ["addReplacementAndVocabulary", "addReplacementOnly"] {
        #expect(CorrectionReviewer.parse(reply: replacing("posthog", with: "PostHog", action: action), candidates: candidates,
                                         original: "open posthog now", edited: "open PostHog now") == [.vocabularyOnly("PostHog")])
    }
}

@Test func correctionReviewRefusesOverLongTerms() {
    func parse(_ heard: String, _ corrected: String) -> [CorrectionDecision]? {
        CorrectionReviewer.parse(reply: replacing(heard, with: corrected), candidates: [LearnedCorrection(heard: heard, corrected: corrected)],
                                 original: "Ask \(heard) today", edited: "Ask \(corrected) today")
    }
    let longest = String(repeating: "x", count: 100), tooLong = String(repeating: "x", count: 101)
    #expect(parse(longest, "Pax") == [.replacementOnly(heard: longest, corrected: "Pax")])
    #expect(parse(tooLong, "Pax") == nil)
    #expect(parse("Pages", longest) == [.replacementOnly(heard: "Pages", corrected: longest)])
    #expect(parse("Pages", tooLong) == nil)
}

@Test func correctionReviewSendsOnlyNumberedExcerptsAroundEachEdit() throws {
    struct Sent: Decodable, Equatable {
        let candidateID: Int
        let originalText: String
        let correctedText: String
    }
    let request = try #require(CorrectionReviewer.request(for: candidates, from: "Private note: rent is due. \(original)", to: "Private note: rent is due. \(edited)"))
    #expect(try JSONDecoder().decode([String: [Sent]].self, from: Data(request.utf8)) == ["candidatesForReview": [
        Sent(candidateID: 0, originalText: "Ask Prakash Joshi Pages to grab the", correctedText: "Ask Prakash Joshi Pax to grab the"),
        Sent(candidateID: 1, originalText: "to grab the post hog numbers today", correctedText: "to grab the PostHog numbers today"),
    ]])
    #expect(!request.contains("Private"))
    #expect(CorrectionReviewer.request(for: [LearnedCorrection(heard: "Pagez", corrected: "Pax")], from: original, to: edited) == nil)
}

@Test func correctionReviewShowsOnlyThreeWordsAroundTheEdit() {
    #expect(CorrectionReviewer.excerpt(around: "kv", in: "one two three four kv five six seven eight") == "two three four kv five six seven")
    #expect(CorrectionReviewer.excerpt(around: "post hog", in: "post hog\nnumbers  today please now") == "post hog\nnumbers  today please")
    #expect(CorrectionReviewer.excerpt(around: "kv", in: "nothing here") == nil)
    #expect(CorrectionReviewer.excerpt(around: "kv", in: "kvm then kv, done") == "kvm then kv, done")
    #expect(CorrectionReviewer.excerpt(around: "kv", in: "the kvm only") == nil)
}

@Test func correctionDecisionsSkipKnownTermsAndStopAt200Entries() {
    let known = [VocabularyEntry(phrase: "post hog", replacement: "PostHog")]
    let added = CorrectionDecision.entries(for: [.replacementAndVocabulary(heard: "Post Hog", corrected: "Posthog"), .vocabularyOnly("posthog"),
                                                 .vocabularyOnly("Pax"), .vocabularyOnly("pax"), .reject,
                                                 .replacementOnly(heard: "super base", corrected: "Supabase")], in: known)
    #expect(added.map { [$0.phrase, $0.replacement] } == [["Pax", ""], ["super base", "Supabase"]])
    #expect(added.map(\.learned) == [true, true])
    let almostFull = (0..<199).map { VocabularyEntry(phrase: "term \($0)", replacement: "") }
    #expect(CorrectionDecision.entries(for: [.vocabularyOnly("Pax"), .vocabularyOnly("PostHog")], in: almostFull).map(\.phrase) == ["Pax"])
    #expect(CorrectionDecision.entries(for: [.vocabularyOnly("Pax")], in: almostFull + [VocabularyEntry(phrase: "one more", replacement: "")]).isEmpty)
}

@Test func correctionDecisionsMapOntoVocabularyEntries() {
    func shape(_ decision: CorrectionDecision) -> [String]? { decision.entry().map { [$0.phrase, $0.replacement] } }
    #expect(shape(.replacementAndVocabulary(heard: "post hog", corrected: "PostHog")) == ["post hog", "PostHog"])
    #expect(shape(.replacementAndVocabulary(heard: "good", corrected: "Goode")) == ["Goode", ""])
    #expect(shape(.replacementOnly(heard: "post hog", corrected: "PostHog")) == ["post hog", "PostHog"])
    #expect(shape(.replacementOnly(heard: "good", corrected: "Goode")) == nil)
    #expect(shape(.vocabularyOnly("PostHog")) == ["PostHog", ""])
    #expect(shape(.reject) == nil)
    #expect(CorrectionDecision.vocabularyOnly("PostHog").entry()?.learned == true)
}

@Test @MainActor func correctionIsStillLearnedAndSavedWithItsNotificationOff() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = LocalStore(directory: folder)
    let model = AppModel(store: store, startsServices: false)
    model.settings.notifyLearnedCorrections = false
    let transcript = Transcript(text: "ping post hog today", rawText: "ping post hog today", duration: 1, modelName: "test", language: "en")
    model.history = [transcript]

    model.updateTranscript(transcript, text: "ping PostHog today")
    let deadline = ContinuousClock.now + .seconds(5)
    while model.vocabulary.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

    #expect(model.vocabulary.map(\.replacement) == ["PostHog"])
    #expect(model.vocabulary.first?.learned == true)
    #expect(try store.load().vocabulary == model.vocabulary)
}
