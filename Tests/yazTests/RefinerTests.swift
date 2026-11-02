import Foundation
import Testing

@testable import yaz

/// Stands in for the on-device model so the guards can be tested on any
/// machine, including one where Apple Intelligence is switched off.
private struct StubBackend: RefinerBackend {
    let response: String
    var delay: Duration = .zero
    var failure: Error?

    func rewrite(_ text: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return response
    }
}

private struct Boom: Error {}

@Suite("FillerFilter — cleanup with no model and no risk")
struct FillerFilterTests {

    @Test("hesitation sounds are dropped")
    func stripsHesitations() {
        #expect(FillerFilter.strip("ıı yarın toplantı var") == "yarın toplantı var")
        #expect(FillerFilter.strip("yarın eee toplantı var") == "yarın toplantı var")
        #expect(FillerFilter.strip("mmm tamam") == "tamam")
    }

    @Test("several hesitations are dropped at once")
    func stripsMultiple() {
        #expect(FillerFilter.strip("ıı yarın ee saat ikide mmm toplantı")
            == "yarın saat ikide toplantı")
    }

    /// These are real words and cannot be dropped without context. That
    /// decision belongs to the language model.
    @Test(
        "gerçek kelimeler korunur — bağlam gerektiren dolgu sözcükleri LLM'in işi",
        arguments: [
            "yani böyle oldu",
            "şey lazım bize",
            "hani söylemiştim",
            "işte bu kadar",
            "ya sen ne dedin",
            "ha tamam anladım",
        ]
    )
    func keepsRealWords(_ text: String) {
        #expect(FillerFilter.strip(text) == text)
    }

    /// "o" is a pronoun and "a" a particle. A single-letter vowel counts as a
    /// hesitation only when it sits next to another one.
    @Test("a lone single-letter vowel is not dropped")
    func singleVowelKept() {
        #expect(FillerFilter.strip("o proje için") == "o proje için")
        #expect(FillerFilter.strip("bu o değil") == "bu o değil")
    }

    @Test("consecutive single-letter vowels count as hesitation")
    func adjacentSingleVowelsAreHesitation() {
        #expect(FillerFilter.strip("ı ı yarın gidiyorum") == "yarın gidiyorum")
    }

    @Test("a word carrying a suffix is never dropped")
    func suffixedWordsKept() {
        #expect(FillerFilter.strip("E'nin anlamı") == "E'nin anlamı")
    }

    @Test("punctuation is tidied after the removal")
    func tidiesPunctuation() {
        #expect(FillerFilter.strip("yarın ıı , toplantı var") == "yarın, toplantı var")
        #expect(FillerFilter.strip("ıı, yarın toplantı") == "yarın toplantı")
    }

    @Test("text comes back untouched when nothing changed")
    func noChangeIsIdentity() {
        let text = "Yarın saat ikide toplantımız var."
        #expect(FillerFilter.strip(text) == text)
    }

    @Test("empty input does not crash")
    func emptyInput() {
        #expect(FillerFilter.strip("") == "")
        #expect(FillerFilter.strip("   ").isEmpty)
    }
}

@Suite("RefinementGuard — model output has to earn its way in")
struct RefinementGuardTests {

    static let original = "ıı yarın saat ikide toplantımız var hani o proje için hazırlık lazım"

