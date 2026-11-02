import Foundation
import Testing
@testable import yaz

@Suite("LanguagePack — the main language decides what runs")
struct LanguagePackTests {

    @Test("packs are found by language code, regional tags included")
    func lookup() {
        #expect(LanguagePack.forLanguage("tr")?.code == "tr")
        #expect(LanguagePack.forLanguage("tr-TR")?.code == "tr")
        #expect(LanguagePack.forLanguage("DE")?.code == "de")
        #expect(LanguagePack.forLanguage("ja") == nil)
    }

    @Test("Turkish is the reference: every layer is there")
    func turkishIsComplete() {
        let pack = LanguagePack.turkish
        #expect(pack.features == ["term repair", "filler removal", "numbers", "voice commands", "language-model clean-up"])
    }

    @Test("a pack's hesitations clean exactly as the Turkish filter did")
    func hesitationsThroughPack() {
        let pack = LanguagePack.turkish
        let text = "ıı yarın ee toplantı var"
        #expect(FillerFilter.strip(text, hesitations: pack.hesitations, fold: pack.fold) == FillerFilter.strip(text))
    }

    @Test("commands go through the pack's command set")
    func commandsThroughPack() {
        let set = LanguagePack.turkish.commands!
        #expect(VoiceCommands.apply("Geliyor musun soru işareti", set: set).text == "Geliyor musun?")
        #expect(VoiceCommands.control("Geri al.", set: set) == .undoLast)
    }

    @Test("the lexicons are the packs' lexicons")
    func lexiconsFollowPacks() {
        #expect(Lexicon.all.map(\.language) == LanguagePack.all.map(\.code))
    }

    @Test("a layer a pack lacks is skipped: German has no fillers or numbers yet")
    func missingLayersSkip() async {
        var config = Config()
        config.language = "de"
        let output = await TranscriptPipeline(config: config).process("ähm das sind zwei Dinge.")
        #expect(output.text == "ähm das sind zwei Dinge.")
        #expect(output.numberChanges.isEmpty)
        #expect(!FillerFilter.isSupported(language: "de"))
        #expect(!VoiceCommands.isSupported(language: "de"))
    }

    @Test("without a pack, nothing but transcription")
    func noPack() async {
        var config = Config()
        config.language = "ja"
        config.vocabulary = [VocabularyTerm(canonical: "Slack")]
        let output = await TranscriptPipeline(config: config).process("Sılacık üzerinden yaz")
        #expect(output.text == "Sılacık üzerinden yaz")
    }
}
