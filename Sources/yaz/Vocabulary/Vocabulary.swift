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
///
/// **This layer runs only for a language with a lexicon** (`Lexicon`: Turkish
/// and German). The guard that stops a false replacement is a list of ordinary
/// words that may not be overwritten on skeleton evidence. Point it at a
/// language without one and that guard protects nothing: measured on English,
/// `into main` became `Notion` and `merged` became `merge`. Running it there
/// is worse than not running it, so `isSupported(language:)` exists and
/// callers must honour it.
struct Vocabulary: Sendable {

    /// The default dictation language, and the one whose lexicon is used
    /// when none is given.
    static let lexiconLanguage = "tr"

    /// Whether correction can run safely for `language`.
    static func isSupported(language: String) -> Bool {
        Lexicon.forLanguage(language) != nil
    }

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

    /// A replacement the user undid: what was heard must never again become
    /// this term. Learned from corrections (`Learner`).
    struct Block: Codable, Sendable, Equatable, Hashable {
        let heard: String
        let term: String
    }

    private let entries: [Entry]
    /// The ordinary words of the dictation language, protected from
    /// skeleton matches.
    private let lexicon: Lexicon
    /// Blocks keyed by normalized heard text and lowercased term.
    private let blockedKeys: Set<String>
    private let blocked: [Block]
    private let language: String

    /// The same vocabulary with `extra` terms after the existing ones (which
    /// win ties), keeping thresholds, blocks and language. For terms that
    /// apply to one dictation only (`ScreenContext`).
    func adding(_ extra: [VocabularyTerm]) -> Vocabulary {
        guard !extra.isEmpty else { return self }
        return Vocabulary(
            terms: terms + extra, threshold: threshold, skeletonThreshold: skeletonThreshold,
            blocked: blocked, language: language)
    }

