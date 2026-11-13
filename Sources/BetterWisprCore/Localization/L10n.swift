import Foundation

/// Interface strings keyed by their English text; never use it for prompts, transcripts or saved values.
public enum L10n {
    static let resourceBundle = Bundle.module

    public static var locale: Locale {
        Locale(identifier: preferredLocalization)
    }

    /// Looks up an English key in the app's language; pass `%@` Strings, or `%ld` Ints for plurals.
    public static func tr(_ key: String, _ arguments: any CVarArg..., table: String? = nil) -> String {
        resolve(key, localization: preferredLocalization, locale: locale, table: table, arguments: arguments)
    }

    /// Looks up an English key for an explicit locale, falling back to English.
    public static func localized(_ key: String, locale: Locale, table: String? = nil,
                                 arguments: [any CVarArg] = []) -> String {
        let localization = localization(for: [locale.identifier])
        return resolve(key, localization: localization, locale: locale, table: table, arguments: arguments)
    }

    private static var preferredLocalization: String {
        localization(for: Bundle.main.preferredLocalizations)
    }

    static func localization(for preferences: [String], in bundle: Bundle = resourceBundle) -> String {
        let localizations = bundle.localizations.filter { $0 != "Base" && $0 != "en" }.sorted()
        return Bundle.preferredLocalizations(from: ["en"] + localizations, forPreferences: preferences).first ?? "en"
    }

    private static func resolve(_ key: String, localization: String, locale: Locale,
                                table: String?, arguments: [any CVarArg]) -> String {
        let englishBundle = localizedBundle("en")
        let fallback = englishBundle.localizedString(forKey: key, value: key, table: table)
        let format = localizedBundle(localization).localizedString(forKey: key, value: fallback, table: table)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static func localizedBundle(_ localization: String) -> Bundle {
        guard let path = resourceBundle.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resourceBundle }
        return bundle
    }
}
