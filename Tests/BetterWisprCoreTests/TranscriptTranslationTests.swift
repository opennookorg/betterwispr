import BetterWisprCore
import Foundation
import Testing

@Test func aDictationSavedBeforeTranslationStillDecodes() throws {
    let saved = Data("""
    {
      "id": "CBF18987-ED38-4BC3-BC9A-68674B2233C4",
      "createdAt": 0,
      "text": "Bonjour !",
      "rawText": "bonjour",
      "duration": 1,
      "modelName": "Parakeet",
      "language": "fr"
    }
    """.utf8)
    let transcript = try JSONDecoder().decode(Transcript.self, from: saved)

    #expect(transcript.translation == nil)
    #expect(transcript.text == "Bonjour !")
    #expect(transcript.rawText == "bonjour")
}

@Test func translatedDictationPreservesThePreparedSourceAndRawRecognition() throws {
    let translation = DictationTranslation(sourceText: "Bonjour !", targetLanguage: "en")
    let transcript = Transcript(text: "Hello!", rawText: "Traduis en anglais. Bonjour.", duration: 3,
                                modelName: "Parakeet", language: "fr", translation: translation)
    let saved = try JSONEncoder().encode(transcript)
    let reloaded = try JSONDecoder().decode(Transcript.self, from: saved)

    #expect(reloaded.text == "Hello!")
    #expect(reloaded.rawText == "Traduis en anglais. Bonjour.")
    #expect(reloaded.language == "fr")
    #expect(reloaded.translation == translation)
}
