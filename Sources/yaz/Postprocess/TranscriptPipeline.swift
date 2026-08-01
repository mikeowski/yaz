import Foundation

/// Everything that happens between the engine's output and the user's cursor.
///
/// Order is a decision, not an accident. Vocabulary correction runs **first**
/// so the refiner sees correctly spelled terms: a language model asked to tidy
/// `Sılacık` may well replace it with something else plausible, and then the
/// deterministic layer can no longer recognise it. Handing the model `Slack`
/// instead gives it nothing to fix.
///
/// That leaves the reverse risk — the model quietly dropping or altering a
/// term the vocabulary just repaired — so the pipeline verifies afterwards
/// that every corrected term survived, and discards the refinement if one did
/// not. The deterministic layer wins ties, in both directions.
struct TranscriptPipeline: Sendable {

    let vocabulary: Vocabulary
    let refiner: Refiner

    struct Output: Sendable {
        let text: String
        let corrections: [Vocabulary.Correction]
        let refined: Bool
        /// Set when a refinement was produced and then thrown away.
        let refinementRejected: String?
    }

    init(config: Config) {
        self.vocabulary = Vocabulary(terms: config.vocabulary)
        self.refiner = Refiner(mode: config.refine)
    }

    init(vocabulary: Vocabulary, refiner: Refiner) {
        self.vocabulary = vocabulary
        self.refiner = refiner
    }

    func process(_ text: String) async -> Output {
        let corrected = vocabulary.correct(text)
        let result = await refiner.refine(corrected.text)

        // A refinement that loses a repaired term is not an improvement.
        if result.changed, let lost = firstLostTerm(
            corrections: corrected.corrections, in: result.text
        ) {
            return Output(
                text: corrected.text,
                corrections: corrected.corrections,
                refined: false,
                refinementRejected: "son işleme \"\(lost)\" terimini düşürdü")
        }

        return Output(
            text: result.text,
            corrections: corrected.corrections,
            refined: result.changed,
            refinementRejected: result.rejection)
    }

    /// The first canonical term that the vocabulary inserted but the refined
    /// text no longer contains.
    private func firstLostTerm(
        corrections: [Vocabulary.Correction], in text: String
    ) -> String? {
        let haystack = PhoneticKey.normalize(text)
        for correction in corrections {
            // `to` carries punctuation and suffixes; compare on the term only.
            let needle = PhoneticKey.normalize(correction.to)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            if !haystack.contains(needle) { return correction.to }
        }
        return nil
    }
}
