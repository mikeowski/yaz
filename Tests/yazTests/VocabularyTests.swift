import Foundation
import Testing

@testable import yaz

/// The vocabulary a Turkish-speaking developer would actually configure.
private let devTerms = [
    VocabularyTerm(canonical: "Slack"),
    VocabularyTerm(canonical: "pull request"),
    VocabularyTerm(canonical: "CI pipeline"),
    VocabularyTerm(canonical: "merge"),
    VocabularyTerm(canonical: "deploy"),
    VocabularyTerm(canonical: "Notion"),
    VocabularyTerm(canonical: "Cursor"),
    VocabularyTerm(canonical: "PostgreSQL"),
    VocabularyTerm(canonical: "Kubernetes"),
    VocabularyTerm(canonical: "TypeScript"),
]

private func vocab(_ terms: [VocabularyTerm] = devTerms) -> Vocabulary {
    Vocabulary(terms: terms)
}

@Suite("PhoneticKey — standing up to Turkish vowel epenthesis")
struct PhoneticKeyTests {

    @Test("Turkish case folds correctly")
    func turkishCaseFolding() {
        #expect(PhoneticKey.lowercasedTurkish("ISTANBUL") == "ıstanbul")
        #expect(PhoneticKey.lowercasedTurkish("İSTANBUL") == "istanbul")
        // Under the default locale İ becomes i + a combining dot, and the
        // comparison breaks.
        #expect(!PhoneticKey.lowercasedTurkish("İ").unicodeScalars.contains { $0.value == 0x307 })
    }

    @Test("diacritics are folded")
    func diacriticsFold() {
        #expect(PhoneticKey.normalize("çğıöşü") == "cgiosu")
    }

    @Test("English digraphs are mapped onto Turkish sounds")
    func digraphsMap() {
        #expect(PhoneticKey.normalize("slack") == "slak")
        #expect(PhoneticKey.normalize("php").contains("f"))
        #expect(PhoneticKey.normalize("query").hasPrefix("k"))
    }

    @Test("punctuation is dropped — Whisper writes abbreviations as 'C.I.P.'")
    func punctuationDropped() {
        // Same letters, only the dots differ: the key must be the same too.
        #expect(PhoneticKey.normalize("C.I.P.") == PhoneticKey.normalize("CIP"))
        #expect(PhoneticKey.normalize("C.I.") == PhoneticKey.normalize("CI"))
    }

    /// The Turkish I/İ distinction does not break matching as long as it is
    /// applied to both sides the same way. What breaks it is folding with the
    /// default locale.
    @Test("dotless I folds the same way on both sides")
    func dotlessIIsConsistent() {
        #expect(PhoneticKey.normalize("CI") == PhoneticKey.normalize("cı"))
    }

    @Test("repeated letters collapse")
    func runsCollapse() {
        #expect(PhoneticKey.normalize("parrot") == PhoneticKey.normalize("parot"))
    }

    @Test("the skeleton drops vowels — epenthesis happens exactly there")
    func skeletonDropsVowels() {
        #expect(PhoneticKey.skeleton("Slack") == "slk")
        #expect(PhoneticKey.skeleton("Sılacık") == "slkk")
    }

    @Test("empty and punctuation-only input does not crash")
    func handlesDegenerateInput() {
        #expect(PhoneticKey.normalize("") == "")
        #expect(PhoneticKey.skeleton("...") == "")
        #expect(PhoneticKey.normalize("   ") .trimmingCharacters(in: .whitespaces) == "")
    }
}

@Suite("EditDistance")
struct EditDistanceTests {

    @Test("bilinen mesafeler")
    func knownDistances() {
        #expect(EditDistance.levenshtein("kitten", "sitting") == 3)
        #expect(EditDistance.levenshtein("", "abc") == 3)
        #expect(EditDistance.levenshtein("abc", "abc") == 0)
    }

    @Test("similarity stays within 0…1")
    func similarityBounds() {
        #expect(EditDistance.similarity("abc", "abc") == 1)
        #expect(EditDistance.similarity("", "") == 1)
        #expect(EditDistance.similarity("abc", "xyz") == 0)
    }
}

@Suite("Vocabulary — repairing measured manglings")
struct VocabularyRecallTests {

