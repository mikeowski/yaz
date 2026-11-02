import Foundation

/// One number for "how good is term repair", and the keep-or-revert decision
/// built on it.
///
/// The metric is `falseMatches × 3 + misses` over `EvalCorpus`, lower is
/// better. A false match costs three times a miss because it is invisible:
/// a missed term stays visibly mangled, a wrong replacement looks like what
/// the user said.
enum Evaluator {

    static let falseMatchWeight = 3

    struct Score: Sendable, Equatable, CustomStringConvertible {
        var falseMatches: Int
        var misses: Int
        var recallCases: Int
        var precisionCases: Int
        /// Sentences that changed when they should not have, for the report.
        var offenders: [String] = []

        var value: Int { falseMatches * Evaluator.falseMatchWeight + misses }

        var description: String {
            "score \(value) (false matches \(falseMatches)/\(precisionCases),"
                + " misses \(misses)/\(recallCases))"
        }
    }

    /// One language's part of the corpus.
    struct LanguageSet: Sendable {
        let language: String
        let riskyTerms: [VocabularyTerm]
        let recall: [(heard: String, expected: String)]
        let precision: [String]
    }

    static let sets: [LanguageSet] = [
        LanguageSet(
            language: "tr", riskyTerms: EvalCorpus.riskyTerms,
            recall: EvalCorpus.recall, precision: EvalCorpus.precision),
        LanguageSet(
            language: EvalCorpus.German.language, riskyTerms: EvalCorpus.German.riskyTerms,
            recall: EvalCorpus.German.recall, precision: EvalCorpus.German.precision),
    ]

    /// Score a vocabulary over the corpus: one language's set, or all of them
    /// summed when `language` is nil (what `yaz eval` reports, since a
    /// threshold or a phonetic rule changes every language at once). `extra`
    /// terms are added to the corpus's own, as a learned rule or a project's
    /// names would be.
    static func score(
        language: String? = nil,
        extra: [VocabularyTerm] = [],
        blocked: [Vocabulary.Block] = [],
        threshold: Double = Vocabulary.defaultThreshold,
        skeletonThreshold: Double = Vocabulary.defaultSkeletonThreshold
    ) -> Score {
        let chosen = sets.filter { set in
            language.map { $0.lowercased().hasPrefix(set.language) } ?? true
        }
        var score = Score(falseMatches: 0, misses: 0, recallCases: 0, precisionCases: 0)
        for set in chosen {
            let vocabulary = Vocabulary(
                terms: EvalCorpus.terms + extra, threshold: threshold,
                skeletonThreshold: skeletonThreshold, blocked: blocked, language: set.language)
            let risky = Vocabulary(
                terms: set.riskyTerms + extra, threshold: threshold,
                skeletonThreshold: skeletonThreshold, blocked: blocked, language: set.language)

            score.recallCases += set.recall.count
            score.precisionCases += set.precision.count * 2
            for (heard, expected) in set.recall
            where !vocabulary.correct(heard).text.contains(expected) {
                score.misses += 1
            }
            for sentence in set.precision {
                for vocab in [vocabulary, risky] {
                    let result = vocab.correct(sentence)
                    if result.didChange {
                        score.falseMatches += 1
                        score.offenders.append(
                            "[\(set.language)] "
                                + result.corrections.map { "\($0.from) → \($0.to)" }
                                .joined(separator: ", "))
                    }
                }
            }
        }
        return score
    }

    /// Whether a learned rule may be kept: it must fix the case it was
    /// learned from, and leave the score no worse than without it.
    static func gate(
        _ candidate: VocabularyTerm, heard: String, existing: [VocabularyTerm] = [],
        language: String = Vocabulary.lexiconLanguage
    ) -> (accepted: Bool, reason: String) {
        let alone = Vocabulary(terms: existing + [candidate], language: language).correct(heard)
        guard alone.text.contains(candidate.canonical) else {
            return (false, "does not fix \"\(heard)\"")
        }
        let before = score(language: language, extra: existing)
        let after = score(language: language, extra: existing + [candidate])
        guard after.value <= before.value else {
            let detail = after.offenders.first.map { ": \($0)" } ?? ""
            return (false, "makes the evaluation worse (\(before.value) → \(after.value))\(detail)")
        }
        return (true, "score \(after.value)")
    }
}
