import Foundation

public enum StyleFormatter {
    /// Applies an English writing tone; formal leaves the recognized text unchanged.
    public static func apply(_ tone: StyleTone, to text: String) -> String {
        switch tone {
        case .formal: text
        case .casual: casual(text)
        case .veryCasual: lowercasingSentenceStarts(casual(text))
        case .excited: excited(text)
        }
    }

    private static func casual(_ text: String) -> String {
        let characters = Array(text)
        var kept = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let insideNumber = index > 0 && characters[index - 1].isNumber && next?.isNumber == true
            if character == ",", !insideNumber, !(next?.isNewline ?? false) { continue }
            kept.append(character)
        }
        if let period = finalPeriod(kept), kept.index(after: period) == kept.endIndex { kept.remove(at: period) }
        return joiningGreeting(kept)
    }

    private static func excited(_ text: String) -> String {
        guard let period = finalPeriod(text) else { return text }
        var result = text
        result.replaceSubrange(period...period, with: "!")
        return result
    }

    /// The period ending the last sentence, skipping ellipses, abbreviations like "p.m." and decimals.
    private static func finalPeriod(_ text: String) -> String.Index? {
        guard let end = text.lastIndex(where: { ".!?".contains($0) }), text[end] == "." else { return nil }
        let after = text.index(after: end)
        guard after == text.endIndex || text[after].isWhitespace else { return nil }
        let isListMarker = after != text.endIndex && text[..<end].reversed().prefix { !$0.isNewline }.allSatisfy(\.isNumber)
        guard !isListMarker else { return nil }
        let word = text[..<end].reversed().prefix { !$0.isWhitespace }
        return word.first?.isLetter == true || word.first?.isNumber == true ? (word.contains(".") ? nil : end) : nil
    }

    private static func joiningGreeting(_ text: String) -> String {
        guard let match = text.firstMatch(of: /\A([^\n.!?,]{1,40}),\n+(\p{L}[\p{L}'’]*)/),
              match.1.split(separator: " ").count <= 4 else { return text }
        return "\(match.1), \(sentenceCased(match.2))" + text[match.range.upperBound...]
    }

    private static func lowercasingSentenceStarts(_ text: String) -> String {
        var result = ""
        var atSentenceStart = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if atSentenceStart, character.isLetter {
                let word = text[index...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }
                result += word.dropFirst().contains(where: \.isUppercase) ? String(word) : word.lowercased()
                atSentenceStart = false
                index = word.endIndex
                continue
            }
            if character.isLetter || character.isNumber { atSentenceStart = false }
            if ".!?\n".contains(character) { atSentenceStart = true }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func sentenceCased(_ word: Substring) -> String {
        let keepsCase = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || word.dropFirst().contains(where: \.isUppercase)
        return keepsCase ? String(word) : word.lowercased()
    }
}
