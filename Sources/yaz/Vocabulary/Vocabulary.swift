import Foundation

/// A term the user wants spelled correctly.
struct VocabularyTerm: Sendable, Equatable {
    /// The spelling to produce, with its intended capitalisation: `Slack`,
    /// `pull request`, `PostgreSQL`.
    let canonical: String
    /// Extra spellings that should also map to `canonical`. Useful when a
    /// term is habitually mangled the same way.
    let aliases: [String]
    /// Per-term override of the match threshold. Lower widens recall, higher
    /// demands a closer match.
    let minSimilarity: Double?

    init(canonical: String, aliases: [String] = [], minSimilarity: Double? = nil) {
        self.canonical = canonical
        self.aliases = aliases
        self.minSimilarity = minSimilarity
    }

    var wordCount: Int {
        canonical.split(whereSeparator: \.isWhitespace).count
    }
}

/// Deterministic correction of technical terms in a transcript.
///
/// This layer exists because the two standard fixes were tried and both failed
/// on this stack:
///
/// - **ASR-level biasing.** Feeding the vocabulary to Whisper as
///   `DecodingOptions.promptTokens` — the usual way to teach a decoder your
///   jargon — returns empty output on `large-v3-turbo`, in every variant
///   tried.
/// - **LLM rewriting.** Handing Apple's on-device model the garbled text *and*
///   the target list still left `Sılacık` untouched, at a cost of 1.4 s. A ~3B
///   model does not do fuzzy Turkish-phonetic matching.
///
/// So correction runs on rules, not on a guess: it can only ever produce words
/// the user themselves put in the list.
struct Vocabulary: Sendable {

    /// Default match threshold. Deliberately conservative — replacing a word
    /// the user actually said is worse than leaving a mangled one, because the
    /// mangled one is visible and the replacement is not.
    static let defaultThreshold: Double = 0.78

    /// Skeleton comparison discards vowels, so it carries less evidence and
    /// has to clear a higher bar.
    static let defaultSkeletonThreshold: Double = 0.74

    /// Below this many characters a term is too short to match safely: a
    /// three-letter skeleton collides with half the language.
    static let minimumTermLength = 3

    let terms: [VocabularyTerm]
    var threshold: Double = Vocabulary.defaultThreshold
    var skeletonThreshold: Double = Vocabulary.defaultSkeletonThreshold

    private let entries: [Entry]

    /// One matchable spelling — a canonical form or one of its aliases.
    private struct Entry {
        let canonical: String
        let surface: String
        let normalized: String
        let skeleton: String
        let wordCount: Int
        let minSimilarity: Double?
    }

    init(
        terms: [VocabularyTerm],
        threshold: Double = Vocabulary.defaultThreshold,
        skeletonThreshold: Double = Vocabulary.defaultSkeletonThreshold
    ) {
        self.terms = terms
        self.threshold = threshold
        self.skeletonThreshold = skeletonThreshold

        var entries: [Entry] = []
        for term in terms {
            for surface in [term.canonical] + term.aliases {
                let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= Vocabulary.minimumTermLength else { continue }
                entries.append(Entry(
                    canonical: term.canonical,
                    surface: trimmed,
                    normalized: PhoneticKey.normalize(trimmed),
                    skeleton: PhoneticKey.skeleton(trimmed),
                    wordCount: max(1, trimmed.split(whereSeparator: \.isWhitespace).count),
                    minSimilarity: term.minSimilarity
                ))
            }
        }
        self.entries = entries
    }

    /// What a single replacement did, for logging and for `yaz vocab test`.
    struct Correction: Sendable, Equatable {
        let from: String
        let to: String
        let score: Double
        let matchedBy: Kind

        enum Kind: String, Sendable { case exact, normalized, skeleton }
    }

    struct Result: Sendable, Equatable {
        let text: String
        let corrections: [Correction]
        var didChange: Bool { !corrections.isEmpty }
    }

    /// Correct `text`, returning the new string and what was changed.
    func correct(_ text: String) -> Result {
        guard !entries.isEmpty, !text.isEmpty else {
            return Result(text: text, corrections: [])
        }

        let tokens = Tokenizer.tokenize(text)
        guard !tokens.isEmpty else { return Result(text: text, corrections: []) }

        var candidates: [Match] = []
        for entry in entries {
            // How many transcript words a term may surface as.
            //
            // Whisper splits and joins freely, so a multi-word term needs
            // slack on both sides ("CI pipeline" → "C.I.P. eline"). A
            // *single-word* term does not get the same latitude: letting
            // "merge" match a two-word window turned "ama kargo" into "merge"
            // and swallowed the "et" in "merge et". Only a long single word is
            // plausibly heard as two, so only a long one may widen.
            let mayJoin = entry.wordCount > 1
            let maySplit = entry.wordCount > 1 || entry.normalized.count >= 6
            let lower = mayJoin ? max(1, entry.wordCount - 1) : entry.wordCount
            let upper = min(tokens.count, maySplit ? entry.wordCount + 1 : entry.wordCount)
            guard lower <= upper else { continue }

            for span in lower...upper {
                guard tokens.count >= span else { continue }
                for start in 0...(tokens.count - span) {
                    let window = Array(tokens[start..<(start + span)])
                    if let match = score(window: window, start: start, span: span, entry: entry) {
                        candidates.append(match)
                    }
                }
            }
        }

        guard !candidates.isEmpty else { return Result(text: text, corrections: []) }
        let chosen = resolveOverlaps(candidates)
        guard !chosen.isEmpty else { return Result(text: text, corrections: []) }

        return apply(chosen, to: text, tokens: tokens)
    }

