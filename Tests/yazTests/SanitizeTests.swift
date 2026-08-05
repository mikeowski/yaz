import Testing

@testable import yaz

@Suite("sanitize — clearing Whisper's non-speech markers")
struct SanitizeTests {

    @Test("bracketed annotation markers are removed")
    func stripsBrackets() {
        #expect(WhisperTranscriber.sanitize("[BLANK_AUDIO] merhaba") == "merhaba")
        #expect(WhisperTranscriber.sanitize("merhaba [MUSIC] dünya") == "merhaba dünya")
    }

    @Test("special tokens are removed")
    func stripsSpecialTokens() {
        #expect(WhisperTranscriber.sanitize("<|nospeech|>test<|endoftext|>") == "test")
    }

    @Test("asterisked stage directions are removed")
    func stripsAsterisks() {
        #expect(WhisperTranscriber.sanitize("*arka plan gürültüsü* tamam") == "tamam")
    }

    @Test("non-speech parentheses are removed")
    func stripsNonSpeechParentheticals() {
        #expect(WhisperTranscriber.sanitize("(sessizlik) merhaba") == "merhaba")
        #expect(WhisperTranscriber.sanitize("merhaba (müzik çalıyor)") == "merhaba")
        #expect(WhisperTranscriber.sanitize("(Music) hello") == "hello")
    }

    /// parrot is too aggressive here: it drops every "(...)", so real dictated
    /// parentheticals go with it. yaz removes only known annotation words.
    @Test("parentheses from real speech are kept")
    func keepsRealParentheses() {
        let input = "toplantı (yarın değil, öbür gün) yapılacak"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }

    @Test("a long parenthetical is not treated as an annotation")
    func keepsLongParentheticals() {
        let input = "bu (aslında bayağı uzun bir açıklama cümlesi) böyle"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }

    @Test("whitespace collapses to single spaces and is trimmed")
    func collapsesWhitespace() {
        #expect(WhisperTranscriber.sanitize("  a    b  \n c ") == "a b c")
    }

    @Test("text left entirely empty by cleaning comes back empty")
    func fullyStrippedBecomesEmpty() {
        #expect(WhisperTranscriber.sanitize("[BLANK_AUDIO]").isEmpty)
        #expect(WhisperTranscriber.sanitize("(sessizlik) [MUSIC]").isEmpty)
    }

    @Test("Turkish characters survive intact")
    func preservesTurkish() {
        let input = "çğıöşü ÇĞİÖŞÜ değişmedi"
        #expect(WhisperTranscriber.sanitize(input) == input)
    }
}
