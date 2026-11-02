import Foundation

/// The fixed evaluation set. **Do not edit to make a change pass.**
///
/// This is yaz's `prepare.py`, in the sense of Karpathy's autoresearch: the
/// part of the loop nothing being tuned may touch. A learned rule, a new
/// threshold, a lexicon entry — each is kept only if the score over this set
/// does not get worse. Changing the set to admit a change defeats the point;
/// add cases only when they are real, measured transcripts, and in their own
/// commit.
enum EvalCorpus {

    /// The vocabulary a Turkish-speaking developer actually configures.
    static let terms: [VocabularyTerm] = [
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

    /// Terms that resemble Turkish words dangerously: the precision set must
    /// stay clean with these too.
    static let riskyTerms: [VocabularyTerm] = [
        VocabularyTerm(canonical: "Docker"),
        VocabularyTerm(canonical: "Redis"),
        VocabularyTerm(canonical: "Vercel"),
        VocabularyTerm(canonical: "Sentry"),
        VocabularyTerm(canonical: "Linear"),
        VocabularyTerm(canonical: "Figma"),
    ]

    /// Measured manglings (whisper large-v3-turbo, fixtures/) and what must
    /// appear after correction.
    static let recall: [(heard: String, expected: String)] = [
        ("Ahmet'e Sılacık üzerinden mesaj atmayı unutma.", "Slack"),
        ("Puhrıkı Esti'de merge etmem lazım.", "pull request"),
        ("C.I.P. eline yeşile döndüğünde deploy ederiz.", "CI pipeline"),
        ("Sılacık üzerinden yaz", "Slack"),
        ("Puhrıkı Esti açtım", "pull request"),
        ("C.I.P. eline kırmızı", "CI pipeline"),
        ("Körsır ile yazdım", "Cursor"),
    ]

    /// Ordinary Turkish with no technical term in it. Any change is a false
    /// match.
    static let precision: [String] = [
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
}