    // MARK: -

    private struct Match {
        let start: Int
        let span: Int
        let canonical: String
        let score: Double
        let kind: Correction.Kind
        let original: String
    }

    private func score(
        window: [Tokenizer.Token], start: Int, span: Int, entry: Entry
    ) -> Match? {
        let stems = window.map(\.stem).joined(separator: " ")
        guard !stems.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let original = window.map(\.core).joined(separator: " ")

        // Already correct — nothing to do, and reporting it as a correction
        // would be noise.
        if stems.compare(entry.surface, options: .caseInsensitive) == .orderedSame {
            return nil
        }

        let normalizedWindow = PhoneticKey.normalize(stems)
        guard !normalizedWindow.isEmpty else { return nil }

        // A window holding an ordinary Turkish word is something the user
        // plainly said. It may still be replaced, but only on near-exact
        // evidence — never on a skeleton guess, which is what turned "Doktor"
        // into "Docker" and "sonra" into "Sentry".
        let isProtected = TurkishLexicon.containsCommonWord(window.map(\.stem))

        let limit = max(
            entry.minSimilarity ?? threshold,
            isProtected ? TurkishLexicon.protectedWordThreshold : 0)

        let full = EditDistance.similarity(normalizedWindow, entry.normalized)
        if full >= limit {
            return Match(
                start: start, span: span, canonical: entry.canonical,
                score: full, kind: .normalized, original: original)
        }

        // Skeleton evidence is never enough to overrule a real Turkish word.
        guard !isProtected else { return nil }

        // Skeleton comparison only where there are enough consonants to carry
        // meaning; a two-letter skeleton matches almost anything.
        let windowSkeleton = PhoneticKey.skeleton(stems)
        guard entry.skeleton.count >= 3, windowSkeleton.count >= 3 else { return nil }

        // The leading consonant is the most stable part of the signal:
        // epenthesis inserts vowels and doubles consonants, but it does not
        // change what the word starts with. Requiring it to agree is what
        // separates "Redis"/"neredeyse" (r vs n — reject) from
        // "Slack"/"Sılacık" (s vs s — allow), which score identically.
        guard windowSkeleton.first == entry.skeleton.first else { return nil }

        let skeletal = EditDistance.similarity(windowSkeleton, entry.skeleton)
        let skeletonLimit = entry.minSimilarity ?? skeletonThreshold
        if skeletal >= skeletonLimit {
            return Match(
                start: start, span: span, canonical: entry.canonical,
                // Report the skeleton score, but keep it below a full-form
                // match of the same value so overlap resolution prefers the
                // better-evidenced one.
                score: skeletal - 0.001, kind: .skeleton, original: original)
        }
        return nil
    }

    /// Greedy best-first selection of non-overlapping matches. Longer spans
    /// win ties so "pull request" beats a lone "request".
    private func resolveOverlaps(_ candidates: [Match]) -> [Match] {
        let ranked = candidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.span != $1.span { return $0.span > $1.span }
            return $0.start < $1.start
        }

        var taken: [Match] = []
        var used = Set<Int>()
        for match in ranked {
            let indices = Set(match.start..<(match.start + match.span))
            guard used.isDisjoint(with: indices) else { continue }
            used.formUnion(indices)
            taken.append(match)
        }
        return taken.sorted { $0.start < $1.start }
    }

    /// Rebuild the string with replacements, preserving what surrounds each
    /// match: leading punctuation, the Turkish apostrophe suffix, and trailing
    /// punctuation all belong to the user, not to us.
    private func apply(
        _ matches: [Match], to text: String, tokens: [Tokenizer.Token]
    ) -> Result {
        var result = text
        var corrections: [Correction] = []

        // Back to front, so earlier ranges stay valid.
        for match in matches.reversed() {
            let first = tokens[match.start]
            let last = tokens[match.start + match.span - 1]
            let range = first.range.lowerBound..<last.range.upperBound

            let replacement = first.leading + match.canonical + last.suffix + last.trailing
            let before = String(text[range])
            result.replaceSubrange(range, with: replacement)

            corrections.append(Correction(
                from: before, to: replacement, score: match.score, matchedBy: match.kind))
        }

        return Result(text: result, corrections: corrections.reversed())
    }
}
