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

@Suite("PhoneticKey — Türkçe ünlü türemesine karşı")
struct PhoneticKeyTests {

    @Test("Türkçe büyük/küçük harf doğru katlanır")
    func turkishCaseFolding() {
        #expect(PhoneticKey.lowercasedTurkish("ISTANBUL") == "ıstanbul")
        #expect(PhoneticKey.lowercasedTurkish("İSTANBUL") == "istanbul")
        // Varsayılan locale ile İ, i + birleşik nokta olur ve karşılaştırma bozulur.
        #expect(!PhoneticKey.lowercasedTurkish("İ").unicodeScalars.contains { $0.value == 0x307 })
    }

    @Test("aksanlar katlanır")
    func diacriticsFold() {
        #expect(PhoneticKey.normalize("çğıöşü") == "cgiosu")
    }

    @Test("İngilizce digraf'lar Türkçe sese çevrilir")
    func digraphsMap() {
        #expect(PhoneticKey.normalize("slack") == "slak")
        #expect(PhoneticKey.normalize("php").contains("f"))
        #expect(PhoneticKey.normalize("query").hasPrefix("k"))
    }

    @Test("noktalama atılır — Whisper kısaltmaları 'C.I.P.' diye yazıyor")
    func punctuationDropped() {
        // Aynı harfler, yalnızca noktalar farklı: anahtar da aynı olmalı.
        #expect(PhoneticKey.normalize("C.I.P.") == PhoneticKey.normalize("CIP"))
        #expect(PhoneticKey.normalize("C.I.") == PhoneticKey.normalize("CI"))
    }

    /// Türkçe I/İ ayrımı her iki tarafa da aynı uygulandığı sürece eşleşmeyi
    /// bozmaz; bozan şey varsayılan locale ile katlamaktır.
    @Test("noktasız I her iki tarafta da aynı katlanır")
    func dotlessIIsConsistent() {
        #expect(PhoneticKey.normalize("CI") == PhoneticKey.normalize("cı"))
    }

    @Test("tekrarlı harfler sadeleşir")
    func runsCollapse() {
        #expect(PhoneticKey.normalize("parrot") == PhoneticKey.normalize("parot"))
    }

    @Test("iskelet ünlüleri atar — ünlü türemesi tam burada yaşanıyor")
    func skeletonDropsVowels() {
        #expect(PhoneticKey.skeleton("Slack") == "slk")
        #expect(PhoneticKey.skeleton("Sılacık") == "slkk")
    }

    @Test("boş ve noktalama-yalnız girdi çökmez")
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

    @Test("benzerlik 0…1 aralığında")
    func similarityBounds() {
        #expect(EditDistance.similarity("abc", "abc") == 1)
        #expect(EditDistance.similarity("", "") == 1)
        #expect(EditDistance.similarity("abc", "xyz") == 0)
    }
}

@Suite("Vocabulary — ölçülmüş bozulmaları düzeltme")
struct VocabularyRecallTests {

    /// Bu cümle gerçekten ölçüldü: fixtures/t2.wav, whisper large-v3-turbo.
    @Test("ölçülen tam cümle düzelir")
    func correctsTheMeasuredSentence() {
        let heard = "Yarın saat 14'te toplantı var. Ahmet'e Sılacık üzerinden mesaj atmayı unutma. "
            + "Puhrıkı Esti'de merge etmem lazım. C.I.P. eline yeşile döndüğünde deploy ederiz."
        let result = vocab().correct(heard)

        #expect(result.text.contains("Slack"))
        #expect(result.text.contains("pull request"))
        #expect(result.text.contains("CI pipeline"))
        // Doğru olanlara dokunulmamalı.
        #expect(result.text.contains("merge"))
        #expect(result.text.contains("deploy"))
        // Türkçe kısımlar korunmalı.
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

    @Test("zaten doğru yazılmış terim değiştirilmez ve düzeltme sayılmaz")
    func exactTermsUntouched() {
        let text = "Slack üzerinden pull request gönder"
        let result = vocab().correct(text)
        #expect(result.text == text)
        #expect(!result.didChange)
    }

    @Test("düzeltmeler raporlanır")
    func reportsCorrections() throws {
        let result = vocab().correct("Sılacık aç")
        #expect(result.didChange)
        let correction = try #require(result.corrections.first)
        #expect(result.corrections.count == 1)
        #expect(correction.to.contains("Slack"))
        #expect(correction.score > 0.7)
    }

    @Test("boş sözlük hiçbir şey yapmaz")
    func emptyVocabularyIsNoOp() {
        let text = "Sılacık üzerinden yaz"
        #expect(Vocabulary(terms: []).correct(text).text == text)
    }

    @Test("boş metin çökmez")
    func emptyTextIsSafe() {
        #expect(vocab().correct("").text == "")
    }
}

@Suite("Vocabulary — Türkçe ek koruması")
struct VocabularySuffixTests {

