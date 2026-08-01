import Foundation

/// High-frequency Turkish words, used as a veto on fuzzy replacement.
///
/// A similarity ratio alone cannot do this job, and the measurement says so.
/// Compared as consonant skeletons:
///
/// ```
/// Slack  (slk)  vs  Sılacık (slck)   → 0.75   ← want this replaced
/// Docker (dkr)  vs  Doktor  (dktr)   → 0.75   ← must NOT be replaced
/// Sentry (sntr) vs  sonra   (snr)    → 0.75   ← must NOT be replaced
/// ```
///
/// Identical scores, opposite desired outcomes. No threshold separates them.
/// What does separate them is that `doktor` and `sonra` are ordinary Turkish
/// words a speaker plainly said, while `Sılacık` is not a word in any language
/// — it only exists because the acoustic model broke an English consonant
/// cluster with epenthetic vowels.
///
/// So a window containing a common Turkish word is protected: it may only be
/// replaced on near-exact evidence, never on a skeleton guess. The list is
/// frequency-ordered function words plus everyday nouns, verbs and adjectives.
/// It does not need to be a dictionary — it needs to cover the words a
/// dictation user actually says between technical terms.
enum TurkishLexicon {

    /// Similarity a protected word must reach before it can be replaced.
    /// Effectively "you must have said almost exactly the term".
    static let protectedWordThreshold: Double = 0.90

    /// True when any word in the window is common enough to protect.
    static func containsCommonWord(_ stems: [String]) -> Bool {
        stems.contains { isCommon($0) }
    }

    static func isCommon(_ word: String) -> Bool {
        let folded = PhoneticKey.lowercasedTurkish(word)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !folded.isEmpty else { return false }
        if common.contains(folded) { return true }

        // Turkish is agglutinative: `sonraki`, `doktora`, `saatte` are the same
        // stems wearing suffixes. Checking a few common endings catches those
        // without shipping a morphological analyser.
        for suffix in suffixes where folded.count > suffix.count + 2 {
            if folded.hasSuffix(suffix) {
                let stem = String(folded.dropLast(suffix.count))
                if common.contains(stem) { return true }
            }
        }
        return false
    }

    /// Frequent Turkish case, possessive and tense endings.
    private static let suffixes = [
        "lar", "ler", "dan", "den", "tan", "ten", "nin", "nın", "nun", "nün",
        "in", "ın", "un", "ün", "de", "da", "te", "ta", "ye", "ya", "yi", "yı",
        "yu", "yü", "le", "la", "ki", "si", "sı", "su", "sü", "im", "ım", "um",
        "üm", "iz", "ız", "uz", "üz", "di", "dı", "du", "dü", "ti", "tı", "tu",
        "tü", "miş", "mış", "muş", "müş", "yor", "ecek", "acak", "e", "a", "i",
        "ı", "u", "ü",
    ]