    /// This sentence was actually measured: fixtures/t2.wav, whisper
    /// large-v3-turbo.
    @Test("the full measured sentence is repaired")
    func correctsTheMeasuredSentence() {
        let heard = "Yarın saat 14'te toplantı var. Ahmet'e Sılacık üzerinden mesaj atmayı unutma. "
            + "Puhrıkı Esti'de merge etmem lazım. C.I.P. eline yeşile döndüğünde deploy ederiz."
        let result = vocab().correct(heard)

        #expect(result.text.contains("Slack"))
        #expect(result.text.contains("pull request"))
        #expect(result.text.contains("CI pipeline"))
        // The correct ones must be left alone.
        #expect(result.text.contains("merge"))
        #expect(result.text.contains("deploy"))
        // The Turkish parts must survive.
        #expect(result.text.contains("Yarın saat 14'te toplantı var"))
        #expect(result.text.contains("Ahmet'e"))
        #expect(result.text.contains("yeşile döndüğünde"))
    }

    @Test(
        "tek tek bozulmalar yakalanır",
        arguments: [
            ("Sılacık üzerinden yaz", "Slack"),
            ("Puhrıkı Esti açtım", "pull request"),
            ("C.I.P. eline kırmızı", "CI pipeline"),
            ("Körsır ile yazdım", "Cursor"),
        ]
    )
    func catchesIndividualCorruptions(_ input: String, _ expected: String) {
        let result = vocab().correct(input)
        #expect(result.text.contains(expected), "\(input) → \(result.text)")
    }

    @Test("an already-correct term is neither changed nor counted as a correction")
    func exactTermsUntouched() {
        let text = "Slack üzerinden pull request gönder"
        let result = vocab().correct(text)
        #expect(result.text == text)
        #expect(!result.didChange)
    }

    @Test("corrections are reported")
    func reportsCorrections() throws {
        let result = vocab().correct("Sılacık aç")
        #expect(result.didChange)
        let correction = try #require(result.corrections.first)
        #expect(result.corrections.count == 1)
        #expect(correction.to.contains("Slack"))
        #expect(correction.score > 0.7)
    }

    @Test("an empty vocabulary does nothing")
    func emptyVocabularyIsNoOp() {
        let text = "Sılacık üzerinden yaz"
        #expect(Vocabulary(terms: []).correct(text).text == text)
    }

    @Test("empty text does not crash")
    func emptyTextIsSafe() {
        #expect(vocab().correct("").text == "")
    }
}

@Suite("Vocabulary — preserving Turkish suffixes")
struct VocabularySuffixTests {

    /// Turkish attaches suffixes to proper nouns with an apostrophe. Dropping
    /// the suffix breaks the sentence: we mean "Slack'ten", not "Slack".
    @Test("an apostrophe suffix is preserved")
    func preservesApostropheSuffix() {
        let result = vocab().correct("Sılacık'ten mesaj geldi")
        #expect(result.text == "Slack'ten mesaj geldi")
    }

    @Test("the typographic apostrophe is recognised too — Whisper emits it")
    func recognisesTypographicApostrophe() {
        let result = vocab().correct("Sılacık\u{2019}a yazdım")
        #expect(result.text.contains("Slack\u{2019}a"))
    }

    @Test("sondaki noktalama korunur")
    func preservesTrailingPunctuation() {
        #expect(vocab().correct("Sılacık.").text == "Slack.")
        #expect(vocab().correct("Sılacık, sonra").text == "Slack, sonra")
        #expect(vocab().correct("Sılacık?").text == "Slack?")
    }

    @Test("leading punctuation is preserved")
    func preservesLeadingPunctuation() {
        #expect(vocab().correct("(Sılacık)").text == "(Slack)")
        #expect(vocab().correct("\"Sılacık\"").text == "\"Slack\"")
    }

    @Test("ek ve noktalama birlikte korunur")
    func preservesSuffixAndPunctuation() {
        #expect(vocab().correct("Sılacık'ten, dedi").text == "Slack'ten, dedi")
    }

    @Test("in a multi-word term the suffix stays on the last word")
    func multiWordSuffixOnLastWord() {
        let result = vocab().correct("Puhrıkı Esti'yi merge et")
        #expect(result.text.contains("pull request'yi") || result.text.contains("pull request"))
        #expect(result.text.contains("merge et"))
    }
}

@Suite("Vocabulary — guarding against a false match")
struct VocabularyPrecisionTests {