    /// Türkçe özel isimlere ekleri kesme işaretiyle bağlar. Eki düşürmek
    /// cümleyi bozar: "Slack üzerinden" değil "Slack'ten" demek istiyoruz.
    @Test("kesme işaretli ek korunur")
    func preservesApostropheSuffix() {
        let result = vocab().correct("Sılacık'ten mesaj geldi")
        #expect(result.text == "Slack'ten mesaj geldi")
    }

    @Test("tipografik kesme işareti de tanınır — Whisper bunu üretiyor")
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

    @Test("baştaki noktalama korunur")
    func preservesLeadingPunctuation() {
        #expect(vocab().correct("(Sılacık)").text == "(Slack)")
        #expect(vocab().correct("\"Sılacık\"").text == "\"Slack\"")
    }

    @Test("ek ve noktalama birlikte korunur")
    func preservesSuffixAndPunctuation() {
        #expect(vocab().correct("Sılacık'ten, dedi").text == "Slack'ten, dedi")
    }

    @Test("çok kelimeli terimde ek son kelimede kalır")
    func multiWordSuffixOnLastWord() {
        let result = vocab().correct("Puhrıkı Esti'yi merge et")
        #expect(result.text.contains("pull request'yi") || result.text.contains("pull request"))
        #expect(result.text.contains("merge et"))
    }
}

@Suite("Vocabulary — yanlış eşleşmeye karşı")
struct VocabularyPrecisionTests {

    /// Asıl risk bu: kullanıcının gerçekten söylediği bir kelimeyi değiştirmek.
    /// Bozuk terim görünür kalır, yanlış değiştirme görünmez.
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

    @Test("çok kısa terimler sözlüğe alınmaz — üç harfli iskelet her şeye benzer")
    func shortTermsAreRejected() {
        let tiny = Vocabulary(terms: [VocabularyTerm(canonical: "CI"), VocabularyTerm(canonical: "Go")])
        let text = "Bu iş çok zor ve uzun sürecek"
        #expect(tiny.correct(text).text == text)
    }

    @Test("alakasız kelime yüksek eşikte geçmez")
    func unrelatedWordsDoNotMatch() {
        let result = vocab().correct("Kalem masanın üzerinde duruyor")
        #expect(!result.didChange)
    }

    @Test("eşik yükseltilince kapsam daralır")
    func higherThresholdReducesRecall() {
        let strict = Vocabulary(terms: devTerms, threshold: 0.95, skeletonThreshold: 0.95)
        #expect(!strict.correct("Sılacık aç").didChange)
    }

    @Test("terim başına eşik geçersiz kılınabilir")
    func perTermThresholdApplies() {
        let loose = Vocabulary(
            terms: [VocabularyTerm(canonical: "parrot", minSimilarity: 0.6)],
            threshold: 0.95, skeletonThreshold: 0.95)
        #expect(loose.correct("Pilot projesi").didChange)
    }

    @Test("takma ad ile eşleşme")
    func aliasesMatch() {
        let withAlias = Vocabulary(terms: [
            VocabularyTerm(canonical: "Notion", aliases: ["noşın", "noşin"])
        ])
        #expect(withAlias.correct("Noşın'a yazdım").text.contains("Notion"))
    }
}

@Suite("Vocabulary — çakışan eşleşmeler")
struct VocabularyOverlapTests {

    @Test("uzun terim kısa terimi yener")
    func longerTermWins() {
        let terms = [
            VocabularyTerm(canonical: "pull request"),
            VocabularyTerm(canonical: "request"),
        ]
        let result = Vocabulary(terms: terms).correct("Puhrıkı Esti açtım")
        #expect(result.text.contains("pull request"))
        #expect(result.corrections.count == 1)
    }

