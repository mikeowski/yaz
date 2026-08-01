import Testing

@testable import yaz

@Suite("sanitize — Whisper'ın konuşma-dışı işaretlerini temizleme")
struct SanitizeTests {

    @Test("köşeli parantez içindeki not işaretleri silinir")
    func stripsBrackets() {
        #expect(WhisperTranscriber.sanitize("[BLANK_AUDIO] merhaba") == "merhaba")
        #expect(WhisperTranscriber.sanitize("merhaba [MUSIC] dünya") == "merhaba dünya")
    }

    @Test("özel token'lar silinir")
    func stripsSpecialTokens() {
        #expect(WhisperTranscriber.sanitize("<|nospeech|>test<|endoftext|>") == "test")
    }

    @Test("yıldızlı sahne notları silinir")
    func stripsAsterisks() {
        #expect(WhisperTranscriber.sanitize("*arka plan gürültüsü* tamam") == "tamam")
    }

    @Test("konuşma-dışı parantezler silinir")
    func stripsNonSpeechParentheticals() {
        #expect(WhisperTranscriber.sanitize("(sessizlik) merhaba") == "merhaba")
        #expect(WhisperTranscriber.sanitize("merhaba (müzik çalıyor)") == "merhaba")
        #expect(WhisperTranscriber.sanitize("(Music) hello") == "hello")
    }

    /// parrot bu noktada fazla agresif: her "(...)" silindiği için dikte edilen
    /// gerçek parantezli ifadeler de gidiyor. yaz yalnızca bilinen not
    /// sözcüklerini siler.
    @Test("gerçek konuşmadaki parantezler korunur")
    func keepsRealParentheses() {
        let input = "toplantı (yarın değil, öbür gün) yapılacak"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }

    @Test("uzun parantezli ifade not sayılmaz")
    func keepsLongParentheticals() {
        let input = "bu (aslında bayağı uzun bir açıklama cümlesi) böyle"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }

    @Test("boşluklar tek boşluğa indirgenir ve kırpılır")
    func collapsesWhitespace() {
        #expect(WhisperTranscriber.sanitize("  a    b  \n c ") == "a b c")
    }

    @Test("temizlik sonrası tamamen boşalan metin boş döner")
    func fullyStrippedBecomesEmpty() {
        #expect(WhisperTranscriber.sanitize("[BLANK_AUDIO]").isEmpty)
        #expect(WhisperTranscriber.sanitize("(sessizlik) [MUSIC]").isEmpty)
    }

    @Test("Türkçe karakterler bozulmaz")
    func preservesTurkish() {
        let input = "çğıöşü ÇĞİÖŞÜ değişmedi"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }
}
