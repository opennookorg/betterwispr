import Foundation

/// Rewrites spoken numbers as digits in languages other than English, using number words the system spells for each language.
public enum LocalizedSpokenNumbers {
    private enum Kind { case unit, tens, small, hundreds, multiplier, scale }
    private typealias Word = (value: Int, kind: Kind)

    /// Words after which "um" or "uno" is a number rather than an article, as in "PR número um".
    private static let anchors: Set<String> = ["numero", "nummer", "numer", "nr", "nº", "n°", "номер", "pr", "issue", "ticket"]
    /// Decimal and grouping marks spoken between numbers, written as said: "três vírgula cinco" is "3,5" and "zero ponto um ponto seis" "0.1.6".
    private static let separators: [String: String] = [
        "virgula": ",", "ponto": ".", "coma": ",", "punto": ".", "virgule": ",", "point": ".", "virgola": ",", "komma": ",", "punkt": ".",
    ]
    private static let percents: [[String]] = [
        ["por", "cento"], ["porcento"], ["por", "ciento"], ["pour", "cent"], ["pourcent"], ["per", "cento"], ["prozent"], ["procent"], ["procento"],
    ]
    /// English has `SpokenNumbers`; the others are written without spaces between words.
    private static let skipped: Set<String> = ["en", "zh", "ja", "ko", "th", "yue", "my", "km", "lo"]
    /// Common spoken forms the system doesn't spell: Brazilian "quatorze" and feminine counts such as "duas" or "duzentas".
    private static let extras: [String: [String: Int]] = ["pt": ["quatorze": 14, "uma": 1, "duas": 2], "es": ["una": 1]]

