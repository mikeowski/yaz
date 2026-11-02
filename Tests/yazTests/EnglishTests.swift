import Foundation
import Testing
@testable import yaz

@Suite("English — a main language with the full pack")
struct EnglishTests {

    private func english(_ terms: [String]) -> Vocabulary {
        Vocabulary(terms: terms.map { VocabularyTerm(canonical: $0) }, language: "en")
    }

    @Test("the English set scores zero: no false match, every number written")
    func evaluation() {
        let score = Evaluator.score(language: "en")
        #expect(score.value == 0, "\(score.offenders)")
    }

    @Test(
        "everyday words that score like a term are left alone",
        arguments: [
            ("My phone is dead and I left the charger at home.", "Cursor"),
            ("The doctor told me to rest.", "Docker"),
            ("We were all thrilled.", "Vercel"),
            ("Put it into main memory.", "Notion"),
            ("I merged the two lists.", "merge"),
            ("He docked the boat.", "Docker"),
        ])
    func protectedWords(_ sentence: String, _ term: String) {
        #expect(!english([term]).correct(sentence).didChange)
    }

    @Test("a misheard term is repaired")
    func repair() {
        #expect(english(["Slack"]).correct("Ping me on Slak when it's done.").text == "Ping me on Slack when it's done.")
    }

    @Test("a plural keeps its ending")
    func plural() {
        #expect(!english(["pull request"]).correct("I opened two pull requests today.").didChange)
        #expect(!Vocabulary(terms: [VocabularyTerm(canonical: "pull request")]).correct("two pull requests").didChange)
    }

    @Test("numbers: each evaluation case", arguments: EvalCorpus.English.numbersConvert.map { [$0.heard, $0.expected] })
    func numbers(_ pair: [String]) {
        #expect(EnglishNumbers.format(pair[0]).text == pair[1])
    }

    @Test("numbers: pronouns, small counts and idioms stay words", arguments: EvalCorpus.English.numbersUnchanged)
    func numberLookAlikes(_ sentence: String) {
        #expect(EnglishNumbers.format(sentence).text == sentence)
    }

    @Test("commands end a sentence or are not commands")
    func commands() {
        let set = CommandSet.english
        #expect(VoiceCommands.apply("Thanks, new line. See you tomorrow.", set: set).text == "Thanks\nSee you tomorrow.")
        #expect(VoiceCommands.apply("Are you coming question mark", set: set).text == "Are you coming?")
        #expect(VoiceCommands.apply("Add a new line here.", set: set).text == "Add a new line here.")
        #expect(VoiceCommands.control("Scratch that.", set: set) == .undoLast)
        #expect(VoiceCommands.control("scratch that paint", set: set) == nil)
    }

    @Test("the whole pipeline in English")
    func pipeline() async {
        var config = Config()
        config.language = "en"
        config.vocabulary = [VocabularyTerm(canonical: "Kubernetes")]
        let output = await TranscriptPipeline(config: config)
            .process("um the Cooper Netties cluster served fifteen thousand requests, new line.")
        #expect(output.text == "the Kubernetes cluster served 15,000 requests\n")
    }
}
