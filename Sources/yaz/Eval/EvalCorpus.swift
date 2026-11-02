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

        static let numbersConvert: [(heard: String, expected: String)] = [
            ("Wir hatten fünfundzwanzig Gäste.", "Wir hatten 25 Gäste."),
            ("Das Budget liegt bei fünfzehntausend Euro.", "Das Budget liegt bei 15.000 Euro."),
            ("Der Umsatz stieg um fünfzig Prozent.", "Der Umsatz stieg um 50 %."),
            ("Es waren dreihundertzwölf Tests.", "Es waren 312 Tests."),
            ("Zwei Millionen Nutzer haben sich angemeldet.", "2.000.000 Nutzer haben sich angemeldet."),
            ("Warte fünfundvierzig Minuten.", "Warte 45 Minuten."),
            ("Das Projekt endet zweitausendsechsundzwanzig.", "Das Projekt endet 2026."),
            ("Wir treffen uns um fünfzehn Uhr dreißig.", "Wir treffen uns um 15:30 Uhr."),
            ("Der Zug fährt um neun Uhr.", "Der Zug fährt um 9 Uhr."),
            ("Setz das Timeout auf dreißig Sekunden.", "Setz das Timeout auf 30 Sekunden."),
            ("Einhundertzwanzig Fehler sind behoben.", "120 Fehler sind behoben."),
            ("Er ist zwölf Jahre alt.", "Er ist 12 Jahre alt."),
        ]

        /// The article "ein", "Gib Acht", ordinals, "hundertmal".
        static let numbersUnchanged: [String] = [
            "Ich habe eine Frage.",
            "Gib Acht auf die Stufe.",
            "Das ist ein guter Plan.",
            "Gib mir fünf Minuten.",
            "Wir haben zwei Kinder.",
            "Sie kam als Erste an.",
            "Am zweiten Tag regnete es.",
            "Einer von ihnen hat zugestimmt.",
            "Sieben von ihnen kamen.",
            "Zwanzig ist nicht viel.",
            "Wir haben uns um acht getroffen.",
            "Das war einmal anders.",
            "Er hat hundertmal angerufen.",
            "Achtung, frisch gestrichen!",
        ]

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

extension EvalCorpus {

    /// Spoken Turkish numbers (`TurkishNumbers`). Same rule as the rest of
    /// the file: a wrong digit is a false match, a number left as words is a
    /// miss. The unchanged sentences are the words that only look like
    /// numbers: "onu" (him), "altında" (under), "yedi" (ate), "bin" (get on),
    /// "yüzünü" (face), and the article "bir".
    enum Numbers {

        static let convert: [(heard: String, expected: String)] = [
            ("İki buçukta bitti.", "2,5'te bitti."),
            ("Saat üç buçuğa kadar buradayım.", "Saat 3.30'a kadar buradayım."),
            ("Bir buçuk saat sürdü.", "1,5 saat sürdü."),
            ("Toplantı saat on beşte başlıyor.", "Toplantı saat 15'te başlıyor."),
            ("Saat on beş otuzda görüşelim.", "Saat 15.30'da görüşelim."),
            ("Saat dokuz kırk beşte çıktım.", "Saat 9.45'te çıktım."),
            ("Saat iki buçukta buluşalım.", "Saat 2.30'da buluşalım."),
            ("Saat ikide gel.", "Saat 2'de gel."),
            ("Fatura iki bin yüz elli lira geldi.", "Fatura 2150 lira geldi."),
            ("Bütçe on beş bin dolar.", "Bütçe 15.000 dolar."),
            ("Proje iki bin yirmi altıda bitecek.", "Proje 2026'da bitecek."),
            ("İndirim yüzde elli.", "İndirim %50."),
            ("Fiyatı yüzde yirmi beş arttı.", "Fiyatı %25 arttı."),
            ("Yüzde onluk bir artış.", "Yüzde onluk bir artış."),
            ("Otuz yaşındayım.", "30 yaşındayım."),
            ("Kırk yıl önce taşındık.", "40 yıl önce taşındık."),
            ("On dakika sonra geliyorum.", "10 dakika sonra geliyorum."),
            ("Yüz kişi katıldı.", "100 kişi katıldı."),
            ("Beş lira ver.", "5 lira ver."),
            ("Yirmi birinci yüzyıl.", "21. yüzyıl."),
            ("Onuncu kattayım.", "10. kattayım."),
            ("İki buçuk kilo elma aldım.", "2,5 kilo elma aldım."),
            ("Sunucu 15 bin istek aldı.", "Sunucu 15.000 istek aldı."),
            ("Üç milyon kullanıcı var.", "3.000.000 kullanıcı var."),
            ("Bir milyon kez denedim.", "1.000.000 kez denedim."),
            ("Yetmiş beşe kadar say.", "75'e kadar say."),
            ("Dördüncü sıradayım, on dördüncü değil.", "Dördüncü sıradayım, 14. değil."),
            ("Kırk sekiz saat sürdü.", "48 saat sürdü."),
            ("Bin dokuz yüz seksen dörtte doğdu.", "1984'te doğdu."),
        ]