    @Test("aynı terim birden fazla kez düzeltilir")
    func repeatedTermsAllCorrected() {
        let result = vocab().correct("Sılacık aç, sonra Sılacık'tan yaz")
        #expect(result.corrections.count == 2)
        #expect(!result.text.contains("Sılacık"))
    }

    @Test("düzeltmeler metindeki sırayla raporlanır")
    func correctionsAreInOrder() throws {
        let result = vocab().correct("Sılacık aç ve Körsır kapat")
        try #require(result.corrections.count == 2)
        #expect(result.corrections[0].to.contains("Slack"))
        #expect(result.corrections[1].to.contains("Cursor"))
    }

    @Test("bitişik iki farklı terim çakışmaz")
    func adjacentTermsDoNotCollide() {
        let result = vocab().correct("Sılacık Körsır")
        #expect(result.text == "Slack Cursor")
    }
}

@Suite("Tokenizer")
struct TokenizerTests {

    @Test("kelime, ek ve noktalama ayrışır")
    func splitsParts() {
        let tokens = Tokenizer.tokenize("(Slack'ten,)")
        #expect(tokens.count == 1)
        #expect(tokens[0].leading == "(")
        #expect(tokens[0].stem == "Slack")
        #expect(tokens[0].suffix == "'ten")
        #expect(tokens[0].trailing == ",)")
    }

    @Test("kesme işareti harf gelmezse ek sayılmaz")
    func apostropheWithoutLettersIsNotSuffix() {
        let tokens = Tokenizer.tokenize("Slack'")
        #expect(tokens[0].suffix.isEmpty)
    }

    @Test("boşluklar atlanır, aralıklar doğru")
    func rangesAreCorrect() {
        let text = "  bir   iki  "
        let tokens = Tokenizer.tokenize(text)
        #expect(tokens.count == 2)
        #expect(String(text[tokens[0].range]) == "bir")
        #expect(String(text[tokens[1].range]) == "iki")
    }

    @Test("yalnız noktalamadan oluşan parça atılır")
    func punctuationOnlyDropped() {
        #expect(Tokenizer.tokenize("...").isEmpty)
    }

    @Test("boş metin boş liste verir")
    func emptyText() {
        #expect(Tokenizer.tokenize("").isEmpty)
        #expect(Tokenizer.tokenize("   ").isEmpty)
    }
}

/// Eşik ayarı ancak gerçek bir yanlış-eşleşme korpusuna karşı savunulabilir.
/// Buradaki cümlelerin hiçbirinde teknik terim yok; sözlük ise bir
/// geliştiricinin gerçekten yazacağı terimlerle dolu ve kasıtlı olarak
/// Türkçe kelimelere benzeyen kısa terimler içeriyor.
@Suite("Vocabulary — geniş yanlış-eşleşme korpusu")
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

    @Test("otuz cümlelik korpusta tek bir yanlış eşleşme yok", arguments: corpus)
    func noFalsePositives(_ sentence: String) {
        let result = vocab().correct(sentence)
        #expect(
            !result.didChange,
            "yanlış eşleşme: \(result.corrections.map { "\"\($0.from)\" → \"\($0.to)\" (\($0.score))" }.joined(separator: ", "))")
    }

    /// Türkçeye tehlikeli biçimde benzeyen terimlerle aynı korpus.
    @Test("Türkçe kelimelere benzeyen terimlerde de temiz kalır")
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

    @Test(
        "other languages are not",
        arguments: ["en", "de", "fr", "es", "ru", "ja", "en-US"]
    )
    func othersAreNot(_ language: String) {
        #expect(!Vocabulary.isSupported(language: language))
    }

    /// The exact damage that motivated the boundary.
    @Test("English text is left alone by the pipeline")
    func englishIsUntouched() async {
        let terms = [
            VocabularyTerm(canonical: "Notion"),
            VocabularyTerm(canonical: "merge"),
            VocabularyTerm(canonical: "CI pipeline"),
        ]
        let english = "Today I reviewed the pull request and merged it into main"

        // Directly: the layer would damage it.
        let raw = Vocabulary(terms: terms).correct(english)
        #expect(raw.didChange, "the damage this boundary exists to prevent should be reproducible")

        // Through the pipeline with language: en — untouched.
        let pipeline = TranscriptPipeline(
            vocabulary: Vocabulary(terms: terms),
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
        #expect(!FillerFilter.isSupported(language: "en"))
    }
}
