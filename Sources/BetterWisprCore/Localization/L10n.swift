import Foundation

/// Native presentation strings shared by the app and its core errors.
///
/// The host bundle selects from the languages in the native resource bundle;
/// command-line hosts without localizations keep English. Domain
/// values, persisted identifiers and model prompts must not use this helper.
public enum L10n {
    static let resourceBundle = Bundle.module

    public static var locale: Locale {
        Locale(identifier: preferredLocalization)
    }

    /// Look up a fixed English key, then apply Foundation's format arguments.
    /// Use `%@` with String arguments for ordinary interpolation and numeric
    /// `%ld` with Int arguments for native .stringsdict plural selectors.
    public static func tr(_ key: String, _ arguments: any CVarArg..., table: String? = nil) -> String {
        resolve(key, localization: preferredLocalization, locale: locale, table: table, arguments: arguments)
    }

    /// An explicit locale keeps tests deterministic without changing language
    /// preferences. Unsupported languages fall back to the English resources.
    public static func localized(_ key: String, locale: Locale, table: String? = nil,
                                 arguments: [any CVarArg] = []) -> String {
        let localization = localization(for: [locale.identifier])
        return resolve(key, localization: localization, locale: locale, table: table, arguments: arguments)
    }

    private static var preferredLocalization: String {
        localization(for: Bundle.main.preferredLocalizations)
    }

    static func localization(for preferences: [String], in bundle: Bundle = resourceBundle) -> String {
        // Foundation falls back to the first candidate for unsupported languages.
        // Keep English first independently of the filesystem's directory order.
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