        static let unchanged: [String] = [
            "Onu dün gördüm.",
            "Ona söyledim, onda kalsın.",
            "Kedi masanın altında uyuyor.",
            "Yemeği yedi ve uyudu.",
            "Ata bin ve git.",
            "Yüzünü yıkadı.",
            "Bir şey söylemek istiyorum.",
            "Bir saat bekledim.",
            "Altı yedi kişi geldi.",
            "Beş dakika bekle.",
            "Üç kere söyledim.",
            "Birinci olarak bunu yap.",
            "İki kişi geldi.",
            "Bu yüzden geç kaldım.",
            "On numaralı odaya bak.",
            "Bin yıllık bir ağaç.",
            "Yüzlerce kişi vardı.",
            "Binlerce mesaj geldi.",
            "Onlar da geliyor.",
            "Dörtlü bir masa.",
            "Sekizer kişilik gruplar.",
            "Onun kitabı bende.",
            "Elli elli paylaştık.",
        ]
    }
}

extension EvalCorpus {

    /// English as the main language. Precision only for term repair, as for
    /// German: no English manglings have been measured yet.
    enum English {

        static let language = "en"

        /// Terms near English words: "doctor", "were all", "ready".
        static let riskyTerms: [VocabularyTerm] = [
            VocabularyTerm(canonical: "Docker"),
            VocabularyTerm(canonical: "Redis"),
            VocabularyTerm(canonical: "Vercel"),
            VocabularyTerm(canonical: "Figma"),
            VocabularyTerm(canonical: "Jira"),
            VocabularyTerm(canonical: "Kafka"),
            VocabularyTerm(canonical: "Svelte"),
        ]

        static let recall: [(heard: String, expected: String)] = []

        /// Everyday English, the counterpart of the Turkish set.
        static let precision: [String] = [
            "I got up early this morning and made breakfast before work.",
            "The delivery guy called and said the package arrives today.",
            "These new shoes are a little tight, I might return them.",
            "We are driving to my grandparents' place this weekend.",
            "My phone is almost dead and I left the charger at home.",
            "Lunch was soup and rice, not bad at all.",
            "I paid the rent but forgot to ask for a receipt again.",
            "Did you watch the game last night? They scored in the last minute.",
            "My laptop got really slow, I think it needs a cleanup.",
            "I took the cat to the vet and she got her shots.",
            "I signed up for a course but I rarely make it to class.",
            "The electricity bill is really high this month.",
            "My daughter has a part in the school play.",
            "Please don't forget to water the plants on the balcony.",
            "I applied for a loan at the bank and I'm waiting to hear back.",
            "Traffic was terrible, I was almost an hour late.",
            "The doctor told me to take the pills every morning.",
            "The neighbors were loud again late last night.",
            "We cancelled the trip because work got busy.",
            "I added milk, bread and cheese to the shopping list.",
            "My brother passed the exam and we were all thrilled.",
            "I washed the curtains and now I have to iron them.",
            "We had a fight but then we made up.",
            "When I finish this book I'll lend it to you.",
            "The morning meeting got moved to the afternoon.",
            "I'm hungry, should we order something?",
            "I got a haircut but it's way too short.",
            "The trees in the garden really need trimming.",
            "It's raining, don't forget your umbrella.",
            "The trail was hard, I gave up halfway through the run.",
        ]

        static let numbersConvert: [(heard: String, expected: String)] = [
            ("We had twenty-five people at the launch.", "We had 25 people at the launch."),
            ("The budget is fifteen thousand dollars.", "The budget is 15,000 dollars."),
            ("Revenue grew fifty percent this year.", "Revenue grew 50% this year."),
            ("It took three hundred and twelve tests.", "It took 312 tests."),
            ("Version two point oh ships today.", "Version two point oh ships today."),
            ("Two million users signed up.", "2,000,000 users signed up."),
            ("Wait forty-five minutes before retrying.", "Wait 45 minutes before retrying."),
            ("We fixed a hundred and twenty bugs.", "We fixed 120 bugs."),
            ("He is ten years old.", "He is 10 years old."),
            ("It costs a thousand euros.", "It costs 1000 euros."),
            ("Ninety nine problems.", "99 problems."),
            ("Set the timeout to thirty seconds.", "Set the timeout to 30 seconds."),
        ]

        /// "one" the pronoun, "five minutes", "at nine", idioms.
        static let numbersUnchanged: [String] = [
            "No one came to the meeting.",
            "This one is better than that one.",
            "I have two kids and a dog.",
            "Give me five minutes.",
            "Twenty is not a lot.",
            "One of these days I will fix it.",
            "We met at nine.",
            "Only one is left.",
            "A hundred times no.",
            "I'll be there in a second.",
            "The hundred-year flood.",
            "She won the first prize.",
            "Seven of them agreed.",
        ]
    }
}
