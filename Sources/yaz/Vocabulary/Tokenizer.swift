import Foundation

/// Splits a transcript into words while remembering everything that is *not*
/// the word.
///
/// Correction rewrites the stem and must put the rest back untouched. Three
/// things ride along with a Turkish word and all three matter:
///
/// - **Leading punctuation** — an opening quote or bracket.
/// - **The apostrophe suffix** — Turkish attaches case endings to proper nouns
///   after an apostrophe (`Slack'ten`, `Notion'a`). Replacing `Sılacık'tan`
///   with `Slack` and dropping `'tan` produces a grammatically broken
///   sentence, so the suffix is preserved verbatim.
/// - **Trailing punctuation** — commas and full stops that end a clause.
enum Tokenizer {

    struct Token: Sendable, Equatable {
        /// Range of the whole token in the source string.
        let range: Range<String.Index>
        /// Punctuation before the word (`"`, `(`).
        let leading: String
        /// The word plus any apostrophe suffix, without outer punctuation.
        let core: String
        /// The word alone — what matching compares against.
        let stem: String
        /// Apostrophe and everything after it (`'ten`), or empty.
        let suffix: String
        /// Punctuation after the word (`,`, `.`).
        let trailing: String
    }

    /// Apostrophes Whisper may emit. The typographic one is common in its
    /// Turkish output, so matching only `'` would miss most real suffixes.
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "`"]

    private static let leadingPunctuation: Set<Character> = [
        "\"", "\u{201C}", "(", "[", "{", "«", "'", "\u{2018}",
    ]
    private static let trailingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "\"", "\u{201D}", ")", "]", "}", "»", "…",
    ]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex

        while index < text.endIndex {
            // Skip whitespace between tokens.
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let range = start..<index
            let raw = String(text[range])
            guard let token = split(raw, range: range) else { continue }
            tokens.append(token)
        }
        return tokens
    }

    /// Peel a whitespace-delimited run into leading / stem / suffix / trailing.
    private static func split(_ raw: String, range: Range<String.Index>) -> Token? {
        var characters = Array(raw)

        var leading = ""
        while let first = characters.first, leadingPunctuation.contains(first) {
            leading.append(first)
            characters.removeFirst()
        }

        var trailingReversed: [Character] = []
        while let last = characters.last, trailingPunctuation.contains(last) {
            trailingReversed.append(last)
            characters.removeLast()
        }
        let trailing = String(trailingReversed.reversed())

        let core = String(characters)
        guard !core.isEmpty else { return nil }

        // A suffix only counts when the apostrophe is followed by letters:
        // that distinguishes `Slack'ten` from a stray quotation mark.
        var stem = core
        var suffix = ""
        if let position = core.firstIndex(where: { apostrophes.contains($0) }) {
            let after = core.index(after: position)
            let tail = core[after...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isLetter }) {
                stem = String(core[core.startIndex..<position])
                suffix = String(core[position...])
            }
        }
        guard !stem.isEmpty else { return nil }

        return Token(
            range: range,
            leading: leading,
            core: core,
            stem: stem,
            suffix: suffix,
            trailing: trailing
        )
    }
}
