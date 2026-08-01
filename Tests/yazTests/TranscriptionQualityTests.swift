import Testing

@testable import yaz

@Suite("TranscriptionQuality — halüsinasyon savunması")
struct TranscriptionQualityTests {

    typealias Signals = TranscriptionQuality.Signals

    /// Gerçek ölçümden alınan sağlıklı sinyaller (fixtures/t2.wav).
    static let healthy = Signals(noSpeechProb: 0.0, avgLogProb: -0.230, compressionRatio: 1.40)

    @Test("sağlıklı çıktı kabul edilir")
    func acceptsHealthy() {
        let q = TranscriptionQuality.assess(text: "Yarın saat ikide toplantı var.", signals: Self.healthy)
        #expect(q.verdict == .good)
        #expect(q.verdict.isUsable)
    }

    @Test("boş metin reddedilir")
    func rejectsEmpty() {
        let q = TranscriptionQuality.assess(text: "   ", signals: Self.healthy)
        #expect(!q.verdict.isUsable)
    }

    @Test("yüksek noSpeech reddedilir — konuşma değil")
    func rejectsNonSpeech() {
        let q = TranscriptionQuality.assess(
            text: "Altyazı M.K.", signals: Signals(noSpeechProb: 0.92, avgLogProb: -0.3, compressionRatio: 1.2))
        #expect(!q.verdict.isUsable)
    }

    @Test("yüksek sıkıştırma oranı tekrar döngüsü demektir")
    func rejectsCompressionLoop() {
        let q = TranscriptionQuality.assess(
            text: "teşekkürler teşekkürler teşekkürler",
            signals: Signals(noSpeechProb: 0.1, avgLogProb: -0.4, compressionRatio: 3.1))
        #expect(!q.verdict.isUsable)
    }

    @Test("çok düşük güven reddedilir")
    func rejectsLowLogProb() {
        let q = TranscriptionQuality.assess(
            text: "bir şeyler", signals: Signals(noSpeechProb: 0.1, avgLogProb: -1.8, compressionRatio: 1.1))
        #expect(!q.verdict.isUsable)
    }

    @Test("orta güven kullanılabilir ama işaretlenir")
    func flagsMediumConfidence() {
        let q = TranscriptionQuality.assess(
            text: "belki böyle", signals: Signals(noSpeechProb: 0.1, avgLogProb: -0.85, compressionRatio: 1.1))
        #expect(q.verdict.isUsable)
        if case .lowConfidence = q.verdict {} else {
            Issue.record("düşük güven bekleniyordu, gelen: \(q.verdict)")
        }
    }

    @Test("kelime tekrarı sıkıştırma oranı yakalayamadan tespit edilir")
    func detectsRepeatsDirectly() {
        // Kısa bir ifadede sıkıştırma oranı eşiği geçmeyebilir; doğrudan bak.
        #expect(TranscriptionQuality.repeatsExcessively("evet evet evet evet evet", limit: 4))
        #expect(!TranscriptionQuality.repeatsExcessively("evet evet hayır evet", limit: 4))
        #expect(!TranscriptionQuality.repeatsExcessively("kısa", limit: 4))
    }

    @Test("tekrar tespiti noktalama ve büyük harfe takılmaz")
    func repeatDetectionNormalises() {
        #expect(TranscriptionQuality.repeatsExcessively("Evet, evet. evet! EVET evet", limit: 4))
    }

    @Test("permissive eşikler hiçbir şeyi reddetmez — boş metin hariç")
    func permissiveKeepsEverything() {
        let awful = Signals(noSpeechProb: 1.0, avgLogProb: -9.0, compressionRatio: 12.0)
        let q = TranscriptionQuality.assess(
            text: "aynı aynı aynı aynı aynı aynı", signals: awful, thresholds: .permissive)
        #expect(q.verdict == .good)
    }

    @Test("permissive bile boş metni reddeder")
    func permissiveStillRejectsEmpty() {
        let q = TranscriptionQuality.assess(text: "", signals: Signals(), thresholds: .permissive)
        #expect(!q.verdict.isUsable)
    }
}

@Suite("TranscriptionQuality — sinyal yokluğu kusursuzluk değildir")
struct MissingSignalsTests {

    /// Signals() alanlarının hepsi sıfır; avgLogProb 0 = log(1.0) = mümkün olan
    /// EN İYİ güven, noSpeechProb 0 = kesinlikle konuşma. Yani sıfırlanmış bir
    /// Signals, "veri yok"u "kusursuz" diye raporlar. Motorlar bu yüzden nil
    /// geçmeli.
    @Test("sıfırlanmış Signals mükemmel güven gibi okunur — bu yüzden nil kullanılır")
    func zeroedSignalsLookPerfect() {
        let zeroed = TranscriptionQuality.Signals()
        let q = TranscriptionQuality.assess(text: "herhangi bir metin", signals: zeroed)
        #expect(q.verdict == .good)
        #expect(!q.isTextOnlyJudgement)
    }

    @Test("nil sinyal metin-temelli karar olarak işaretlenir")
    func nilSignalsAreFlagged() {
        let q = TranscriptionQuality.assess(text: "herhangi bir metin", signals: nil)
        #expect(q.verdict == .good)
        #expect(q.isTextOnlyJudgement)
        #expect(q.signals == nil)
    }

    @Test("sinyal olmasa da boş çıktı reddedilir")
    func stillRejectsEmptyWithoutSignals() {
        let q = TranscriptionQuality.assess(text: "  ", signals: nil)
        #expect(!q.verdict.isUsable)
    }

    @Test("sinyal olmasa da tekrar döngüsü yakalanır — imlece giden asıl hata")
    func stillCatchesRepeatsWithoutSignals() {
        let q = TranscriptionQuality.assess(
            text: "tamam tamam tamam tamam tamam tamam", signals: nil)
        #expect(!q.verdict.isUsable)
    }

    @Test("sinyal yoksa güven eşikleri sessizce uygulanmaz")
    func confidenceGatesSkippedWithoutSignals() {
        // Aynı metin, düşük güven sinyalleriyle reddedilirdi.
        let low = TranscriptionQuality.Signals(
            noSpeechProb: 0.1, avgLogProb: -2.0, compressionRatio: 1.0)
        #expect(!TranscriptionQuality.assess(text: "belirsiz", signals: low).verdict.isUsable)
        #expect(TranscriptionQuality.assess(text: "belirsiz", signals: nil).verdict.isUsable)
    }
}
