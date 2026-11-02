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
    /// For text going into code (`CodeContext`): the user's terms plus the
    /// project's identifiers, the casing and file rules, and no language
    /// model, which would "tidy" `getUserById` into words.
    let codeVocabulary: Vocabulary
    let formatter: CodeFormatter
    let codeRefiner: Refiner
    /// The dictation language. Decides whether the Turkish-specific layers may
    /// run at all.
    let language: String
    /// Write spoken Turkish numbers as digits (`TurkishNumbers`).
    let numbers: Bool

    struct Output: Sendable {
        let text: String
        let corrections: [Vocabulary.Correction]
        /// Casing commands and file mentions applied (code context only).
        var codeChanges: [CodeFormatter.Change] = []
        /// Numbers written as digits.
        var numberChanges: [TurkishNumbers.Change] = []
        let refined: Bool
        /// Set when a refinement was produced and then thrown away.
        let refinementRejected: String?
    }

    init(config: Config, project: ProjectIndex = .empty, learned: LearnedRules = LearnedRules()) {
        // The user's own terms first: they win a tie with a learned rule or a
        // project name. Blocks are repairs the user undid (`Learner`).
        let terms = config.vocabulary + learned.terms
        self.vocabulary = Vocabulary(
            terms: terms, blocked: learned.blocks, language: config.language)
        self.refiner = Refiner(mode: config.refine, language: config.language)
        self.language = config.language
        self.numbers = config.numbers
        self.codeVocabulary = Vocabulary(
            terms: terms + project.vocabularyTerms(), blocked: learned.blocks,
            language: config.language)
        self.formatter = CodeFormatter(
            files: project.files, lexicon: Lexicon.forLanguage(config.language) ?? .turkish)
        self.codeRefiner = Refiner(
            mode: config.refine == .llm ? .fillers : config.refine, language: config.language)
    }

    init(
        vocabulary: Vocabulary, refiner: Refiner, language: String = Vocabulary.lexiconLanguage,
        codeVocabulary: Vocabulary? = nil, formatter: CodeFormatter = CodeFormatter(),
        numbers: Bool = false
    ) {
        self.numbers = numbers
        self.vocabulary = vocabulary
        self.refiner = refiner
        self.language = language
        self.codeVocabulary = codeVocabulary ?? vocabulary
        self.formatter = formatter
        self.codeRefiner = refiner
    }

    /// `code`: the text is going into an editor, a terminal or a coding agent.
    func process(_ text: String, code: Bool = false) async -> Output {
        // Vocabulary correction is Turkish-only, and unsafe rather than merely
        // useless elsewhere: its guard against replacing a real word is a
        // Turkish word list, so on English it turned "into main" into "Notion".
        // Skipping is the correct behaviour, not a limitation to work around.
        let terms = code ? codeVocabulary : vocabulary
        let corrected = Vocabulary.isSupported(language: language)
            ? terms.correct(text)
            : Vocabulary.Result(text: text, corrections: [])
        // Casing and file names do not depend on the language.
        let formatted = code
            ? formatter.format(corrected.text)
            : CodeFormatter.Result(text: corrected.text, changes: [])
        let result = await (code ? codeRefiner : refiner).refine(formatted.text)

        // A refinement that loses a repaired term is not an improvement.
        if result.changed, let lost = firstLostTerm(
            corrections: corrected.corrections, in: result.text
        ) {
            let digits = writeNumbers(formatted.text)
            return Output(
                text: digits.text,
                corrections: corrected.corrections,
                codeChanges: formatted.changes,
                numberChanges: digits.changes,
                refined: false,
                refinementRejected: "post-processing dropped the term \"\(lost)\"")
        }

        // Numbers last, on the final wording: a model asked to tidy "15'te"
        // could spell it out again, but it never sees the digits.
        let digits = writeNumbers(result.text)
        return Output(
            text: digits.text,
            corrections: corrected.corrections,
            codeChanges: formatted.changes,
            numberChanges: digits.changes,
            refined: result.changed,
            refinementRejected: result.rejection)
    }

    private func writeNumbers(_ text: String) -> TurkishNumbers.Result {
        guard numbers, TurkishNumbers.isSupported(language: language) else {
            return TurkishNumbers.Result(text: text, changes: [])
        }
        return TurkishNumbers.format(text)
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