    /// This is the real risk: replacing a word the user actually said. A
    /// mangled term stays visible; a wrong replacement does not.
    @Test(
        "sıradan Türkçe cümleler değiştirilmez",
        arguments: [
            "Yarın sabah toplantımız var, sunumu hazırlamam lazım.",
            "Bugün hava çok güzel, biraz yürüyüşe çıkalım mı?",
            "Kitabı okudum ama sonunu pek beğenmedim açıkçası.",
            "Annem aradı, akşam yemeğe bekliyorlar bizi.",
            "Bu konuyu daha önce konuşmuştuk sanırım, hatırlıyor musun?",
            "Sipariş verdim ama kargo hâlâ gelmedi, takip numarası da çalışmıyor.",
            "Çocuklar bahçede oynuyor, biraz sonra içeri çağırırım.",
            "Sınav sonuçları açıklandı, ortalamam beklediğimden yüksek çıktı.",
            "Arabanın lastiği patladı, yolun kenarında bekliyorum şu an.",
            "Doktor randevusunu haftaya erteledim, bu hafta çok yoğunum.",
        ]
    )
    func ordinaryTurkishIsUntouched(_ sentence: String) {
        let result = vocab().correct(sentence)
        #expect(
            result.text == sentence,
            "değiştirildi: \(result.corrections.map { "\($0.from)→\($0.to)" }.joined(separator: ", "))")
    }

    @Test("very short terms are refused — a three-letter skeleton resembles everything")
    func shortTermsAreRejected() {
        let tiny = Vocabulary(terms: [VocabularyTerm(canonical: "CI"), VocabularyTerm(canonical: "Go")])
        let text = "Bu iş çok zor ve uzun sürecek"
        #expect(tiny.correct(text).text == text)
    }

    @Test("an unrelated word does not pass at a high threshold")
    func unrelatedWordsDoNotMatch() {
        let result = vocab().correct("Kalem masanın üzerinde duruyor")
        #expect(!result.didChange)
    }

    @Test("raising the threshold narrows the coverage")
    func higherThresholdReducesRecall() {
        let strict = Vocabulary(terms: devTerms, threshold: 0.95, skeletonThreshold: 0.95)
        #expect(!strict.correct("Sılacık aç").didChange)
    }

    @Test("the threshold can be overridden per term")
    func perTermThresholdApplies() {
        let loose = Vocabulary(
            terms: [VocabularyTerm(canonical: "parrot", minSimilarity: 0.6)],
            threshold: 0.95, skeletonThreshold: 0.95)
        #expect(loose.correct("Pilot projesi").didChange)
    }

    @Test("matching through an alias")
    func aliasesMatch() {
        let withAlias = Vocabulary(terms: [
            VocabularyTerm(canonical: "Notion", aliases: ["noşın", "noşin"])
        ])
        #expect(withAlias.correct("Noşın'a yazdım").text.contains("Notion"))
    }

    /// An alias nothing like the term: only the alias itself can match it.
    @Test("an alias heard exactly is replaced, however far from the term")
    func exactAlias() {
        let vocabulary = Vocabulary(terms: [VocabularyTerm(canonical: "Kubernetes", aliases: ["kates"])])
        #expect(Vocabulary(terms: [VocabularyTerm(canonical: "Kubernetes")])
            .correct("kates üzerinde çalışıyor").text == "kates üzerinde çalışıyor")
        #expect(vocabulary.correct("kates üzerinde çalışıyor").text == "Kubernetes üzerinde çalışıyor")
        #expect(vocabulary.correct("Kubernetes üzerinde").corrections.isEmpty)
    }
}

@Suite("Vocabulary — overlapping matches")
struct VocabularyOverlapTests {

    @Test("the longer term beats the shorter one")
    func longerTermWins() {
        let terms = [
            VocabularyTerm(canonical: "pull request"),
            VocabularyTerm(canonical: "request"),
        ]
        let result = Vocabulary(terms: terms).correct("Puhrıkı Esti açtım")
        #expect(result.text.contains("pull request"))
        #expect(result.corrections.count == 1)
    }

    @Test("the same term is repaired more than once")
    func repeatedTermsAllCorrected() {
        let result = vocab().correct("Sılacık aç, sonra Sılacık'tan yaz")
        #expect(result.corrections.count == 2)
        #expect(!result.text.contains("Sılacık"))
    }

