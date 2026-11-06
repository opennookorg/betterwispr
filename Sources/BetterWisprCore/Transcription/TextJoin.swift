import Foundation

public enum TextJoin {
    /// Text pasted right after an earlier dictation in the same field, with a space between them unless it starts with
    /// punctuation or is Chinese or Japanese, which aren't written with spaces between words.
    public static func continuing(_ text: String) -> String {
        guard let first = text.first, !first.isWhitespace, !",.!?;:)]}…".contains(first),
              let scalar = first.unicodeScalars.first, !unspaced.contains(where: { $0.contains(scalar.value) }) else { return text }
        return " " + text
    }

    /// Text followed by a space, unless it already ends in whitespace or with Chinese or Japanese.
    public static func trailing(_ text: String) -> String {
        guard let last = text.last, !last.isWhitespace, let scalar = last.unicodeScalars.last,
              !unspaced.contains(where: { $0.contains(scalar.value) }) else { return text }
        return text + " "
    }

    /// CJK punctuation, kana, ideographs and full-width forms.
    private static let unspaced: [ClosedRange<UInt32>] = [0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF]
}
