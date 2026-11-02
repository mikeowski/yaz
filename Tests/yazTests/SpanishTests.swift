import Foundation
import Testing
@testable import yaz

@Suite("Spanish — a main language with the full pack")
struct SpanishTests {

    private func spanish(_ terms: [String]) -> Vocabulary {
        Vocabulary(terms: terms.map { VocabularyTerm(canonical: $0) }, language: "es")
    }

    @Test("the Spanish set scores zero")
    func evaluation() {
        let score = Evaluator.score(language: "es")
        #expect(score.value == 0, "\(score.offenders)")
    }

    @Test(
        "everyday words that score like a term are left alone",
        arguments: [
            ("Me apunté a un curso de cocina.", "Cursor"),
            ("El doctor me dijo que descansara.", "Docker"),
            ("Este fin de semana vamos al pueblo.", "Vercel"),
            ("Abandoné la carrera a mitad.", "Cursor"),
        ])
    func protectedWords(_ sentence: String, _ term: String) {
        #expect(!spanish([term]).correct(sentence).didChange)
    }

    @Test("misheard terms are repaired, with or without accents")
    func repair() {
        #expect(spanish(["Slack"]).correct("Avísame por Eslak cuando acabes.").text == "Avísame por Slack cuando acabes.")
        #expect(spanish(["Kubernetes"]).correct("El clúster de Cubernetes está caído.").text.contains("Kubernetes"))
    }

    @Test("numbers: each evaluation case", arguments: EvalCorpus.Spanish.numbersConvert.map { [$0.heard, $0.expected] })
    func numbers(_ pair: [String]) {
        #expect(SpanishNumbers.format(pair[0]).text == pair[1])
    }

    @Test("numbers: articles, small counts and idioms stay words", arguments: EvalCorpus.Spanish.numbersUnchanged)
    func numberLookAlikes(_ sentence: String) {
        #expect(SpanishNumbers.format(sentence).text == sentence)
    }

    @Test("a question opens with ¿, wherever its sentence starts")
    func openingMarks() {
        let set = CommandSet.spanish
        #expect(VoiceCommands.apply("vienes hoy signo de interrogación", set: set).text == "¿Vienes hoy?")
        #expect(VoiceCommands.apply("Hola. vienes mañana signo de interrogación", set: set).text == "Hola. ¿Vienes mañana?")
        #expect(VoiceCommands.apply("qué bien signo de exclamación", set: set).text == "¡Qué bien!")
        #expect(VoiceCommands.apply("Ahí hay un signo de interrogación.", set: set).text == "Ahí hay un signo de interrogación.")
    }

    @Test("commands match with or without accents")
    func accents() {
        let set = CommandSet.spanish
        #expect(VoiceCommands.apply("Gracias, nueva linea. Hasta mañana.", set: set).text == "Gracias\nHasta mañana.")
        #expect(VoiceCommands.control("Bórralo.", set: set) == .undoLast)
        #expect(VoiceCommands.control("borra eso", set: set) == .undoLast)
    }

    @Test("the whole pipeline in Spanish")
    func pipeline() async {
        var config = Config()
        config.language = "es"
        config.vocabulary = [VocabularyTerm(canonical: "Slack")]
        let output = await TranscriptPipeline(config: config)
            .process("ehm avísame por Eslak, el presupuesto es de quince mil euros.")
        #expect(output.text == "avísame por Slack, el presupuesto es de 15.000 euros.")
    }
}