    @Test("corrections are reported in the order they appear in the text")
    func correctionsAreInOrder() throws {
        let result = vocab().correct("Sılacık aç ve Körsır kapat")
        try #require(result.corrections.count == 2)
        #expect(result.corrections[0].to.contains("Slack"))
        #expect(result.corrections[1].to.contains("Cursor"))
    }

    @Test("two adjacent but different terms do not collide")
    func adjacentTermsDoNotCollide() {
        let result = vocab().correct("Sılacık Körsır")
        #expect(result.text == "Slack Cursor")
    }
}

@Suite("Tokenizer")
struct TokenizerTests {

    @Test("word, suffix and punctuation separate cleanly")
    func splitsParts() {
        let tokens = Tokenizer.tokenize("(Slack'ten,)")
        #expect(tokens.count == 1)
        #expect(tokens[0].leading == "(")
        #expect(tokens[0].stem == "Slack")
        #expect(tokens[0].suffix == "'ten")
        #expect(tokens[0].trailing == ",)")
    }

    @Test("an apostrophe with no letter after it is not a suffix")
    func apostropheWithoutLettersIsNotSuffix() {
        let tokens = Tokenizer.tokenize("Slack'")
        #expect(tokens[0].suffix.isEmpty)
    }

    @Test("whitespace is skipped and the ranges stay correct")
    func rangesAreCorrect() {
        let text = "  bir   iki  "
        let tokens = Tokenizer.tokenize(text)
        #expect(tokens.count == 2)
        #expect(String(text[tokens[0].range]) == "bir")
        #expect(String(text[tokens[1].range]) == "iki")
    }

    @Test("a token made only of punctuation is discarded")
    func punctuationOnlyDropped() {
        #expect(Tokenizer.tokenize("...").isEmpty)
    }

    @Test("empty text gives an empty list")
    func emptyText() {
        #expect(Tokenizer.tokenize("").isEmpty)
        #expect(Tokenizer.tokenize("   ").isEmpty)
    }
}

/// A threshold is only defensible against a real false-match corpus. None of
/// the sentences here contain a technical term, while the vocabulary is full
/// of terms a developer would actually write — including short ones chosen
/// because they deliberately resemble Turkish words.
@Suite("Vocabulary — the broad false-match corpus")
struct VocabularyFalsePositiveCorpusTests {

    static let corpus = [
        "Sabah erken kalkıp kahvaltı hazırladım, sonra markete uğradım.",
        "Kargo şirketi aradı, paket bugün teslim edilecek dediler.",
        "Yeni aldığım ayakkabı biraz dar geldi, değiştirmem gerekecek.",
        "Hafta sonu köye gidiyoruz, dedem bizi bekliyor.",
        "Telefonun şarjı bitmek üzere, kabloyu unutmuşum evde.",
        "Öğle yemeğinde çorba ve pilav vardı, fena değildi.",
        "Kirayı yatırdım ama makbuzu almayı unuttum yine.",
        "Maçı izledin mi dün akşam, son dakikada gol attılar.",
        "Bilgisayarım çok yavaşladı, sanırım temizlik gerekiyor.",
        "Kediyi veterinere götürdüm, aşısını yaptırdık.",
        "Kursa yazıldım ama derslere düzenli gidemiyorum.",
        "Elektrik faturası bu ay çok yüksek gelmiş, itiraz edeceğim.",
        "Kızım okulda tiyatro oyununda rol alacakmış.",
        "Balkondaki çiçekleri sulamayı unutma lütfen.",
        "Bankadan kredi başvurusu yaptım, cevap bekliyorum.",
        "Yolda trafik çok yoğundu, neredeyse bir saat geç kaldım.",
        "Doktor ilaçları düzenli kullanmamı söyledi.",
        "Komşular yine gece geç saatte gürültü yaptı.",
        "Tatil planımızı iptal ettik, işler yoğunlaştı çünkü.",
        "Market listesine süt, ekmek ve peynir ekledim.",
        "Kardeşim üniversiteyi kazandı, çok sevindik hep beraber.",
        "Perdeleri yıkadım, şimdi ütülemem gerekiyor.",
        "Arkadaşımla kavga ettik ama sonra barıştık.",
        "Bu kitabı bitirince sana da öneririm kesinlikle.",
        "Sabahki toplantı iptal oldu, öğleden sonraya kaydı.",
        "Karnım acıktı, bir şeyler ısmarlayalım mı?",
        "Saç kestirdim ama çok kısa oldu bence.",
        "Bahçedeki ağaçları budamak lazım artık.",
        "Yağmur yağıyor, şemsiyeni almayı unutma.",
        "Parkur çok zorluydu, yarısında bıraktım koşuyu.",
    ]

