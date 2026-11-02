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

extension EvalCorpus {

    /// A German speaker who mixes in English terms, scored with the same
    /// developer `terms`.
    ///
    /// **Precision only, for now.** Recall cases are measured manglings, and
    /// none have been measured for German yet: inventing them would tune the
    /// matcher to guesses. Add them from real transcripts (`yaz transcribe
    /// --language de --vocabulary <file>`), in their own commit.
    enum German {

        static let language = "de"

        /// Terms that resemble German words: Doktor, Rede, Rost, jetzt.
        static let riskyTerms: [VocabularyTerm] = [
            VocabularyTerm(canonical: "Docker"),
            VocabularyTerm(canonical: "Redis"),
            VocabularyTerm(canonical: "Vercel"),
            VocabularyTerm(canonical: "Sentry"),
            VocabularyTerm(canonical: "Figma"),
            VocabularyTerm(canonical: "Jest"),
            VocabularyTerm(canonical: "Rust"),
        ]

        static let recall: [(heard: String, expected: String)] = []

        /// Ordinary German with no technical term in it, the counterpart of
        /// the Turkish set. Any change is a false match.
        static let precision: [String] = [
            "Heute Morgen bin ich früh aufgestanden und habe Frühstück gemacht.",
            "Der Paketdienst hat angerufen, die Lieferung kommt morgen.",
            "Die neuen Schuhe sind mir ein bisschen zu eng.",
            "Am Wochenende fahren wir zu meinen Großeltern aufs Land.",
            "Mein Handy ist fast leer, ich habe das Ladekabel zu Hause vergessen.",
            "Zum Mittagessen gab es Suppe und Reis, gar nicht schlecht.",
            "Ich habe die Miete überwiesen, aber die Quittung vergessen.",
            "Hast du gestern das Spiel gesehen? In der letzten Minute fiel ein Tor.",
            "Mein Computer ist sehr langsam geworden, ich muss ihn aufräumen.",
            "Ich war mit der Katze beim Tierarzt, sie wurde geimpft.",
            "Ich habe mich für einen Kurs angemeldet, aber gehe selten hin.",
            "Die Stromrechnung ist diesen Monat sehr hoch, ich lege Widerspruch ein.",
            "Meine Tochter spielt im Schultheater eine Rolle.",
            "Vergiss bitte nicht, die Blumen auf dem Balkon zu gießen.",
            "Ich habe bei der Bank einen Kredit beantragt und warte auf die Antwort.",
            "Auf der Straße war viel Verkehr, ich kam fast eine Stunde zu spät.",
            "Der Doktor hat gesagt, ich soll die Tabletten regelmäßig nehmen.",
            "Die Nachbarn waren gestern Nacht wieder sehr laut.",
            "Wir haben den Urlaub abgesagt, weil gerade so viel los ist.",
            "Ich habe Milch, Brot und Käse auf die Einkaufsliste geschrieben.",
            "Mein Bruder hat die Prüfung bestanden, wir haben uns sehr gefreut.",
            "Ich habe die Vorhänge gewaschen und muss sie jetzt bügeln.",
            "Ich habe mich mit meinem Freund gestritten, aber wir haben uns versöhnt.",
            "Wenn ich das Buch fertig habe, empfehle ich es dir auf jeden Fall.",
            "Die Besprechung heute früh fällt aus, sie wird auf den Nachmittag verschoben.",
            "Ich habe Hunger, sollen wir etwas bestellen?",
            "Ich war beim Friseur, aber die Haare sind viel zu kurz geworden.",
            "Die Bäume im Garten müssen endlich geschnitten werden.",
            "Es regnet, vergiss deinen Regenschirm nicht.",
            "Die Strecke war sehr schwer, ich habe den Lauf nach der Hälfte abgebrochen.",
        ]
    }
}
