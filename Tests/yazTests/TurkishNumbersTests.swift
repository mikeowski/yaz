import Foundation
import Testing
@testable import yaz

@Suite("TurkishNumbers — spoken numbers as digits")
struct TurkishNumbersTests {

    @Test("every case in the evaluation set converts as written",
          arguments: EvalCorpus.Numbers.convert.map { [$0.heard, $0.expected] })
    func converts(_ pair: [String]) {
        #expect(TurkishNumbers.format(pair[0]).text == pair[1])
    }

    @Test("words that only look like numbers stay words",
          arguments: EvalCorpus.Numbers.unchanged)
    func lookAlikes(_ sentence: String) {
        let result = TurkishNumbers.format(sentence)
        #expect(result.text == sentence)
        #expect(result.changes.isEmpty)
    }

    @Test("the everyday Turkish corpus is untouched", arguments: EvalCorpus.precision)
    func corpus(_ sentence: String) {
        #expect(TurkishNumbers.format(sentence).text == sentence)
    }

    @Test("the numbers part of the evaluation scores zero")
    func evaluation() {
        let score = Evaluator.score(language: "tr")
        #expect(score.value == 0, "\(score.offenders)")
    }

    @Test("an ill-formed run is left whole, not converted in part")
    func illFormed() {
        #expect(TurkishNumbers.format("Bir yüz gördüm.").text == "Bir yüz gördüm.")
        #expect(TurkishNumbers.format("Yedi iki kere.").text == "Yedi iki kere.")
    }

    @Test("thousands are grouped from five digits, a year is not")
    func grouping() {
        #expect(TurkishNumbers.format("dokuz bin dokuz yüz doksan dokuz kişi").text == "9999 kişi")
        #expect(TurkishNumbers.format("on bin kişi").text == "10.000 kişi")
        #expect(TurkishNumbers.format("iki milyar yüz bin lira").text == "2.000.100.000 lira")
    }

    @Test("punctuation around a number is kept")
    func punctuation() {
        #expect(TurkishNumbers.format("(on beş dakika)").text == "(15 dakika)")
    }

    @Test("each change is reported")
    func changes() {
        let result = TurkishNumbers.format("Saat on beşte, yüzde elli indirim.")
        #expect(result.changes.map(\.to) == ["15'te,", "%50"])
    }

    @Test("only Turkish")
    func language() {
        #expect(TurkishNumbers.isSupported(language: "tr-TR"))
        #expect(!TurkishNumbers.isSupported(language: "de"))
    }

    @Test("the pipeline writes numbers last, and only when switched on")
    func pipeline() async {
        var config = Config()
        #expect(config.numbers)
        let on = await TranscriptPipeline(config: config).process("Toplantı saat on beşte.")
        #expect(on.text == "Toplantı saat 15'te.")
        #expect(on.numberChanges.count == 1)

        config.numbers = false
        let off = await TranscriptPipeline(config: config).process("Toplantı saat on beşte.")
        #expect(off.text == "Toplantı saat on beşte.")

        config.numbers = true
        config.language = "en"
        let english = await TranscriptPipeline(config: config).process("on beş")
        #expect(english.text == "on beş")
    }

    @Test("the setting is read from and written to the config file")
    func config() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-num-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{ "numbers": false }"#.utf8).write(to: url)
        #expect(Config.load(from: url).numbers == false)
    }
}
