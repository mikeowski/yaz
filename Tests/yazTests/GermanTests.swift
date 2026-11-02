import Foundation
import Testing
@testable import yaz

/// German speakers mix English terms into their speech the way Turkish
/// speakers do. The same matcher serves them, with a German lexicon as the
/// veto. With no lexicon, the words below were all replaced.
@Suite("German — a second language with its own lexicon")
struct GermanTests {

    private func german(_ terms: [String]) -> Vocabulary {
        Vocabulary(terms: terms.map { VocabularyTerm(canonical: $0) }, language: "de")
    }

    @Test("the German precision set has no false match")
    func precisionSet() {
        let score = Evaluator.score(language: "de")
        #expect(score.falseMatches == 0, "\(score.offenders)")
        #expect(score.precisionCases == EvalCorpus.German.precision.count * 2)
    }

    @Test("the summed score over every language is still zero")
    func allLanguages() {
        let score = Evaluator.score()
        #expect(score.value == 0, "\(score.offenders)")
        #expect(score.precisionCases
            == (EvalCorpus.precision.count + EvalCorpus.German.precision.count) * 2)
    }

    @Test(
        "ordinary German words that score like a term are left alone",
        arguments: [
            ("Der Doktor hat gesagt, ich soll mich ausruhen.", "Docker"),
            ("Morgen fahre ich nach Berlin.", "merge"),
            ("Zum Mittagessen gab es Reis.", "Redis"),
            ("Ich habe mich für einen Kurs angemeldet.", "Cursor"),
            ("Auf der Straße war viel Verkehr.", "Vercel"),
            ("Das Wetter soll am Sonntag besser werden.", "Sentry"),
            ("Der Drucker im Büro ist kaputt.", "Docker"),
        ])
    func protectedWords(_ sentence: String, _ term: String) {
        #expect(!german([term]).correct(sentence).didChange)
    }

    @Test("a German-spelled term is repaired")
    func umlautSpelling() {
        let result = german(["Slack"]).correct("Schreib mir auf Släck.")
        #expect(result.text == "Schreib mir auf Slack.")
    }

    @Test("a joined compound is split back into the term")
    func joinedCompound() {
        let result = german(["pull request"]).correct("Ich habe den Pullrequest geöffnet.")
        #expect(result.text.contains("pull request"))
    }

    @Test("the pipeline repairs terms when dictating German")
    func pipeline() async {
        var config = Config()
        config.language = "de"
        config.vocabulary = [VocabularyTerm(canonical: "Kubernetes")]
        let output = await TranscriptPipeline(config: config).process("Das läuft auf Kubernetis.")
        #expect(output.text.contains("Kubernetes"))
    }

    @Test("a casing command stops at an ordinary German word")
    func casingStops() {
        let formatter = CodeFormatter(lexicon: .german)
        #expect(formatter.format("camel case user name bitte").text == "userName bitte")
    }

    @Test("Datei triggers a file mention like dosya and file")
    func fileWord() {
        #expect(CodeFormatter.isFileWord("Datei"))
        #expect(CodeFormatter.isFileWord("Dateien"))
    }

    @Test("an edit into ordinary German is not learned as a mishearing")
    func learnerUsesGerman() {
        #expect(!Learner.isMishearing(heard: "Morgan", meant: "Morgen", lexicon: .german))
        #expect(Learner.isMishearing(heard: "Släck", meant: "Slack", lexicon: .german))
    }

    @Test("German has no recall cases until some are measured")
    func noInventedRecall() {
        #expect(EvalCorpus.German.recall.isEmpty)
    }
}
