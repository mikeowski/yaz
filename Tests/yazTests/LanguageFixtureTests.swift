import Testing

@testable import yaz

/// Whisper large-v3-turbo's own output for `fixtures/languages/*.wav`
/// (macOS `say`, Flo and Anna voices, 2026-11-14), through each language's
/// pipeline with a developer vocabulary. Synthetic speech, like the Turkish
/// fixtures: the kind of output is real, the accuracy is not a claim.
/// Known gaps are written down in docs/architecture.md, not asserted here.
@Suite("Language packs — measured Whisper output through the pipeline")
struct LanguageFixtureTests {

    private static let vocabulary = ["Slack", "pull request", "merge", "deploy", "Notion", "Cursor", "Docker", "Redis"]

    @Test(
        "each language's measured transcript comes out as expected",
        arguments: [
            ["en", "Can you merge the pull request into main question mark?", "Can you merge the pull request into main?"],
            ["en", "Um, I think it costs $15,000, and 50% is already paid.", "I think it costs $15,000, and 50% is already paid."],
            ["en", "The doctor said I should rest. New line. Thanks.", "The doctor said I should rest.\nThanks."],
            ["de", "Kommst du um 15.30 Uhr?", "Kommst du um 15.30 Uhr?"],
            ["de", "Das kostet 15.000 Euro, 50% sind schon bezahlt.", "Das kostet 15.000 Euro, 50% sind schon bezahlt."],
            ["de", "Der Doktor hat gesagt, ich soll mich ausruhen. Neue Zeile, danke.",
             "Der Doktor hat gesagt, ich soll mich ausruhen. Neue Zeile, danke."],
            ["es", "Vienes a las 5 signo de interrogación.", "¿Vienes a las 5?"],
            ["es", "El doctor dijo que tengo que descansar. Nueva línea era. Gracias.",
             "El doctor dijo que tengo que descansar. Nueva línea era. Gracias."],
            ["fr", "Euh, ça coûte 15 000 euros et on a corrigé 90 bucks.", "ça coûte 15 000 euros et on a corrigé 90 bucks."],
            ["fr", "Le docteur a dit que je dois me reposer. Nouvelle ligne. Merci.", "Le docteur a dit que je dois me reposer.\nMerci."],
        ])
    func measured(_ row: [String]) async {
        var config = Config()
        config.language = row[0]
        config.vocabulary = Self.vocabulary.map { VocabularyTerm(canonical: $0) }
        let output = await TranscriptPipeline(config: config).process(row[1])
        #expect(output.text == row[2])
        #expect(output.corrections.isEmpty, "no term is in these sentences")
    }
}