    @Test("a reasonable cleanup is accepted")
    func acceptsPlausibleCleanup() {
        let candidate = "Yarın saat ikide toplantımız var. O proje için hazırlık lazım."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) == nil)
    }

    @Test("empty output is rejected")
    func rejectsEmpty() {
        #expect(RefinementGuard.reject(original: Self.original, candidate: "") != nil)
    }

    /// Summarising is the likeliest misbehaviour: the model reads "tidy" as
    /// "shorten".
    @Test("summarising is rejected")
    func rejectsSummary() {
        let reason = RefinementGuard.reject(original: Self.original, candidate: "Toplantı var.")
        #expect(reason != nil)
    }

    @Test("output that adds material is rejected")
    func rejectsAddition() {
        let candidate = Self.original
            + " Ayrıca size yardımcı olabileceğim başka bir konu var mı? Umarım bu yardımcı olmuştur."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) != nil)
    }

    @Test("output that answers the question is rejected")
    func rejectsAnswering() {
        let question = "ıı yarın hava nasıl olacak acaba sence"
        let answer = "Yarın hava güneşli ve sıcak olacak, sıcaklık 25 derece civarında."
        #expect(RefinementGuard.reject(original: question, candidate: answer) != nil)
    }

    @Test("losing content words is rejected")
    func rejectsContentLoss() {
        let candidate = "Yarın saat ikide bir şeyler yapacağız herhalde böyle."
        #expect(RefinementGuard.reject(original: Self.original, candidate: candidate) != nil)
    }

    @Test("fixing punctuation and capitalisation does not count as loss")
    func punctuationOnlyIsFullRetention() {
        let source = "toplantımızı ertelediler proje hazırlığını bekliyoruz"
        let candidate = "Toplantımızı ertelediler. Proje hazırlığını bekliyoruz."
        #expect(RefinementGuard.contentRetention(original: source, candidate: candidate) == 1)
        #expect(RefinementGuard.reject(original: source, candidate: candidate) == nil)
    }

    @Test("small suffix differences are tolerated")
    func minorSuffixDriftTolerated() {
        let source = "yarınki toplantıya hazırlığımızı bitirelim"
        let candidate = "Yarınki toplantıya hazırlığımızı bitirelim."
        #expect(RefinementGuard.contentRetention(original: source, candidate: candidate) >= 0.75)
    }

    /// Changing voice (active → passive) changes the meaning; that is not a
    /// cleanup. Measured: 40% of the content words in this candidate are
    /// unrecognisable.
    @Test("an active/passive voice change is rejected")
    func rejectsVoiceChange() {
        let source = "toplantımızı ertelediler proje hazırlığını bekliyoruz"
        let candidate = "Toplantımız ertelendi. Proje hazırlığı bekleniyor."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) != nil)
    }

    /// Found by measurement: the model correctly dropped "yani" and "hani",
    /// and the guard called that 30% content loss and threw away a good
    /// cleanup. Words we asked the model to remove cannot count as lost.
    @Test("dropping contextual fillers does not count as loss")
    func removingFillerWordsIsNotLoss() {
        let source = "yarın şey saat ikide yani toplantımız var hani o proje için hazırlık yapmamız lazım"
        let candidate = "Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) == nil)
    }

    @Test("real content loss is still caught")
    func realContentLossStillCaught() {
        let source = "yarın saat ikide toplantımız var proje için hazırlık yapmamız lazım"
        let candidate = "Yarın toplantı var."
        #expect(RefinementGuard.reject(original: source, candidate: candidate) != nil)
    }

    @Test("a model preamble and surrounding quotes are stripped")
    func cleansWrappers() {
        #expect(RefinementGuard.clean("\"Yarın toplantı var.\"") == "Yarın toplantı var.")
        #expect(RefinementGuard.clean("İşte temizlenmiş metin:\nYarın toplantı var.")
            == "Yarın toplantı var.")
    }

    @Test("whitespace is trimmed")
    func trims() {
        #expect(RefinementGuard.clean("  metin  ") == "metin")
    }
}

@Suite("Refiner — never lose the dictation, under any circumstance")
struct RefinerTests {

    static let messy = "ıı yarın saat ikide toplantımız var hani o proje için hazırlık lazım"

    @Test("off mode does not touch the text")
    func offIsIdentity() async {
        let result = await Refiner(mode: .off, backend: StubBackend(response: "x")).refine(Self.messy)
        #expect(result.text == Self.messy)
        #expect(!result.changed)
    }

    @Test("fillers mode never calls the model")
    func fillersSkipsModel() async {
        let refiner = Refiner(mode: .fillers, backend: StubBackend(response: "MODEL ÇAĞRILDI"))
        let result = await refiner.refine(Self.messy)
        #expect(!result.text.contains("MODEL"))
        #expect(result.text.hasPrefix("yarın"))
        #expect(result.changed)
    }

    @Test("llm mode accepts good output")
    func llmAcceptsGoodOutput() async {
        let good = "Yarın saat ikide toplantımız var. O proje için hazırlık lazım."
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: good))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == good)
        #expect(result.rejection == nil)
    }

    /// The behaviour that matters most: a cleanup step must never cost the
    /// dictation.
    @Test("a model error falls back to the deterministic result")
    func fallsBackOnError() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "", failure: Boom()))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("a model timeout falls back to the deterministic result")
    func fallsBackOnTimeout() async {
        // The model takes 30 s; the refiner must give up long before. The
        // margin is wide on purpose: tests run in parallel on a shared pool,
        // and a loaded CI runner has delayed this wake-up past 3 s.
        let slow = StubBackend(response: "geç kaldı", delay: .seconds(30))
        let refiner = Refiner(mode: .llm, timeout: .milliseconds(120), backend: slow)

        let started = Date()
        let result = await refiner.refine(Self.messy)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("a guard rejection falls back to the deterministic result")
    func fallsBackOnRejection() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "Toplantı."))
        let result = await refiner.refine(Self.messy)
        #expect(result.text == FillerFilter.strip(Self.messy))
        #expect(result.rejection != nil)
    }

    @Test("empty text never calls the model")
    func emptyTextSkipsModel() async {
        let refiner = Refiner(mode: .llm, backend: StubBackend(response: "uydurma"))
        let result = await refiner.refine("   ")
        #expect(!result.text.contains("uydurma"))
    }

    @Test("off and fillers are available on every machine")
    func cheapModesAlwaysAvailable() {
        #expect(Refiner.availability(for: .off).isAvailable)
        #expect(Refiner.availability(for: .fillers).isAvailable)
    }
}

