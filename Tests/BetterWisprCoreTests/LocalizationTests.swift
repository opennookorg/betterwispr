import Foundation
import Testing
@testable import BetterWisprCore
@testable import BetterWispr

private let french = Locale(identifier: "fr_FR")
private let english = Locale(identifier: "en_US")

@Test func localizationUsesFrenchAndFallsBackToEnglishWithoutChangingPreferences() {
    #expect(L10n.localized("Settings", locale: french) == "Réglages")
    #expect(L10n.localized("Settings", locale: english) == "Settings")
    #expect(L10n.localized("Settings", locale: Locale(identifier: "zz_ZZ")) == "Settings")
    #expect(L10n.localized("A missing English source key", locale: french) == "A missing English source key")
    #expect(L10n.localized("Settings", locale: Locale(identifier: "fr_CA")) == "Réglages")
}

@Test func localizationKeepsNativeFormattingEscapesAndArgumentsIntact() {
    #expect(L10n.localized("Downloading… %@%%", locale: french, arguments: ["42"]) == "Téléchargement… 42 %")
    #expect(L10n.localized("Downloading… %@%%", locale: english, arguments: ["42"]) == "Downloading… 42%")
    #expect(L10n.localized("## Summary\n\n%@", locale: french, arguments: ["A \"quote\"\n100%"])
            == "## Résumé\n\nA \"quote\"\n100%")
    #expect(L10n.localized("%2$@ / %1$@ / %2$@", locale: french, arguments: ["one", "two%"])
            == "two% / one / two%")
}

@Test func contextualTranslationsDistinguishThemeCleanupAndKeyboardLabels() {
    #expect(L10n.localized("Light", locale: french) == "Léger")
    #expect(L10n.localized("Light", locale: french, table: "Appearance") == "Clair")
    #expect(L10n.localized("Home", locale: french) == "Accueil")
    #expect(L10n.localized("Home", locale: french, table: "ShortcutKey") == "Début")
    #expect(L10n.localized("Delete", locale: french, table: "ShortcutKey") == "Suppression")
    #expect(L10n.localized("Undo", locale: french, table: "Recording") == "Reprendre la transcription")
    #expect(L10n.localized("Finish", locale: french, table: "Sounds") == "Fin")
    #expect(L10n.localized("Finish", locale: french) == "Terminer")
}

@Test func nativePluralRulesHandleZeroOneAndSeveralAndOtherArguments() {
    for (count, expectedFrench, expectedEnglish) in [(0, "0 mot", "0 words"), (1, "1 mot", "1 word"), (2, "2 mots", "2 words")] {
        #expect(L10n.localized("%ld words", locale: french, arguments: [count]) == expectedFrench)
        #expect(L10n.localized("%ld words", locale: english, arguments: [count]) == expectedEnglish)
        #expect(L10n.localized("%@, %ld words, %@", locale: french, arguments: ["Editor", count, "50 %"])
                == "Editor, \(expectedFrench), 50 %")
    }
    #expect(L10n.localized("%@: %ld words", locale: french, arguments: ["Lundi", 2]) == "Lundi : 2 mots")
}

@Test func localizationDoesNotRewriteCanonicalModelMetadataOrUserNames() throws {
    let apple = try #require(SpeechModel.catalog.first { $0.id == "apple" })
    #expect(apple.name == "Apple on-device")
    #expect(L10n.localized(apple.name, locale: french) == "Apple sur l’appareil")
    var connection = SpeechConnection()
    connection.name = "Apple on-device"
    #expect(connection.speechModel.name == "Apple on-device")
    #expect(connection.speechModel.localizedName == "Apple on-device")
    #expect(connection.speechModel.localizedDetail.contains(connection.endpoint))
    #expect(Speaker.me.label == "Me")
    #expect(MeetingQuestion.catchUpQuestion.contains("What did I miss"))
    let shortcut = DictationShortcut.optionSpace
    let saved = try JSONEncoder().encode(shortcut)
    #expect(try JSONDecoder().decode(DictationShortcut.self, from: saved).key == "Space")
}

@Test func countOnlyUnitsUseEachLanguagesNativePluralRules() {
    let units = [
        ("Streak day unit", "day", "days", "jour", "jours"),
        ("Removed word unit", "word removed", "words removed", "mot supprimé", "mots supprimés"),
        ("Consecutive day unit", "day in a row", "days in a row", "jour de suite", "jours de suite"),
    ]
    for (key, englishOne, englishOther, frenchOne, frenchOther) in units {
        for count in [0, 1, 2] {
            #expect(L10n.localized(key, locale: english, arguments: [count]) == (count == 1 ? englishOne : englishOther))
            #expect(L10n.localized(key, locale: french, arguments: [count]) == (count <= 1 ? frenchOne : frenchOther))
        }
    }
}