    private static func blockKey(heard: String, term: String) -> String {
        PhoneticKey.normalize(heard) + "\u{1F}" + term.lowercased()
    }

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
        skeletonThreshold: Double = Vocabulary.defaultSkeletonThreshold,
        blocked: [Block] = [],
        language: String = Vocabulary.lexiconLanguage
    ) {
        self.terms = terms
        self.lexicon = Lexicon.forLanguage(language) ?? .turkish
        self.threshold = threshold
        self.skeletonThreshold = skeletonThreshold
        self.blockedKeys = Set(blocked.map { Self.blockKey(heard: $0.heard, term: $0.term) })
        self.blocked = blocked
        self.language = language

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
            // Where the term is already written as it should be. No window
            // may overlap one: "Fitbit Air'ın" is not a mangled "Fitbit",
            // and "Fitbit" before "Air" is not a short "Fitbit Air".
            let written = Self.occurrences(of: entry.canonical, in: tokens)
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
                    guard !written.intersects(integersIn: start..<(start + span)) else { continue }
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
        /// Replaces the last token's apostrophe suffix: a Turkish ending the
        /// transcript wrote without one ("Notiona" → "Notion'a").
        var suffix: String? = nil
    }

    /// What one spelling of a window says about one entry.
    private enum Evidence {
        /// The window already is the term.
        case same
        case match(score: Double, kind: Correction.Kind)
        case none
    }

    /// Case endings Turkish writes after an apostrophe on a proper noun, and
    /// a transcript often writes without one. Longest first.
    private static let turkishEndings = [
        "nın", "nin", "nun", "nün", "dan", "den", "tan", "ten", "yla", "yle",
        "ya", "ye", "yı", "yi", "yu", "yü", "da", "de", "ta", "te", "la", "le",
        "ın", "in", "un", "ün", "na", "ne", "a", "e", "ı", "i", "u", "ü",
    ]

    private func score(
        window: [Tokenizer.Token], start: Int, span: Int, entry: Entry
    ) -> Match? {
        let stems = window.map(\.stem)
        guard !stems.joined().trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let original = window.map(\.core).joined(separator: " ")
        // Protection is decided on the words as heard: cutting an ending off
        // "sonra" must not turn it into something the lexicon does not know.
        let isProtected = lexicon.containsCommonWord(stems)
        let full = evidence(stems, entry: entry, isProtected: isProtected)
        // Already correct — nothing to do, and reporting it as a correction
        // would be noise.
        if case .same = full { return nil }

        // A Turkish ending without an apostrophe: the term may be the stem
        // under it. Only in Turkish, and only when the transcript wrote no
        // apostrophe suffix of its own.
        let last = window[window.count - 1]
        var endsInSuffix = false
        var cut: Match?
        // The cut stem is, on its own, the term's last word: "kod" under
        // "koda" for Claude Code, "Cloud" under "Cloudu" for Claude. A vowel
        // ending leaves the skeleton as it was, so only this tells a real
        // ending from the term's own last letters ("C.I.P. eline").
        var cutCompletesTerm = false
        let lastWordSkeleton = PhoneticKey.skeleton(
            entry.canonical.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "")
        if lexicon.language == "tr", last.suffix.isEmpty {
            let lower = PhoneticKey.lowercasedTurkish(last.stem)
            for ending in Self.turkishEndings
            where lower.hasSuffix(ending) && lower.count - ending.count >= Vocabulary.minimumTermLength {
                endsInSuffix = true
                let stem = String(last.stem.dropLast(ending.count))
                let written = String(last.stem.suffix(ending.count))
                switch evidence(Array(stems.dropLast()) + [stem], entry: entry, isProtected: isProtected) {
                case .same:
                    // The term itself with a Turkish ending. A lowercase term
                    // is used as a Turkish word ("mergele", "deployla") and is
                    // already right; a name gets its apostrophe.
                    guard entry.canonical.first?.isUppercase == true else { return nil }
                    return Match(
                        start: start, span: span, canonical: entry.canonical, score: 1.0,
                        kind: .exact, original: original, suffix: "'" + written)
                case .match(let value, let kind):
                    // The full-form reading of a stem beats a skeleton one,
                    // whatever the numbers: "Taypskript" (normalized) is the
                    // stem of "Taypskripte", not "Taypskrip" (skeleton).
                    let candidate = Match(
                        start: start, span: span, canonical: entry.canonical, score: value,
                        kind: kind, original: original, suffix: "'" + written)
                    if let current = cut, Self.rank(current) >= Self.rank(candidate) { break }
                    cut = candidate
                    let stemSkeleton = PhoneticKey.skeleton(stem)
                    cutCompletesTerm = stemSkeleton.count >= 2 && stemSkeleton == lastWordSkeleton
                case .none:
                    break
                }
            }
        }

        switch full {
        case .match(let value, let kind):
            // The stem explains the word better than the whole word does:
            // "Körsır" (0.999) under "Körsırda" (0.799).
            if let cut,
               cut.kind == .normalized || cut.score > value
                || (cutCompletesTerm && abs(cut.score - value) < 1e-9) {
                return cut
            }
            // A skeleton guess on a word wearing a Turkish ending that the
            // stem does not explain: "inputuna" is not Notion, and neither
            // is "inputun". One word only: across several, the last one's
            // ending is usually the term's own mangled end ("C.I.P. eline",
            // "Puhrıkı Esti").
            if kind == .skeleton, endsInSuffix, window.count == 1 { return nil }
            return Match(
                start: start, span: span, canonical: entry.canonical, score: value,
                kind: kind, original: original)
        case .same, .none:
            // A stem alone may find a term only on full-form evidence: on a
            // skeleton, "satır" under "satırın" became Sentry.
            guard let cut, cut.kind == .normalized else { return nil }
            return cut
        }
    }

    /// Token positions covered by `canonical` written exactly (ignoring
    /// case), word for word.
    private static func occurrences(of canonical: String, in tokens: [Tokenizer.Token]) -> IndexSet {
        let words = canonical.split(whereSeparator: \.isWhitespace).map(String.init)
        var covered = IndexSet()
        guard !words.isEmpty, tokens.count >= words.count else { return covered }
        for start in 0...(tokens.count - words.count) {
            let matches = words.indices.allSatisfy {
                tokens[start + $0].stem.compare(words[$0], options: .caseInsensitive) == .orderedSame
            }
            if matches { covered.insert(integersIn: start..<(start + words.count)) }
        }
        return covered
    }

    /// Lowercase, without diacritics or the dotless ı.
    private static func letters(_ text: String) -> String {
        PhoneticKey.lowercasedTurkish(text).replacingOccurrences(of: "ı", with: "i")
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func rank(_ match: Match) -> (Int, Double) {
        (match.kind == .skeleton ? 0 : 1, match.score)
    }

    private func evidence(_ window: [String], entry: Entry, isProtected: Bool) -> Evidence {
        let stems = window.joined(separator: " ")

        // Compared with the canonical form, not the entry's spelling: an
        // alias heard exactly is the clearest match there is, and skipping
        // it meant a learned alias only ever worked when the canonical form
        // caught the word anyway.
        if stems.compare(entry.canonical, options: .caseInsensitive) == .orderedSame {
            return .same
        }

        let normalizedWindow = PhoneticKey.normalize(stems)
        guard !normalizedWindow.isEmpty else { return .none }

        // The user undid this exact replacement before.
        if !blockedKeys.isEmpty,
           blockedKeys.contains(Self.blockKey(heard: stems, term: entry.canonical)) {
            return .none
        }

        // A window holding an ordinary word of the language is something the
        // user plainly said. It may still be replaced, but only on near-exact
        // evidence — never on a skeleton guess, which is what turned "Doktor"
        // into "Docker" and "sonra" into "Sentry".
        let limit = max(
            entry.minSimilarity ?? threshold,
            isProtected ? lexicon.protectedWordThreshold : 0)

        let full = EditDistance.similarity(normalizedWindow, entry.normalized)
        if full >= limit {
            // For a word of the language, near-exact means as written, not
            // only as it sounds: "kursör" sounds exactly like Cursor and is
            // the Turkish word for the pointer. Letters count, their marks
            // do not ("kahvaltı" is still "Kahvalti").
            if isProtected {
                let written = EditDistance.similarity(Self.letters(stems), Self.letters(entry.canonical))
                guard written >= lexicon.protectedWordThreshold else { return .none }
            }
            return .match(score: full, kind: .normalized)
        }

        // Skeleton evidence is never enough to overrule a real Turkish word.
        guard !isProtected else { return .none }

        // Skeleton comparison only where there are enough consonants to carry
        // meaning; a two-letter skeleton matches almost anything.
        let windowSkeleton = PhoneticKey.skeleton(stems)
        guard entry.skeleton.count >= 3, windowSkeleton.count >= 3 else { return .none }

        // The leading consonant is the most stable part of the signal:
        // epenthesis inserts vowels and doubles consonants, but it does not
        // change what the word starts with. Requiring it to agree is what
        // separates "Redis"/"neredeyse" (r vs n — reject) from
        // "Slack"/"Sılacık" (s vs s — allow), which score identically.
        guard windowSkeleton.first == entry.skeleton.first else { return .none }

        let skeletal = EditDistance.similarity(windowSkeleton, entry.skeleton)
        let skeletonLimit = entry.minSimilarity ?? skeletonThreshold
        if skeletal >= skeletonLimit {
            // Report the skeleton score, but keep it below a full-form match
            // of the same value so overlap resolution prefers the
            // better-evidenced one.
            return .match(score: skeletal - 0.001, kind: .skeleton)
        }
        return .none
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

            let replacement = first.leading + match.canonical + (match.suffix ?? last.suffix)
                + last.trailing
            let before = String(text[range])
            result.replaceSubrange(range, with: replacement)

            corrections.append(Correction(
                from: before, to: replacement, score: match.score, matchedBy: match.kind))
        }

        return Result(text: result, corrections: corrections.reversed())
    }
}
