import Foundation

/// Removes hesitation sounds from a transcript, with no model involved.
///
/// The scope here is deliberately narrow. Turkish speech is full of things a
/// naive "filler word" list would delete and shouldn't: `yani`, `şey`, `hani`,
/// `işte`, `falan` are all real words carrying real meaning depending on
/// context. Deciding when they are filler needs context, which is what the
/// language model in `Refiner` is for.
///
/// What this filter handles is the category that is *never* a word: `ııı`,
/// `eee`, `mmm`. Those can be removed on a rule with no risk of changing what
/// the user said, at no latency cost — so they should not wait for a model
/// that might be unavailable, slow, or switched off.
enum FillerFilter {

    /// The hesitation list and the "these are real words" exclusions are both
    /// Turkish. On English it removes nothing — `um` and `uh` are not in the
    /// list — so running it elsewhere is inert rather than harmful, but it is
    /// still not doing the job the caller thinks it is.
    static func isSupported(language: String) -> Bool {
        language.lowercased().hasPrefix("tr")
    }

    /// Pure hesitation sounds. Every entry is a vowel or nasal run that
    /// carries no lexical meaning in Turkish.
    ///
    /// `ya` and `ha` are excluded on purpose: both are ordinary words.
    private static let hesitations: Set<String> = [
        "ı", "ıı", "ııı", "ıııı",
        "e", "ee", "eee", "eeee",
        "a", "aa", "aaa", "aaaa",
        "o", "oo", "ooo",
        "ö", "öö", "ööö",
        "ü", "üü", "üüü",
        "m", "mm", "mmm", "mmmm",
        "hm", "hmm", "hmmm",
        "ıh", "ıhı", "hı", "hıı",
        "ee-", "ıı-", "şşş", "sss",
    ]

    /// Strip hesitation tokens and tidy the punctuation they leave behind.
    ///
    /// A single-letter token is only dropped when it is a bare vowel with no
    /// suffix and no punctuation attached — `o` as a hesitation looks exactly
    /// like `o` the pronoun, so it is kept whenever anything suggests it is
    /// being used as a word.
    static func strip(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var removals: [Range<String.Index>] = []
        for (index, token) in tokens.enumerated() {
            guard token.suffix.isEmpty else { continue }
            let folded = PhoneticKey.lowercasedTurkish(token.stem)
            guard hesitations.contains(folded) else { continue }

            // A one-letter vowel is far more likely to be the pronoun `o` or
            // the conjunction `a` than a hesitation, unless it repeats or the
            // surrounding text marks it off.
            if folded.count == 1 && !isClearlyHesitation(at: index, in: tokens) { continue }

            removals.append(token.range)
        }

        guard !removals.isEmpty else { return text }

        var result = text
        for range in removals.reversed() {
            result.replaceSubrange(range, with: "")
        }
        return tidy(result)
    }

    /// True when a one-letter token sits next to another hesitation, which is
    /// what a stumble actually looks like: "ı ı yarın".
    private static func isClearlyHesitation(at index: Int, in tokens: [Tokenizer.Token]) -> Bool {
        let neighbours = [index - 1, index + 1].filter { $0 >= 0 && $0 < tokens.count }
        return neighbours.contains { neighbour in
            let folded = PhoneticKey.lowercasedTurkish(tokens[neighbour].stem)
            return hesitations.contains(folded) && tokens[neighbour].suffix.isEmpty
        }
    }

    /// Collapse the whitespace and stranded punctuation left by removal.
    static func tidy(_ text: String) -> String {
        var out = text

        // " ," → "," and " ." → "."
        out = out.replacingOccurrences(
            of: #"\s+([,\.\!\?;:])"#, with: "$1", options: .regularExpression)
        // ",," → "," and ", ," → ","
        out = out.replacingOccurrences(
            of: #"([,;:])(\s*[,;:])+"#, with: "$1", options: .regularExpression)
        // A clause that now starts with a comma.
        out = out.replacingOccurrences(
            of: #"(^|[\.\!\?]\s*)[,;:]\s*"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