    /// ~340 of the most frequent Turkish words.
    private static let common: Set<String> = [
        // Pronouns, determiners, conjunctions, particles
        "ben", "sen", "o", "biz", "siz", "onlar", "bu", "şu", "bunu", "şunu",
        "bana", "sana", "ona", "bize", "size", "onlara", "benim", "senin",
        "onun", "bizim", "sizin", "kendi", "kendim", "kendini",
        "ve", "veya", "ya", "ile", "ama", "fakat", "ancak", "çünkü", "ki",
        "de", "da", "ise", "yani", "hem", "ya da", "eğer", "diye", "gibi",
        "için", "kadar", "göre", "sonra", "önce", "beri", "doğru", "karşı",
        "rağmen", "üzere", "dolayı", "başka", "yerine",
        "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz",
        "on", "yirmi", "otuz", "kırk", "elli", "yüz", "bin", "milyon",
        "her", "hiç", "bazı", "birçok", "tüm", "bütün", "çok", "az", "biraz",
        "daha", "en", "pek", "epey", "fazla", "birkaç", "herkes", "kimse",
        "şey", "şeyler", "hepsi", "hiçbir", "böyle", "şöyle", "öyle", "nasıl",
        "neden", "niye", "ne", "kim", "hangi", "nerede", "nereye", "nereden",
        "kaç", "zaman", "evet", "hayır", "tamam", "peki", "belki", "tabii",
        "elbette", "sanırım", "galiba", "acaba", "keşke", "artık", "hâlâ",
        "hala", "yine", "tekrar", "hep", "hemen", "şimdi", "bugün", "dün",
        "yarın", "akşam", "sabah", "öğle", "gece", "gündüz", "hafta", "ay",
        "yıl", "gün", "saat", "dakika", "saniye", "an", "sıra", "kez", "defa",

        // Very common verbs (bare stems and frequent finite forms)
        "olmak", "olur", "oldu", "olsun", "olan", "olarak", "var", "yok",
        "değil", "etmek", "etti", "eder", "yapmak", "yaptı", "yapar", "yapıyor",
        "gelmek", "geldi", "gelir", "geliyor", "gitmek", "gitti", "gider",
        "gidiyor", "almak", "aldı", "alır", "vermek", "verdi", "verir",
        "görmek", "gördü", "görür", "bilmek", "bildi", "bilir", "biliyor",
        "demek", "dedi", "der", "diyor", "istemek", "istedi", "ister",
        "bakmak", "baktı", "bakar", "bulmak", "buldu", "bulur", "kalmak",
        "kaldı", "kalır", "çıkmak", "çıktı", "çıkar", "girmek", "girdi",
        "başlamak", "başladı", "bitmek", "bitti", "durmak", "durdu",
        "koymak", "koydu", "açmak", "açtı", "kapatmak", "kapattı",
        "sormak", "sordu", "söylemek", "söyledi", "anlamak", "anladı",
        "çalışmak", "çalıştı", "çalışıyor", "beklemek", "bekledi", "bekliyor",
        "unutmak", "unuttu", "unuttum", "hatırlamak", "sevmek", "sevdi",
        "yazmak", "yazdı", "okumak", "okudu", "dinlemek", "izlemek", "izledi",
        "konuşmak", "konuştu", "gerekmek", "gerek", "gerekiyor", "lazım",
        "kullanmak", "kullandı", "göndermek", "gönderdi", "aramak", "aradı",
        "getirmek", "getirdi", "götürmek", "götürdü", "yemek", "yedi",
        "içmek", "içti", "uyumak", "uyudu", "kalkmak", "kalktı", "oturmak",
        "oturdu", "yürümek", "koşmak", "binmek", "inmek", "geçmek", "geçti",
        "kazanmak", "kaybetmek", "ödemek", "ödedi", "satmak", "satın",

        // Everyday nouns
        "ev", "iş", "okul", "ders", "sınav", "kitap", "kalem", "masa",
        "sandalye", "kapı", "pencere", "oda", "mutfak", "banyo", "bahçe",
        "araba", "yol", "sokak", "şehir", "köy", "ülke", "dünya", "insan",
        "adam", "kadın", "çocuk", "kız", "oğlan", "anne", "baba", "kardeş",
        "abla", "abi", "dede", "nine", "aile", "arkadaş", "komşu", "öğretmen",
        "öğrenci", "doktor", "hasta", "hastane", "ilaç", "para", "banka",
        "market", "mağaza", "fiyat", "hesap", "fatura", "kira", "maaş",
        "telefon", "bilgisayar", "internet", "mesaj", "haber", "resim",
        "müzik", "film", "oyun", "maç", "top", "spor", "yemek", "su", "çay",
        "kahve", "süt", "ekmek", "peynir", "et", "sebze", "meyve", "tatlı",
        "hava", "yağmur", "kar", "güneş", "rüzgar", "deniz", "dağ", "ağaç",
        "çiçek", "kedi", "köpek", "kuş", "hayvan", "renk", "ses", "yüz",
        "göz", "el", "ayak", "baş", "kalp", "isim", "ad", "soru", "cevap",
        "sorun", "problem", "konu", "fikir", "plan", "karar", "sonuç",
        "durum", "yer", "taraf", "yön", "boyut", "parça", "tane", "kargo",
        "paket", "sipariş", "teslim", "toplantı", "sunum", "rapor", "proje",
        "görev", "izin", "tatil", "yolculuk", "bilet", "otel", "randevu",

        // Frequent adjectives and adverbs
        "iyi", "kötü", "büyük", "küçük", "yeni", "eski", "uzun", "kısa",
        "yüksek", "alçak", "hızlı", "yavaş", "kolay", "zor", "güzel", "çirkin",
        "temiz", "kirli", "sıcak", "soğuk", "ılık", "dolu", "boş", "açık",
        "kapalı", "doğru", "yanlış", "önemli", "gerekli", "hazır", "meşgul",
        "yorgun", "mutlu", "üzgün", "hasta", "sağlam", "genç", "yaşlı",
        "zengin", "fakir", "ucuz", "pahalı", "yakın", "uzak", "erken", "geç",
        "birlikte", "beraber", "yalnız", "tek", "ayrı", "aynı", "farklı",
        "benzer", "kesin", "kesinlikle", "gerçekten", "aslında", "özellikle",
        "genellikle", "bazen", "sık", "nadiren", "asla", "mutlaka",
        "neredeyse", "hemen hemen", "gerçi", "madem", "üstelik", "ayrıca",
        "yaklaşık", "ortalama", "toplam", "sadece", "yalnızca", "bile",

        // More everyday vocabulary — coverage here is the weakest link in the
        // veto, so it is worth being generous.
        "kurs", "saç", "sınıf", "not", "ödev", "tahta", "defter", "çanta",
        "ayakkabı", "elbise", "gömlek", "pantolon", "ceket", "şapka", "gözlük",
        "saat", "yüzük", "anahtar", "cüzdan", "kart", "şifre", "adres",
        "numara", "liste", "kutu", "torba", "şişe", "bardak", "tabak", "kaşık",
        "çatal", "bıçak", "tencere", "fırın", "buzdolabı", "çamaşır", "bulaşık",
        "perde", "halı", "yatak", "yorgan", "yastık", "havlu", "sabun",
        "makbuz", "fiş", "vergi", "sigorta", "kredi", "borç", "taksit",
        "veteriner", "aşı", "reçete", "eczane", "muayene", "ateş", "ağrı",
        "tiyatro", "sinema", "konser", "sergi", "müze", "kütüphane", "park",
        "bahçıvan", "çiftlik", "tarla", "hasat", "tohum", "toprak", "gübre",
        "lastik", "benzin", "motor", "fren", "direksiyon", "kaza", "trafik",
        "otobüs", "tren", "uçak", "vapur", "taksi", "durak", "istasyon",
        "kalabalık", "sessiz", "gürültü", "koku", "tat", "dokunmak",
        "gitar", "piyano", "şarkı", "dans", "resim", "boya", "fırça",
        "kahvaltı", "öğlen", "yemekhane", "lokanta", "garson", "hesap",
        "sunum", "toplantı", "mesai", "izinli", "raporlu", "emekli",
        "başvuru", "belge", "imza", "onay", "iptal", "erteleme", "gecikme",
        "yürüyüş", "koşu", "antrenman", "maç", "takım", "kaleci", "gol",
        "beğenmek", "beğendi", "denemek", "denedi", "seçmek", "seçti",
        "kesmek", "kesti", "kestirdim", "değiştirmek", "değiştirdi",
        "temizlemek", "temizledi", "yıkamak", "yıkadı", "ütülemek",
        "sulamak", "budamak", "toplamak", "topladı", "taşımak", "taşıdı",
        "barışmak", "barıştı", "kavga", "tartışma", "sohbet", "muhabbet",
        "uğramak", "uğradı", "yazılmak", "yazıldı", "kaydolmak",
        "patlamak", "patladı", "bozulmak", "bozuldu", "çalışmamak",
        "yoğun", "yoğunluk", "boşluk", "aralık", "süre", "süreç", "aşama",
    ]
}