    @Test("not one false match across the thirty-sentence corpus", arguments: corpus)
    func noFalsePositives(_ sentence: String) {
        let result = vocab().correct(sentence)
        #expect(
            !result.didChange,
            "yanlış eşleşme: \(result.corrections.map { "\"\($0.from)\" → \"\($0.to)\" (\($0.score))" }.joined(separator: ", "))")
    }

    /// The same corpus, with terms that resemble Turkish dangerously closely.
    @Test("it stays clean even with terms that look like Turkish words")
    func riskyTermsStayClean() {
        let risky = Vocabulary(terms: [
            VocabularyTerm(canonical: "Docker"),
            VocabularyTerm(canonical: "Redis"),
            VocabularyTerm(canonical: "Vercel"),
            VocabularyTerm(canonical: "Sentry"),
            VocabularyTerm(canonical: "Linear"),
            VocabularyTerm(canonical: "Figma"),
        ])
        var offenders: [String] = []
        for sentence in Self.corpus {
            let result = risky.correct(sentence)
            if result.didChange {
                offenders.append("\(sentence) → \(result.text)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: " | "))")
    }
}

/// The correction layer is Turkish-only, and unsafe rather than merely useless
/// elsewhere: its guard against overwriting a real word is a Turkish word
/// list. Measured on English before this was enforced — `into main` became
/// `Notion` and `merged` became `merge`.
@Suite("Vocabulary — language support is a safety boundary")
struct VocabularyLanguageTests {

    @Test("Turkish is supported", arguments: ["tr", "TR", "tr-TR"])
    func turkishIsSupported(_ language: String) {
        #expect(Vocabulary.isSupported(language: language))
    }

    @Test("German is supported", arguments: ["de", "DE", "de-DE", "de-AT"])
    func germanIsSupported(_ language: String) {
        #expect(Vocabulary.isSupported(language: language))
    }

    @Test(
        "languages without a lexicon are not",
        arguments: ["fr", "ru", "ja", "ko"]
    )
    func othersAreNot(_ language: String) {
        #expect(!Vocabulary.isSupported(language: language))
    }

    @Test("English is supported", arguments: ["en", "EN", "en-US", "en-GB"])
    func englishIsSupported(_ language: String) {
        #expect(Vocabulary.isSupported(language: language))
    }

    /// The exact damage that motivated the boundary, and the English lexicon
    /// that now prevents it.
    @Test("English text is left alone by the pipeline")
    func englishIsUntouched() async {
        let terms = [
            VocabularyTerm(canonical: "Notion"),
            VocabularyTerm(canonical: "merge"),
            VocabularyTerm(canonical: "CI pipeline"),
        ]
        let english = "Today I reviewed the pull request and merged it into main"

        // With the Turkish lexicon, the layer damages it.
        let raw = Vocabulary(terms: terms).correct(english)
        #expect(raw.didChange, "the damage this boundary exists to prevent should be reproducible")

        // With the English one, untouched.
        let pipeline = TranscriptPipeline(
            vocabulary: Vocabulary(terms: terms, language: "en"),
            refiner: Refiner(mode: .off),
            language: "en")
        let result = await pipeline.process(english)
        #expect(result.text == english)
        #expect(result.corrections.isEmpty)
    }

    @Test("Turkish still gets corrected through the pipeline")
    func turkishStillWorks() async {
        let pipeline = TranscriptPipeline(
            vocabulary: Vocabulary(terms: [VocabularyTerm(canonical: "Slack")]),
            refiner: Refiner(mode: .off),
            language: "tr")
        let result = await pipeline.process("Sılacık üzerinden yaz")
        #expect(result.text.contains("Slack"))
        #expect(!result.corrections.isEmpty)
    }

    @Test("the filler filter declares the same boundary")
    func fillerFilterDeclaresItsLanguage() {
        #expect(FillerFilter.isSupported(language: "tr"))
        #expect(FillerFilter.isSupported(language: "en"))
        #expect(!FillerFilter.isSupported(language: "ja"))
    }
}
