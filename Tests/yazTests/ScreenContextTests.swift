import Foundation
import Testing
@testable import yaz

@Suite("ScreenContext — the names on screen, for one dictation")
struct ScreenContextTests {

    private let slackThread = """
        #backend · Slack
        Ahmet 14:02 Deploy ne zaman? PaymentGateway testleri Vercel üzerinde kırmızı.
        Merve 14:03 CORS hatası mı? useState hook'unu da kontrol et.
        Pull Request açtım, sonra bakarız.
        """

    @Test("words that look like names are taken, ordinary words are not")
    func extraction() {
        let terms = ScreenContext.terms(in: slackThread, lexicon: .turkish).map(\.canonical)
        #expect(terms.contains("PaymentGateway"))
        #expect(terms.contains("Vercel"))
        #expect(terms.contains("CORS"))
        #expect(terms.contains("useState"))
        #expect(terms.contains("Pull Request"))
        #expect(!terms.contains("sonra"))
        #expect(!terms.contains("ne"))
        #expect(!terms.contains("14"))
    }

    @Test("screen terms are stricter than the user's own")
    func strict() {
        let terms = ScreenContext.terms(in: "Vercel", lexicon: .turkish)
        #expect(terms.first?.minSimilarity == ScreenContext.minSimilarity)
    }

    @Test("terms already in the vocabulary are not added twice")
    func excludesKnown() {
        let terms = ScreenContext.terms(
            in: slackThread, lexicon: .turkish, excluding: [VocabularyTerm(canonical: "Vercel")])
        #expect(!terms.map(\.canonical).contains("Vercel"))
    }

    @Test("the most frequent names come first, up to the limit")
    func ranking() {
        let text = (0..<60).map { "Term\($0)Name" }.joined(separator: " ") + " Vercel Vercel Vercel"
        let terms = ScreenContext.terms(in: text, lexicon: .turkish)
        #expect(terms.count == ScreenContext.maxTerms)
        #expect(terms.first?.canonical == "Vercel")
    }

    @Test("a term that would change an everyday sentence is dropped")
    func vetting() {
        let kept = ScreenContext.vetted(
            [VocabularyTerm(canonical: "Kahvalti"), VocabularyTerm(canonical: "Vercel")],
            language: "tr")
        #expect(kept.map(\.canonical) == ["Vercel"])
    }

    @Test("nothing is used for a language without a lexicon")
    func unsupported() {
        #expect(ScreenContext.vetted([VocabularyTerm(canonical: "Vercel")], language: "ja").isEmpty)
    }

    @Test("a screen term repairs this dictation only")
    func pipeline() async {
        let pipeline = TranscriptPipeline(config: Config())
        let without = await pipeline.process("Vörsel'e deploy ettim")
        #expect(!without.text.contains("Vercel"))
        let with = await pipeline.process(
            "Vörsel'e deploy ettim", context: ScreenContext.terms(in: "Vercel", lexicon: .turkish))
        #expect(with.text.contains("Vercel"))
    }

    @Test("adding terms keeps blocks")
    func addingKeepsBlocks() {
        let base = Vocabulary(terms: [], blocked: [Vocabulary.Block(heard: "Vörsel", term: "Vercel")])
        let extended = base.adding([VocabularyTerm(canonical: "Vercel")])
        #expect(!extended.correct("Vörsel'e deploy ettim").didChange)
    }

    @Test("the switch is read from the config file")
    func config() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-ctx-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{ "screen_context": false }"#.utf8).write(to: url)
        #expect(Config.load(from: url).screenContext == false)
        #expect(Config().screenContext)
    }
}
