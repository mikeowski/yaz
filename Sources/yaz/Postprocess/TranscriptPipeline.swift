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
    /// The dictation language. Decides whether the Turkish-specific layers may
    /// run at all.
    let language: String

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
        self.language = config.language
    }

    init(vocabulary: Vocabulary, refiner: Refiner, language: String = Vocabulary.lexiconLanguage) {
        self.vocabulary = vocabulary
        self.refiner = refiner
        self.language = language
    }

    func process(_ text: String) async -> Output {
        // Vocabulary correction is Turkish-only, and unsafe rather than merely
        // useless elsewhere: its guard against replacing a real word is a
        // Turkish word list, so on English it turned "into main" into "Notion".
        // Skipping is the correct behaviour, not a limitation to work around.
        let corrected = Vocabulary.isSupported(language: language)
            ? vocabulary.correct(text)
            : Vocabulary.Result(text: text, corrections: [])
        let result = await refiner.refine(corrected.text)

        // A refinement that loses a repaired term is not an improvement.
        if result.changed, let lost = firstLostTerm(
            corrections: corrected.corrections, in: result.text
        ) {
            return Output(
                text: corrected.text,
                corrections: corrected.corrections,
                refined: false,
                refinementRejected: "post-processing dropped the term \"\(lost)\"")
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
