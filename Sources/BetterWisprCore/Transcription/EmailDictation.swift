import Foundation

public enum EmailDictation {
    private static let formalClosings = ["regards", "sincerely", "yours", "wishes"]

    /// Whether the dictation opens by asking for an email, such as "write an email to Sam …".
    public static func isRequest(_ text: String) -> Bool {
        (try? #/^\s*(?:please\s+)?(?:write|draft|compose|send)\s+(?:an?\s+)?(?:quick\s+|short\s+)?e-?mail\b/#.ignoresCase().prefixMatch(in: text)) != nil
    }

    /// Lays out "write an email to Sam saying …" as a greeting, body and sign-off, or returns nil for any other text.
    public static func compose(_ text: String) -> String? {
        let request = #/\s*(?:please\s+)?(?:write|draft|compose)\s+(?:an?\s+)?(?:quick\s+|short\s+)?e-?mail\s+to\s+(?:the\s+)?(?<name>\p{L}[\p{L}'’.-]*(?:\s+\p{L}[\p{L}'’.-]*){0,2}?)\s*(?:,?\s+(?:saying|telling\s+(?:him|her|them)|letting\s+(?:him|her|them)\s+know|to\s+say|that|with\s+(?:this|the\s+following)\s+(?:content|message|text|body))[,:]?|:)\s+(?:that\s+)?(?<body>.+)/#
        guard let match = try? request.ignoresCase().dotMatchesNewlines().wholeMatch(in: text) else { return nil }
        var body = String(match.output.body).trimmingCharacters(in: .whitespacesAndNewlines)
        var signOff: String?
        let closing = #/(?<lead>^|[.,!?;])\s*(?<closing>best regards|kind regards|warm regards|warmest regards|yours sincerely|yours truly|many thanks|best wishes|thank you|sincerely|regards|cheers|thanks|best)(?:[,.!]\s*(?<name>\p{L}[\p{L}'’.-]*(?:\s+\p{L}[\p{L}'’.-]*){0,2}))?[.!]?\s*$/#
        if let end = try? closing.ignoresCase().firstMatch(in: body) {
            let phrase = end.output.closing.lowercased()
            let name = end.output.name.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            let namesSigner = formalClosings.contains { phrase.contains($0) } || name?.split(separator: " ").allSatisfy { $0.first?.isUppercase == true } ?? true
            let kept = trimmed(String(body[..<end.range.lowerBound]) + ("!?.".contains(end.output.lead) ? end.output.lead : ""))
            if namesSigner, !kept.isEmpty {
                signOff = capitalized(phrase, everyWord: false) + (name.map { ",\n" + capitalized($0, everyWord: true) } ?? "")
                body = kept
            }
        }
        body = trimmed(body)
        guard !body.isEmpty else { return nil }
        if let last = body.last, !".!?".contains(last) { body += "." }
        let greeting = "Hi \(capitalized(String(match.output.name), everyWord: true)),\n\n\(capitalized(body, everyWord: false))"
        return signOff.map { "\(greeting)\n\n\($0)" } ?? greeting
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:")))
    }

    private static func capitalized(_ text: String, everyWord: Bool) -> String {
        guard everyWord else { return text.prefix(1).uppercased() + text.dropFirst() }
        return text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
