import Testing

@testable import yaz

@Suite("TranscriptionQuality — the defence against hallucination")
struct TranscriptionQualityTests {

    typealias Signals = TranscriptionQuality.Signals

    /// Healthy signals taken from a real measurement (fixtures/t2.wav).
    static let healthy = Signals(noSpeechProb: 0.0, avgLogProb: -0.230, compressionRatio: 1.40)

    @Test("healthy output is accepted")
    func acceptsHealthy() {
        let q = TranscriptionQuality.assess(text: "Yarın saat ikide toplantı var.", signals: Self.healthy)
        #expect(q.verdict == .good)
        #expect(q.verdict.isUsable)
    }

    @Test("empty text is rejected")
    func rejectsEmpty() {
        let q = TranscriptionQuality.assess(text: "   ", signals: Self.healthy)
        #expect(!q.verdict.isUsable)
    }

    @Test("a high noSpeech is rejected — that was not speech")
    func rejectsNonSpeech() {
        let q = TranscriptionQuality.assess(
            text: "Altyazı M.K.", signals: Signals(noSpeechProb: 0.92, avgLogProb: -0.3, compressionRatio: 1.2))
        #expect(!q.verdict.isUsable)
    }

    @Test("a high compression ratio means a repeat loop")
    func rejectsCompressionLoop() {
        let q = TranscriptionQuality.assess(
            text: "teşekkürler teşekkürler teşekkürler",
            signals: Signals(noSpeechProb: 0.1, avgLogProb: -0.4, compressionRatio: 3.1))
        #expect(!q.verdict.isUsable)
    }

    @Test("very low confidence is rejected")
    func rejectsLowLogProb() {
        let q = TranscriptionQuality.assess(
            text: "bir şeyler", signals: Signals(noSpeechProb: 0.1, avgLogProb: -1.8, compressionRatio: 1.1))
        #expect(!q.verdict.isUsable)
    }

    @Test("middling confidence is usable but flagged")
    func flagsMediumConfidence() {
        let q = TranscriptionQuality.assess(
            text: "belki böyle", signals: Signals(noSpeechProb: 0.1, avgLogProb: -0.85, compressionRatio: 1.1))
        #expect(q.verdict.isUsable)
        if case .lowConfidence = q.verdict {} else {
            Issue.record("expected low confidence, got: \(q.verdict)")
        }
    }

    @Test("word repetition is caught before the compression ratio can see it")
    func detectsRepeatsDirectly() {
        // On a short utterance the ratio may not cross the threshold; look
        // for the repetition directly.
        #expect(TranscriptionQuality.repeatsExcessively("evet evet evet evet evet", limit: 4))
        #expect(!TranscriptionQuality.repeatsExcessively("evet evet hayır evet", limit: 4))
        #expect(!TranscriptionQuality.repeatsExcessively("kısa", limit: 4))
    }

    @Test("repeat detection is not thrown by punctuation or case")
    func repeatDetectionNormalises() {
        #expect(TranscriptionQuality.repeatsExcessively("Evet, evet. evet! EVET evet", limit: 4))
    }

    @Test("permissive thresholds reject nothing — except empty text")
    func permissiveKeepsEverything() {
        let awful = Signals(noSpeechProb: 1.0, avgLogProb: -9.0, compressionRatio: 12.0)
        let q = TranscriptionQuality.assess(
            text: "aynı aynı aynı aynı aynı aynı", signals: awful, thresholds: .permissive)
        #expect(q.verdict == .good)
    }

    @Test("even permissive rejects empty text")
    func permissiveStillRejectsEmpty() {
        let q = TranscriptionQuality.assess(text: "", signals: Signals(), thresholds: .permissive)
        #expect(!q.verdict.isUsable)
    }
}

@Suite("TranscriptionQuality — absent signals are not perfect ones")
struct MissingSignalsTests {

    /// Every field of Signals() is zero — and avgLogProb 0 = log(1.0) is the
    /// BEST confidence possible, noSpeechProb 0 means definitely speech. So a
    /// zeroed Signals reports "no data" as "flawless". That is why engines
    /// must pass nil instead.
    @Test("a zeroed Signals reads as perfect confidence — hence nil")
    func zeroedSignalsLookPerfect() {
        let zeroed = TranscriptionQuality.Signals()
        let q = TranscriptionQuality.assess(text: "herhangi bir metin", signals: zeroed)
        #expect(q.verdict == .good)
        #expect(!q.isTextOnlyJudgement)
    }

    @Test("a nil signal is marked as a text-only verdict")
    func nilSignalsAreFlagged() {
        let q = TranscriptionQuality.assess(text: "herhangi bir metin", signals: nil)
        #expect(q.verdict == .good)
        #expect(q.isTextOnlyJudgement)
        #expect(q.signals == nil)
    }

    @Test("empty output is rejected even with no signals")
    func stillRejectsEmptyWithoutSignals() {
        let q = TranscriptionQuality.assess(text: "  ", signals: nil)
        #expect(!q.verdict.isUsable)
    }

    @Test("a repeat loop is caught even with no signals — the one that reaches the cursor")
    func stillCatchesRepeatsWithoutSignals() {
        let q = TranscriptionQuality.assess(
            text: "tamam tamam tamam tamam tamam tamam", signals: nil)
        #expect(!q.verdict.isUsable)
    }

    @Test("confidence thresholds are not applied silently when signals are absent")
    func confidenceGatesSkippedWithoutSignals() {
        // The same text would have been rejected with low-confidence signals.
        let low = TranscriptionQuality.Signals(
            noSpeechProb: 0.1, avgLogProb: -2.0, compressionRatio: 1.0)
        #expect(!TranscriptionQuality.assess(text: "belirsiz", signals: low).verdict.isUsable)
        #expect(TranscriptionQuality.assess(text: "belirsiz", signals: nil).verdict.isUsable)
    }
}
