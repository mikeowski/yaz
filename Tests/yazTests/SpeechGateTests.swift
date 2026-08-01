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
