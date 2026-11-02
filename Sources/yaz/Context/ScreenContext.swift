import Foundation

/// Terms taken from what is on screen when the key goes down.
///
/// A developer dictates about what they are looking at: the pull request,
/// the Slack thread, the error. Its names (`Kubernetes`, `PaymentGateway`,
/// `Vercel`) are on screen, and Whisper mangles them like any other. So for
/// one dictation, the words that look like terms join the vocabulary.
///
/// Nobody vetted them, so two guards apply. Each counts as a term only above
/// a stricter threshold (`minSimilarity`). And the whole list goes through
/// the fixed evaluation's everyday sentences first: a word that would change
/// one of them is dropped, in the manner of `Evaluator.gate`. Nothing is
/// saved; the next dictation reads the screen again.
enum ScreenContext {

    /// A screen word must sound this close to replace what was heard.
    static let minSimilarity = 0.86
    static let maxTerms = 40
    static let minimumLength = 4

    /// Candidate terms in `text`, most frequent first. A word qualifies if it
    /// is ASCII, at least four letters, and looks like a name rather than
    /// prose: an inner capital or digit (`GitHub`, `useState`, `S3Bucket`),
    /// all capitals (`CORS`), or a capital and not an ordinary word of the
    /// dictation language. Two capitalised words in a row also count as one
    /// term ("Pull Request").
    static func terms(
        in text: String, lexicon: Lexicon, excluding known: [VocabularyTerm] = []
    ) -> [VocabularyTerm] {
        let knownKeys = Set(known.flatMap { [$0.canonical] + $0.aliases }.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        var order: [String] = []
        func add(_ term: String, weight: Int = 1) {
            guard !knownKeys.contains(term.lowercased()) else { return }
            if counts[term] == nil { order.append(term) }
            counts[term, default: 0] += weight
        }

        let words = text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
            .map(String.init)
        var previousCapital: String?
        for word in words {
            let isCandidate = looksLikeTerm(word, lexicon: lexicon)
            if isCandidate { add(word) }
            let capitalised = isCandidate && word.first?.isUppercase == true
                && word.dropFirst().allSatisfy { $0.isLowercase }
            if capitalised, let previous = previousCapital, previous != word {
                add(previous + " " + word, weight: 2)
            }
            previousCapital = capitalised ? word : nil
        }

        let ranked = order.enumerated().sorted {
            let a = counts[$0.element]!, b = counts[$1.element]!
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        return ranked.prefix(maxTerms).map {
            VocabularyTerm(canonical: $0, minSimilarity: minSimilarity)
        }
    }

    static func looksLikeTerm(_ word: String, lexicon: Lexicon) -> Bool {
        guard word.count >= minimumLength,
              word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              word.first?.isLetter == true
        else { return false }
        let rest = word.dropFirst()
        if rest.contains(where: { $0.isUppercase || $0.isNumber || $0 == "_" }) { return true }
        guard word.first?.isUppercase == true else { return false }
        return !lexicon.isCommon(word)
    }

    /// The terms that leave every everyday sentence of the fixed set alone.
    /// One pass finds the offenders, which are dropped; a second confirms.
    static func vetted(_ terms: [VocabularyTerm], language: String) -> [VocabularyTerm] {
        guard !terms.isEmpty, Vocabulary.isSupported(language: language) else { return [] }
        let sentences = Evaluator.sets
            .filter { language.lowercased().hasPrefix($0.language) }
            .flatMap(\.precision)
        var kept = terms
        for _ in 0..<2 {
            let vocabulary = Vocabulary(terms: kept, language: language)
            var offenders = Set<String>()
            for sentence in sentences {
                for correction in vocabulary.correct(sentence).corrections {
                    for term in kept where correction.to.localizedCaseInsensitiveContains(term.canonical) {
                        offenders.insert(term.canonical)
                    }
                }
            }
            if offenders.isEmpty { return kept }
            kept.removeAll { offenders.contains($0.canonical) }
        }
        return kept
    }
}
