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

    /// Score a vocabulary over the corpus. `extra` terms are added to the
    /// corpus's own, as a learned rule or a project's names would be.
    static func score(
        extra: [VocabularyTerm] = [],
        blocked: [Vocabulary.Block] = [],
        threshold: Double = Vocabulary.defaultThreshold,
        skeletonThreshold: Double = Vocabulary.defaultSkeletonThreshold
    ) -> Score {
        let vocabulary = Vocabulary(
            terms: EvalCorpus.terms + extra, threshold: threshold,
            skeletonThreshold: skeletonThreshold, blocked: blocked)
        let risky = Vocabulary(
            terms: EvalCorpus.riskyTerms + extra, threshold: threshold,
            skeletonThreshold: skeletonThreshold, blocked: blocked)

        var score = Score(
            falseMatches: 0, misses: 0,
            recallCases: EvalCorpus.recall.count,
            precisionCases: EvalCorpus.precision.count * 2)

        for (heard, expected) in EvalCorpus.recall where !vocabulary.correct(heard).text.contains(expected) {
            score.misses += 1
        }
        for sentence in EvalCorpus.precision {
            for vocab in [vocabulary, risky] {
                let result = vocab.correct(sentence)
                if result.didChange {
                    score.falseMatches += 1
                    score.offenders.append(
                        result.corrections.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
                }
            }
        }
        return score
    }

    /// Whether a learned rule may be kept: it must fix the case it was
    /// learned from, and leave the score no worse than without it.
    static func gate(
        _ candidate: VocabularyTerm, heard: String, existing: [VocabularyTerm] = []
    ) -> (accepted: Bool, reason: String) {
        let alone = Vocabulary(terms: existing + [candidate]).correct(heard)
        guard alone.text.contains(candidate.canonical) else {
            return (false, "does not fix \"\(heard)\"")
        }
        let before = score(extra: existing)
        let after = score(extra: existing + [candidate])
        guard after.value <= before.value else {
            let detail = after.offenders.first.map { ": \($0)" } ?? ""
            return (false, "makes the evaluation worse (\(before.value) → \(after.value))\(detail)")
        }
        return (true, "score \(after.value)")
    }
}