@Test func insightSentencesUseNativePluralsAndPreserveOtherArguments() {
    for count in [0, 1, 2] {
        let englishWords = "\(count) \(count == 1 ? "word" : "words")"
        let frenchWords = "\(count) \(count <= 1 ? "mot" : "mots")"
        #expect(L10n.localized("Busiest %@: %@, %ld words", locale: english, arguments: ["day", "Monday", count])
                == "Busiest day: Monday, \(englishWords)")
        #expect(L10n.localized("Busiest %@: %@, %ld words", locale: french, arguments: ["jour", "lundi", count])
                == "Période la plus active (jour) : lundi, \(frenchWords)")
        #expect(L10n.localized("%@ %ld words with BetterWispr at %@ words per minute, about %@ faster than typing.",
                              locale: english, arguments: ["This week", count, "120", "2 minutes"])
                == "This week \(englishWords) with BetterWispr at 120 words per minute, about 2 minutes faster than typing.")
        #expect(L10n.localized("%@ %ld words with BetterWispr at %@ words per minute, about %@ faster than typing.",
                              locale: french, arguments: ["Cette semaine", count, "120", "2 minutes"])
                == "Cette semaine \(frenchWords) avec BetterWispr, à 120 mots par minute, soit environ 2 minutes de moins qu’au clavier.")
        #expect(L10n.localized("Not counted: %ld dictations with no app recorded.", locale: english, arguments: [count])
                == "Not counted: \(count) \(count == 1 ? "dictation" : "dictations") with no app recorded.")
        #expect(L10n.localized("Not counted: %ld dictations with no app recorded.", locale: french, arguments: [count])
                == (count <= 1 ? "Dictée sans app associée, non comptabilisée : \(count)."
                    : "Dictées sans app associée, non comptabilisées : \(count)."))
    }
}

@Test func localizedResourceTablesKeepMatchingKeysAndNativeFormatArguments() throws {
    let en = try #require(L10n.resourceBundle.url(forResource: "en", withExtension: "lproj"))
    let englishTables = try FileManager.default.contentsOfDirectory(at: en, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "strings" }
    let placeholder = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(?:0?\d+)?(@|ld|d|u|f)"#)
    func formats(_ text: String) -> [String] {
        let text = text.replacingOccurrences(of: "%%", with: "")
        return placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 2), in: text).map { String(text[$0]) }
        }.sorted()
    }
    for language in L10n.resourceBundle.localizations where language != "Base" {
        let locale = try #require(L10n.resourceBundle.url(forResource: language, withExtension: "lproj"))
        let localeTables = try FileManager.default.contentsOfDirectory(at: locale, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "strings" }
        #expect(Set(localeTables.map(\.lastPathComponent)) == Set(englishTables.map(\.lastPathComponent)))
        for table in englishTables {
            let englishStrings = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: table), format: nil) as? [String: String])
            let translatedStrings = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: locale.appendingPathComponent(table.lastPathComponent)), format: nil) as? [String: String])
            #expect(Set(englishStrings.keys) == Set(translatedStrings.keys), "Mismatched \(language)/\(table.lastPathComponent) keys")
            for (key, value) in englishStrings {
                let translated = try #require(translatedStrings[key])
                #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(formats(value) == formats(translated), "Format mismatch for \(language)/\(key)")
            }
        }
    }
}

@Test func permissionTranslationsCoverEveryEnglishUsageDescription() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
    let permissions = info.filter { $0.key.hasSuffix("UsageDescription") }.compactMapValues { $0 as? String }
    #expect(permissions.count == 5)
    let sourceLocales = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources/BetterWisprCore/Localization/Resources"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
    let permissionLocales = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Resources"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }
    #expect(Set(sourceLocales) == Set(permissionLocales))
    for language in sourceLocales {
        let file = root.appendingPathComponent("Resources/\(language).lproj/InfoPlist.strings")
        let strings = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: String])
        #expect(Set(strings.keys) == Set(permissions.keys))
        for (key, value) in permissions {
            #expect(strings[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            if language == "en" { #expect(strings[key] == value) }
        }
    }
}

@Test func localizationDiscoversNewBundleLanguagesWithoutRegistrationLists() throws {
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("BetterWispr-localization-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: temporary) }
    let resources = temporary.appendingPathComponent("Fixture.bundle/Contents/Resources", isDirectory: true)
    try manager.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "org.betterwispr.tests.localization", "CFBundleDevelopmentRegion": "en"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    for language in ["en", "es", "pt-BR"] {
        let folder = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Settings": "Fixture \(language)"], format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Localizable.strings"))
    }
    let bundle = try #require(Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent()))
    #expect(L10n.localization(for: ["es-MX"], in: bundle) == "es")
    #expect(L10n.localization(for: ["pt-BR"], in: bundle) == "pt-BR")
    #expect(L10n.localization(for: ["zz-ZZ"], in: bundle) == "en")
    #expect(L10n.localization(for: [], in: bundle) == "en")
}
