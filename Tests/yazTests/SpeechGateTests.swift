import Testing

@testable import yaz

@Suite("SpeechGate — çıkarımdan önceki ucuz kapılar")
struct SpeechGateTests {

    /// 16 kHz mono örnek üretici.
    static func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * AudioLoader.sampleRate)
        return (0..<count).map { amplitude * Float(sin(Double($0) * 0.1)) }
    }

    @Test("normal konuşma seviyesi geçer")
    func passesSpeech() throws {
        let level = try SpeechGate().check(Self.tone(seconds: 2, amplitude: 0.2))
        #expect(level.seconds == 2)
        #expect(level.peak > 0.1)
        #expect(level.rms > 0)
    }

    @Test("çok kısa kayıt reddedilir — ölçüldü: 0.6 sn'lik ifade Whisper'dan boş dönüyor")
    func rejectsShort() {
        #expect(throws: YazError.self) {
            try SpeechGate().check(Self.tone(seconds: 0.2, amplitude: 0.3))
        }
    }

    @Test("sessizlik reddedilir — Whisper sessizlikte metin uyduruyor")
    func rejectsSilence() {
        #expect(throws: YazError.self) {
            try SpeechGate().check(Self.tone(seconds: 3, amplitude: 0))
        }
    }

    @Test("eşik altı gürültü sessizlik sayılır")
    func rejectsNoiseFloor() {
        #expect(throws: YazError.self) {
            try SpeechGate().check(Self.tone(seconds: 2, amplitude: 0.0008))
        }
    }

    @Test("boş tampon reddedilir, çökmez")
    func handlesEmpty() {
        let level = SpeechGate.level([])
        #expect(level.peak == 0)
        #expect(level.rms == 0)
        #expect(level.seconds == 0)
        #expect(throws: YazError.self) { try SpeechGate().check([]) }
    }

    @Test("reddedilen girdiler iyi huylu olarak işaretlenir — daemon sessizce atmalı")
    func rejectionsAreBenign() {
        let short = YazError.audioTooShort(seconds: 0.1, minimum: 0.35)
        let silent = YazError.audioSilent(peak: 0.0001, threshold: 0.005)
        let broken = YazError.modelLoadFailed(model: "x", underlying: "y")
        #expect(short.isBenignInput)
        #expect(silent.isBenignInput)
        #expect(!broken.isBenignInput)
    }

    @Test("gevşek kapı her şeyi geçirir — ölçüm koşum takımı ham çıktıyı görmeli")
    func rawOptionsPassEverything() throws {
        let gate = TranscribeOptions.raw.gate
        _ = try gate.check(Self.tone(seconds: 0.05, amplitude: 0))
    }
}

import func Foundation.sin

@Suite("SpeechGate — vDSP ölçümü skaler referansla aynı sonucu vermeli")
struct LevelAccuracyTests {

    /// vDSP'ye geçerken sonuç değişmemeli; referans skaler hesap burada.
    static func reference(_ samples: [Float]) -> (peak: Float, rms: Float) {
        var peak: Float = 0
        var sum: Double = 0
        for s in samples {
            peak = max(peak, abs(s))
            sum += Double(s) * Double(s)
        }
        return (peak, samples.isEmpty ? 0 : Float((sum / Double(samples.count)).squareRoot()))
    }

    @Test("sinüs dalgasında vDSP ve skaler eşleşir")
    func matchesOnTone() {
        let samples = (0..<50_000).map { 0.3 * Float(sin(Double($0) * 0.01)) }
        let fast = SpeechGate.level(samples)
        let slow = Self.reference(samples)
        #expect(abs(fast.peak - slow.peak) < 1e-5)
        #expect(abs(fast.rms - slow.rms) < 1e-4)
    }

    @Test("negatif tepe genliği mutlak değer olarak alınır")
    func peakUsesMagnitude() {
        let level = SpeechGate.level([-0.9, 0.1, 0.2])
        #expect(abs(level.peak - 0.9) < 1e-6)
    }

    @Test("tek örneklik tampon çökmez")
    func singleSample() {
        let level = SpeechGate.level([0.5])
        #expect(abs(level.peak - 0.5) < 1e-6)
        #expect(abs(level.rms - 0.5) < 1e-6)
    }

    @Test("süre örnek sayısından doğru hesaplanır")
    func durationIsCorrect() {
        let level = SpeechGate.level([Float](repeating: 0.1, count: 16_000))
        #expect(abs(level.seconds - 1.0) < 1e-9)
    }
}
