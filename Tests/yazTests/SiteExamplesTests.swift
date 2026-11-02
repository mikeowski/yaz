import Foundation
import Testing
@testable import yaz

/// The examples on yaz.mike4.dev's Languages section, through the real
/// pipeline: the site only shows what the code does.
@Suite("Site examples — every language row is real output")
struct SiteExamplesTests {

    @Test(
        "each language's example comes out as the site shows it",
        arguments: [
            ["tr", "Slack", "Sılacık'ta yaz, saat on beş otuzda", "Slack'ta yaz, saat 15.30'da"],
            ["en", "Kubernetes", "Cooper Netties served fifteen thousand requests", "Kubernetes served 15,000 requests"],
            ["de", "", "Kommst du um fünfzehn Uhr dreißig Fragezeichen", "Kommst du um 15:30 Uhr?"],
            ["es", "", "vienes a las cinco signo de interrogación", "¿Vienes a las cinco?"],
            ["fr", "", "on a corrigé quatre-vingt-dix bugs", "on a corrigé 90 bugs"],
        ])
    func example(_ row: [String]) async {
        var config = Config()
        config.language = row[0]
        config.vocabulary = row[1].isEmpty ? [] : [VocabularyTerm(canonical: row[1])]
        let output = await TranscriptPipeline(config: config).process(row[2])
        #expect(output.text == row[3])
    }

    @Test("the evaluation totals the site quotes")
    func totals() {
        let score = Evaluator.score()
        #expect(score.precisionCases == 522)
        #expect(score.value == 0)
    }
}
