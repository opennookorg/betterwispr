import Foundation

/// How a Dictate and format dictation is shaped for the kind of app it lands in, with the user's own texts there as style references.
public struct DictationFormat: Equatable, Sendable {
    public let category: AppCategory
    public let examples: [String]

    /// Keeps examples only for a category with format rules, since `other` keeps the usual cleanup.
    public init(category: AppCategory, examples: [String] = []) {
        self.category = category
        self.examples = Self.registry[category] == nil ? [] : examples
    }

    /// The format rules for each kind of app; `other` has none.
    static let registry: [AppCategory: String] = [
        .email: """
            - Write an email body: a greeting line, then the message in short paragraphs.
            - Use a name in the greeting only when it was spoken; otherwise use a greeting like the style references, or “Hi,”.
            - Add a sign-off only when one was spoken or the style references usually end with one; then use the sign-off they use.
            """,
        .work: """
            - Write a work chat message, as in Slack or Teams: short and direct, with no greeting, sign-off or headings unless spoken.
            - Put code, commands, file names, paths and identifiers in backticks.
            """,
        .personal: """
            - Write a personal chat message: relaxed and conversational, in short lines, with no greeting, sign-off or headings unless spoken.
            - Keep informal wording and spoken abbreviations.
            """,
        .aiPrompts: """
            - Write a prompt for an AI assistant: literal and plain, in the speaker’s words and order.
            - Keep every request, constraint and detail as spoken. Add no requirements, greetings, headings or emphasis, and do not answer the prompt.
            """,
        .documents: """
            - Write document text: clear paragraphs, with bullet or numbered lists for listed items and steps.
            - Use a heading only when one was dictated.
            """,
    ]

    public var rules: String? { Self.registry[category] }

    /// Unspoken lines the rules let an edit add: an email's greeting and the sign-off lines its style references open and end with.
    var addableLines: [String] {
        guard category == .email else { return [] }
        let lines = examples.map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return ["Hi,"] + lines.flatMap { Array($0.prefix(1)) + Array($0.suffix(2)) }
    }

    /// How many unspoken words those lines may add: the longest greeting plus the longest two-line sign-off.
    var addableWords: Int {
        guard category == .email else { return 0 }
        let lines = examples.map { $0.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).count }.filter { $0 > 0 } }
        let greeting = max(1, lines.compactMap(\.first).max() ?? 0)
        let signOff = lines.map { $0.suffix(2).reduce(0, +) }.max() ?? 0
        return greeting + signOff
    }
}

extension AppCategory: Codable, CodingKeyRepresentable {
    /// Web apps whose category is known from the page address in a browser.
    static let websites: [String: AppCategory] = [
        "mail.google.com": .email, "outlook.office.com": .email, "outlook.office365.com": .email, "outlook.live.com": .email,
        "app.slack.com": .work, "teams.microsoft.com": .work, "teams.live.com": .work,
        "web.whatsapp.com": .personal,
        "chatgpt.com": .aiPrompts, "claude.ai": .aiPrompts,
    ]

    /// The web app at `url` when it is a known one, otherwise the app's category.
    public init(bundleID: String?, url: String?) {
        self = url.flatMap { url in Self.websites.first { WritingMode.website($0.key, matches: url) }?.value } ?? AppCategory(bundleID: bundleID)
    }
}