    /// Lowercased, without soft hyphens and accents, so "Três", "tres" and the system's "quattro\u{AD}mila" spelling compare equal.
    private static func key(_ word: some StringProtocol) -> String {
        word.lowercased().replacing("\u{AD}", with: "").folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Number words and the connectors between them ("e", "y", "și"), learned from the system's spelled-out numbers.
    private struct Lexicon {
        let words: [String: Word]
        let connectors: Set<String>
        /// Whether the language writes numbers as one word, as German "siebenundsechzig" or Italian "sessantasette".
        let compounds: Bool
        let formatter = NumberFormatter()

        init?(language: String) {
            var words: [String: Word] = [:]
            var connectors: Set<String> = []
            let formatter = self.formatter
            formatter.numberStyle = .spellOut
            formatter.locale = Locale(identifier: language)
            formatter.isLenient = true
            func spelled(_ n: Int) -> [String] {
                formatter.string(from: n as NSNumber)?.split(separator: " ").map(String.init) ?? []
            }
            func known(_ word: String) -> Bool { words[key(word)] != nil }
            func add(_ word: String, _ value: Int, _ kind: Kind? = nil) {
                let kind = kind ?? (value < 10 ? .unit : value % 10 == 0 && value >= 20 ? .tens : .small)
                if !known(word) { words[key(word)] = (value, kind) }
            }

            var compound: [[String]] = []
            for n in 0...99 {
                let tokens = spelled(n)
                if tokens.count == 1 { add(tokens[0], n) } else { compound.append(tokens) }
            }
            guard words.count > 10 else { return nil }
            for (word, value) in LocalizedSpokenNumbers.extras[language] ?? [:] { add(word, value) }
            for k in 1...9 {
                let hundred = spelled(100 * k)
                if hundred.count == 1 {
                    add(hundred[0], 100 * k, .hundreds)
                    if ["pt", "es"].contains(language), hundred[0].hasSuffix("os") { add(String(hundred[0].dropLast(2)) + "as", 100 * k, .hundreds) }
                } else if let last = hundred.last {
                    // A feminine or counting form, such as Romanian "două sute" or Czech "dvě stě".
                    if hundred.count == 2, !known(hundred[0]) { add(hundred[0], k, .unit) }
                    add(last, 100, .multiplier)
                }
                // "cento e um", "ciento uno" and "deux cent un" show the forms used before more digits.
                let more = spelled(100 * k + 1)
                for (i, word) in more.enumerated() where more.count > 1 && !known(word) {
                    if i == 0 { add(word, 100 * k, .hundreds) } else if words[key(more[i - 1])]?.kind == .unit { add(word, 100, .multiplier) } else { connectors.insert(key(word)) }
                }
            }
            for scale in [1_000, 1_000_000, 1_000_000_000] {
                for k in [1, 2, 5] {
                    let tokens = spelled(k * scale)
                    if tokens.count == 1, k == 1 {
                        add(tokens[0], scale, .scale)
                    } else if tokens.count > 1, let last = tokens.last {
                        if tokens.count == 2, !known(tokens[0]) { add(tokens[0], k, .unit) }
                        add(last, scale, .scale)
                    }
                }
            }
            for tokens in compound + [spelled(1_001), spelled(2_021)] {
                connectors.formUnion(tokens.filter { !known($0) }.map(key))
            }
            for word in words.keys where word.contains("-") {
                connectors.formUnion(word.split(separator: "-").map(String.init).filter { !known($0) })
            }
            self.words = words
            self.connectors = connectors
            compounds = spelled(67).joined().contains("\u{AD}")
        }

        /// A whole number written as one word, such as German "viertausendfünfhundertsiebenundsechzig".
        /// Only words that start and end with a number word are parsed, which keeps the slow lenient parse off ordinary words,
        /// and only a value the system spells back as the same word counts, which rejects ordinals such as "segundo" or "zweite".
        func compoundValue(_ word: String) -> Int? {
            let wordKey = key(word)
            guard compounds, wordKey.count >= 6, word.allSatisfy(\.isLetter),
                  words.keys.contains(where: { $0.count >= 3 && wordKey.hasPrefix($0) }),
                  words.keys.contains(where: { $0.count >= 3 && wordKey.hasSuffix($0) }),
                  let value = formatter.number(from: word.lowercased())?.intValue,
                  formatter.string(from: value as NSNumber).map(key) == wordKey else { return nil }
            return value
        }
    }

    private struct Token {
        let text: String
        let leading: String
        let core: String
        let trailing: String
        let key: String

        init(_ text: Substring) {
            let isWordCharacter = { (character: Character) in character.isLetter || character.isNumber || character == "-" }
            let end = text.lastIndex(where: isWordCharacter).map(text.index(after:)) ?? text.startIndex
            let start = text[..<end].firstIndex(where: isWordCharacter) ?? end
            self.text = String(text)
            leading = String(text[..<start])
            core = String(text[start..<end])
            trailing = String(text[end...])
            key = LocalizedSpokenNumbers.key(core)
        }
    }

    /// The finished scale groups, the group below the last scale, and the largest value the group's next word may have.
    private struct Reading {
        var total = 0
        var group = 0
        var limit = Int.max
        var scale = Int.max
        var scales = 0
        var words = 0
        var last: Kind?

        var value: Int { total + group }

        mutating func read(_ word: Word) -> Bool {
            switch word.kind {
            case .scale:
                // A scale word alone means one of it, as in "mil e quinhentos" or "тысяча двести".
                let count = group > 0 ? group : words == 0 ? 1 : 0
                guard count > 0, word.value < scale else { return false }
                total += count * word.value
                group = 0
                limit = Int.max
                scale = word.value
                scales += 1
            case .hundreds where word.value == 100 && last == .unit && (1...9).contains(group), .multiplier:
                // French "cinq cent": the word for one hundred also multiplies a count before it.
                guard last == .unit, (1...9).contains(group) else { return false }
                group *= 100
                limit = 100
            case .hundreds:
                guard limit == Int.max else { return false }
                group += word.value
                limit = 100
            case .unit, .tens, .small:
                guard word.value < limit, word.value > 0 || words == 0 else { return false }
                group += word.value
                limit = word.kind == .tens ? 10 : 1
            }
            last = word.kind
            words += 1
            return true
        }
    }

    /// Writes number words as digits in `language`, or in the text's detected language when it is nil: "quatro mil quinhentos e sessenta e sete" becomes "4567",
    /// "dois gatos" "2 gatos", "doscientos cincuenta mil" "250000" and "dix pour cent" "10%". English is left to `SpokenNumbers`.
    public static func apply(_ text: String, language: String?) -> String {
        guard let code = TranscriptCleaner.languageCode(of: text, language: language), !skipped.contains(code), let lexicon = Lexicon(language: code) else { return text }
        let tokens = text.split(separator: " ").map(Token.init)
        func joined(_ j: Int) -> Bool {
            j > 0 && j < tokens.count && tokens[j - 1].trailing.isEmpty && tokens[j].leading.isEmpty
        }
        func isNumberWord(_ j: Int) -> Bool { j < tokens.count && lexicon.words[tokens[j].key] != nil }
        func reading(at start: Int) -> (Reading, end: Int) {
            var reading = Reading()
            if !isNumberWord(start), let value = lexicon.compoundValue(tokens[start].core) {
                reading.group = value
                reading.words = 1
                return (reading, start + 1)
            }
            var end = start
            while end < tokens.count {
                var j = end
                if reading.words > 0 {
                    guard joined(j) else { break }
                    if lexicon.connectors.contains(tokens[j].key) {
                        j += 1
                        guard joined(j) else { break }
                    }
                }
                guard let word = lexicon.words[tokens[j].key] else { break }
                var next = reading
                guard next.read(word) else { break }
                reading = next
                end = j + 1
            }
            return (reading, end)
        }

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let (number, firstEnd) = reading(at: i)
            var end = firstEnd
            guard end > i else {
                out.append(tokens[i].text)
                i += 1
                continue
            }
            // Numbers spoken one after another, such as "quatro cinco seis sete", are one run of digits, and a "vírgula" or "ponto" said between them is written as said.
            // A later number of 100 or more starts a new one. Nothing else adds separators, since whether "." or "," groups thousands depends on the reader.
            var digits = String(number.value)
            while joined(end) {
                let mark = separators[tokens[end].key]
                let start = mark == nil ? end : end + 1
                guard mark == nil || joined(start), case let (next, after) = reading(at: start), after > start, mark != nil || next.value < 100 else { break }
                digits += (mark ?? "") + String(next.value)
                end = after
            }
            let percent = percents.first { words in words.indices.allSatisfy { joined(end + $0) && tokens[end + $0].key == words[$0] } }
            let last = end + (percent?.count ?? 0)
            if end == firstEnd {
                let anchored = i > 0 && tokens[i - 1].trailing.isEmpty && anchors.contains(tokens[i - 1].key)
                // "um", "une" or "eine" alone is usually an article, and "mil" or "mille" alone an exaggeration.
                if percent == nil, end - i == 1, number.value == 1 && !anchored || number.last == .scale {
                    out += tokens[i..<end].map(\.text)
                    i = end
                    continue
                }
                if number.last == .scale, number.scales == 1, number.scale >= 1_000_000 {
                    digits = String(number.value / number.scale) + " " + tokens[end - 1].core
                }
            }
            out.append(tokens[i].leading + digits + (percent == nil ? "" : "%") + tokens[last - 1].trailing)
            i = last
        }
        return out.joined(separator: " ")
    }
}
