import Foundation

public enum VoiceCommands {
    private enum Attachment { case handle, number, nothing }

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:…\"“”")
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\n"]
    private static let nounMarkers: Set<String> = ["a", "an", "the", "this", "that", "oxford", "serial"]
    private static let requests: Set<String> = ["add", "insert", "put"]
    private static let apologies: Set<String> = ["sorry", "oops", "wait"]

    private static let alwaysPunctuation: [([String], String)] = [
        (["exclamation", "mark"], "!"), (["exclamation", "point"], "!"), (["exclamatory", "mark"], "!"), (["question", "mark"], "?"),
        (["full", "stop"], "."), (["semicolon"], ";"), (["comma"], ","),
    ]
    private static let requestedPunctuation: [([String], String)] = [
        (["period"], "."), (["colon"], ":"), (["dash"], " –"), (["hyphen"], "-"),
    ]
    private static let symbols: [(words: [String], symbol: String, attaches: Attachment)] = [
        (["at", "the", "rate"], "@", .handle), (["at", "sign"], "@", .handle), (["at", "symbol"], "@", .handle), (["@"], "@", .handle),
        (["hash", "tag"], "#", .handle), (["hashtag"], "#", .handle), (["hash", "sign"], "#", .nothing), (["hash", "symbol"], "#", .nothing),
        (["hash"], "#", .number), (["percent", "sign"], "%", .nothing), (["percentage", "sign"], "%", .nothing),
        (["percent"], "%", .nothing), (["percentage"], "%", .nothing),
    ]
    private static let functionWords: Set<String> = [
        "of", "is", "was", "are", "we", "you", "they", "it", "for", "and", "to", "the", "a", "an", "per", "which", "that",
    ]
    private static let topLevelDomains: Set<String> = ["com", "org", "net", "io", "ai", "edu", "gov"]
    private static let wordLikeDomains: Set<String> = ["in", "me", "co", "app", "dev"]

    /// Applies English spoken numbers (unless `digits` is false), punctuation, line breaks, "scratch that" and the @, # and % symbols.
    public static func apply(_ text: String, digits: Bool = true) -> String {
        let tokens = joiningDomains((digits ? SpokenNumbers.apply(text) : text).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
        let spoken = tokens.map(normalized).filter { !$0.isEmpty }
        if let whole = symbols.first(where: { $0.words == spoken }) { return whole.symbol }
        if let whole = requestedPunctuation.first(where: { $0.0 == spoken }) { return whole.1.trimmingCharacters(in: .whitespaces) }
        var out = ""
        var capitalizeNext = false
        var i = 0

        func key(_ j: Int) -> String {
            j >= 0 && j < tokens.count ? normalized(tokens[j]) : ""
        }
        func isInitial(_ j: Int) -> Bool {
            key(j).count == 1 && tokens[j].first?.isLetter == true
        }
        func endsSetOff(_ j: Int) -> Bool {
            j < 0 || tokens[j].last.map { ",.!?;:…".contains($0) } == true || apologies.contains(key(j))
        }
        func matches(_ words: [String], at j: Int) -> Bool {
            words.indices.allSatisfy { key(j + $0) == words[$0] }
        }
        func trimTrailing(_ characters: String) {
            while let last = out.last, last == " " || characters.contains(last) { out.removeLast() }
        }
        func dropApology() {
            trimTrailing(",;:")
            let words = out.split(separator: " ", omittingEmptySubsequences: false)
            guard let last = words.last, apologies.contains(last.lowercased().trimmingCharacters(in: edgePunctuation)) else { return }
            out.removeLast(last.count)
        }
        func append(_ word: String) {
            var word = word
            if capitalizeNext, let first = word.first, first.isLowercase { word = first.uppercased() + word.dropFirst() }
            capitalizeNext = false
            if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
            out += word
        }
        func punctuation(at j: Int) -> (symbol: String, length: Int)? {
            let requested = requests.contains(key(j - 1)) || (nounMarkers.contains(key(j - 1)) && requests.contains(key(j - 2)))
            if !requested, nounMarkers.contains(key(j - 1)) { return nil }
            if let (words, symbol) = alwaysPunctuation.first(where: { matches($0.0, at: j) }) { return (symbol, words.count) }
            let isLast = tokens[(j + 1)...].allSatisfy { $0.trimmingCharacters(in: edgePunctuation).isEmpty }
            if let (words, symbol) = requestedPunctuation.first(where: { matches($0.0, at: j) }), requested || (isLast && words == ["period"]) {
                return (symbol, words.count)
            }
            return nil
        }

        while i < tokens.count {
            let k = key(i)

            if requests.contains(k) {
                let target = nounMarkers.contains(key(i + 1)) ? i + 2 : i + 1
                if target < tokens.count, punctuation(at: target) != nil { i = target; continue }
            }

            if let (symbol, length) = punctuation(at: i) {
                trimTrailing(",;:" + (symbol == "," ? "" : ".!?"))
                out += symbol
                capitalizeNext = ".!?".contains(symbol)
                i += length
                continue
            }

            if ["new", "next"].contains(k), ["line", "paragraph"].contains(key(i + 1)), !nounMarkers.contains(key(i - 1)) {
                trimTrailing("")
                out += key(i + 1) == "line" ? "\n" : "\n\n"
                capitalizeNext = true
                i += 2
                continue
            }

            let forced = ["scratch", "strike"].contains(k) && key(i + 1) == "that"
            let setOff = ["remove", "delete", "undo", "cancel"].contains(k) && key(i + 1) == "that"
                && endsSetOff(i - 1) && (i + 2 == tokens.count || endsSetOff(i + 1))
            if forced || setOff {
                dropApology()
                trimTrailing(",;:.!?…")
                if let end = out.lastIndex(where: sentenceEnds.contains) { out = String(out[...end]) } else { out = "" }
                capitalizeNext = true
                i += 2
                continue
            }

            if let (words, symbol, attaches) = symbols.first(where: { matches($0.words, at: i) }) {
                let name = i + words.count
                if symbol == "@", isDomain(key(name)) {
                    if out.last.map({ $0.isLetter || $0.isNumber }) == true { out += "@" + tokens[name] } else { append("@" + tokens[name]) }
                    i = name + 1
                    continue
                }
                let handle = attaches == .handle && !key(name).isEmpty && !functionWords.contains(key(name))
                let number = attaches == .number && !key(name).isEmpty && key(name).allSatisfy(\.isNumber)
                if handle || number {
                    var end = name + 1
                    while tokens[end - 1].count == 1, isInitial(end - 1), isInitial(end) { end += 1 }
                    capitalizeNext = false
                    append(symbol + tokens[name..<end].joined())
                    i = end
                    continue
                }
            }

            append(tokens[i])
            i += 1
        }

        return out.replacing(#/[ \t]+([,.!?;:])/#, with: { $0.output.1 })
            .replacing(#/([,;:])[,;:]+/#, with: { $0.output.1 })
            .replacing(#/[ \t]*\n[ \t]*/#, with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the phrase is wholly a spoken command, as "question mark" becomes "?" and "at the rate" becomes "@".
    public static func isSpokenCommand(_ phrase: String) -> Bool {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = apply(phrase)
        return written != phrase && !written.contains(where: \.isLetter)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: edgePunctuation)
    }

    private static func isDomain(_ key: String) -> Bool {
        let labels = key.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count > 1 && labels.last.map { topLevelDomains.union(wordLikeDomains).contains(String($0)) } == true
            && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    /// Joins "example dot com" and "gmail. com" into one domain, "site dot in" only at a clause end, and splits "at the rategmail.com" into "at the rate gmail.com".
    private static func joiningDomains(_ words: [String]) -> [String] {
        var joined: [String] = []
        var i = 0
        while i < words.count {
            var word = words[i]
            var ending = i + 1 < words.count ? words[i + 1] : ""
            if word.dropLast().last.map({ $0.isLetter || $0.isNumber }) == true, word.last == ".",
               ending.first?.isLowercase == true, topLevelDomains.contains(normalized(ending)) {
                word += ending
                i += 1
                ending = i + 1 < words.count ? words[i + 1] : ""
            }
            let endsClause = i + 2 == words.count || ending.last.map { !$0.isLetter && !$0.isNumber } == true
            if word.lowercased() == "dot", let host = joined.last,
               host.last.map({ $0.isLetter || $0.isNumber }) == true, !["the", "a", "an"].contains(normalized(host)),
               topLevelDomains.contains(normalized(ending)) || (wordLikeDomains.contains(normalized(ending)) && endsClause) {
                joined[joined.count - 1] += "." + words[i + 1]
                i += 2
                continue
            }
            let remainder = String(word.dropFirst(4))
            if joined.suffix(2).map(normalized) == ["at", "the"], word.lowercased().hasPrefix("rate"), isDomain(normalized(remainder)) {
                joined += [String(word.prefix(4)), remainder]
            } else {
                joined.append(word)
            }
            i += 1
        }
        return joined
    }
}
