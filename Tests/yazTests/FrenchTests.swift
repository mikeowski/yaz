import Foundation
import Testing
@testable import yaz

@Suite("French — a main language with the full pack")
struct FrenchTests {

    private let nb = FrenchNumbers.narrowSpace

    private func french(_ terms: [String]) -> Vocabulary {
        Vocabulary(terms: terms.map { VocabularyTerm(canonical: $0) }, language: "fr")
    }

    @Test("the French set scores zero")
    func evaluation() {
        let score = Evaluator.score(language: "fr")
        #expect(score.value == 0, "\(score.offenders)")
    }

    @Test(
        "everyday words that score like a term are left alone",
        arguments: [
            ("Je me suis inscrit à un cours.", "Cursor"),
            ("Le docteur m'a dit de rester au lit.", "Docker"),
            ("J'ai lavé les rideaux.", "Redis"),
            ("La réunion a été déplacée.", "deploy"),
            ("Mes chaussures sont serrées.", "Sentry"),
            ("Le curseur est à la fin de la ligne.", "Cursor"),
        ])
    func protectedWords(_ sentence: String, _ term: String) {
        #expect(!french([term]).correct(sentence).didChange)
    }

    @Test("elided words are judged by what follows the apostrophe")
    func elision() {
        #expect(FrenchLexicon.isCommon("l'école"))
        #expect(FrenchLexicon.isCommon("d\u{2019}électricité"))
        #expect(!FrenchLexicon.isCommon("Kubernetes"))
    }

    @Test("misheard terms are repaired")
    func repair() {
        #expect(french(["Slack"]).correct("Préviens-moi sur Slaque quand c'est fini.").text.contains("Slack"))
        #expect(french(["Kubernetes"]).correct("Le cluster Kubernetis est tombé.").text.contains("Kubernetes"))
    }

    @Test("numbers: each evaluation case", arguments: EvalCorpus.French.numbersConvert.map { [$0.heard, $0.expected] })
    func numbers(_ pair: [String]) {
        #expect(FrenchNumbers.format(pair[0]).text == pair[1])
    }

    @Test("numbers: articles, small counts and idioms stay words", arguments: EvalCorpus.French.numbersUnchanged)
    func numberLookAlikes(_ sentence: String) {
        #expect(FrenchNumbers.format(sentence).text == sentence)
    }

    @Test("counting in twenties")
    func twenties() {
        #expect(FrenchNumbers.format("soixante et onze ans").text == "71 ans")
        #expect(FrenchNumbers.format("quatre-vingt-dix-neuf tests").text == "99 tests")
        #expect(FrenchNumbers.format("quatre-vingt-un tests").text == "81 tests")
    }

    @Test("commands, with the space French puts before ? and !")
    func commands() {
        let set = CommandSet.french
        #expect(VoiceCommands.apply("Tu viens ce soir point d'interrogation", set: set).text == "Tu viens ce soir\(nb)?")
        #expect(VoiceCommands.apply("Merci, à la ligne. À demain.", set: set).text == "Merci\nÀ demain.")
        #expect(VoiceCommands.apply("Il manque un point d'interrogation.", set: set).text == "Il manque un point d'interrogation.")
        #expect(VoiceCommands.control("Efface ça.", set: set) == .undoLast)
    }

    @Test("the whole pipeline in French")
    func pipeline() async {
        var config = Config()
        config.language = "fr"
        config.vocabulary = [VocabularyTerm(canonical: "Slack")]
        let output = await TranscriptPipeline(config: config)
            .process("euh préviens-moi sur Slaque, le budget est de quinze mille euros.")
        #expect(output.text == "préviens-moi sur Slack, le budget est de 15\(nb)000 euros.")
    }
}