/// The layer that damaged English before the boundary existed.
///
/// `FillerFilter.isSupported` was defined and never called: `Refiner` had no
/// language at all, so it ran the Turkish hesitation list and the Turkish model
/// instructions on every transcript regardless of language — while the README
/// claimed both were skipped. These tests exist so the gate cannot be removed
/// without a failure.
@Suite("Refiner — the Turkish-only boundary")
struct RefinerLanguageTests {

    @Test("Turkish text is cleaned")
    func cleansTurkish() async {
        let refiner = Refiner(mode: .fillers, language: "tr")
        let result = await refiner.refine("ıı yarın saat ikide toplantı var")
        #expect(result.text == "yarın saat ikide toplantı var")
        #expect(result.changed)
    }

    @Test("a Turkish regional tag still counts as Turkish")
    func acceptsRegionalTag() async {
        let refiner = Refiner(mode: .fillers, language: "tr-TR")
        let result = await refiner.refine("ıı yarın toplantı var")
        #expect(result.text == "yarın toplantı var")
    }

    @Test(
        "languages without fillers are returned untouched",
        arguments: ["de", "fr", "ru", "ja"])
    func skipsOtherLanguages(language: String) async {
        let text = "a lot of people say um I think we should merge this"
        let result = await Refiner(mode: .fillers, language: language).refine(text)
        #expect(result.text == text)
        #expect(!result.changed)
    }

    /// The expensive half of the boundary. The model's instructions belong
    /// to a language pack, so a language without one must not reach it, and
    /// the stub proves the call never happens rather than merely that the
    /// output was discarded afterwards.
    @Test("the model is never called for a language without a pack")
    func doesNotReachTheModelWithoutAPack() async {
        let backend = StubBackend(response: "MODEL WAS CALLED")
        let refiner = Refiner(mode: .llm, language: "ja", backend: backend)
        let result = await refiner.refine("um I think we should merge this")
        #expect(result.text == "um I think we should merge this")
        #expect(result.rejection == nil)
    }

    @Test("English hesitations go, English words stay")
    func englishFillers() async {
        let result = await Refiner(mode: .fillers, language: "en-US")
            .refine("a lot of people say um I think uh we should merge this")
        #expect(result.text == "a lot of people say I think we should merge this")
    }

    @Test("the model is called for English, with English instructions")
    func reachesTheModelInEnglish() async {
        let backend = StubBackend(response: "I think we should merge this.")
        let result = await Refiner(mode: .llm, language: "en", backend: backend)
            .refine("um I think we should merge this")
        #expect(result.text == "I think we should merge this.")
        #expect(LanguagePack.english.refineInstructions?.hasPrefix("You clean up dictated English") == true)
    }

    @Test("the model is still called for Turkish")
    func reachesTheModelInTurkish() async {
        let backend = StubBackend(response: "Yarın saat ikide toplantımız var.")
        let refiner = Refiner(mode: .llm, language: "tr", backend: backend)
        let result = await refiner.refine("ıı yarın saat ikide toplantımız var")
        #expect(result.text == "Yarın saat ikide toplantımız var.")
        #expect(result.changed)
    }

    /// The whole pipeline, not just the refiner: this is the path a real
    /// dictation takes.
    @Test("the pipeline leaves a clean English transcript byte-identical")
    func pipelineLeavesEnglishAlone() async {
        let text = "I merged the pull request into main after CI turned green"
        let pipeline = TranscriptPipeline(
            vocabulary: Vocabulary(terms: ["Slack", "pull request", "Notion"]
                .map { VocabularyTerm(canonical: $0) }, language: "en"),
            refiner: Refiner(mode: .fillers, language: "en"),
            language: "en")
        let output = await pipeline.process(text)
        #expect(output.text == text)
        #expect(output.corrections.isEmpty)
        #expect(!output.refined)
    }
}
