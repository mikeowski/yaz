import Testing

@testable import yaz

@Suite("SpeechGate — the cheap gates before inference")
struct SpeechGateTests {

    /// Builds 16 kHz mono samples.
    static func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * AudioLoader.sampleRate)
        return (0..<count).map { amplitude * Float(sin(Double($0) * 0.1)) }
    }

    @Test("an ordinary speech level passes")
    func passesSpeech() throws {
        let level = try SpeechGate().check(Self.tone(seconds: 2, amplitude: 0.2))
        #expect(level.seconds == 2)
        #expect(level.peak > 0.1)
        #expect(level.rms > 0)
    }

    @Test("a very short recording is rejected — measured: a 0.6 s utterance returns nothing from Whisper")
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

    @Test("noise below the threshold counts as silence")
    func rejectsNoiseFloor() {
        #expect(throws: YazError.self) {
            try SpeechGate().check(Self.tone(seconds: 2, amplitude: 0.0008))
        }
    }

    @Test("an empty buffer is rejected rather than crashing")
    func handlesEmpty() {
        let level = SpeechGate.level([])
        #expect(level.peak == 0)
        #expect(level.rms == 0)
        #expect(level.seconds == 0)
        #expect(throws: YazError.self) { try SpeechGate().check([]) }
    }

    @Test("rejections are marked benign — the daemon should drop them quietly")
    func rejectionsAreBenign() {
        let short = YazError.audioTooShort(seconds: 0.1, minimum: 0.35)
        let silent = YazError.audioSilent(peak: 0.0001, threshold: 0.005)
        let broken = YazError.modelLoadFailed(model: "x", underlying: "y")
        #expect(short.isBenignInput)
        #expect(silent.isBenignInput)
        #expect(!broken.isBenignInput)
    }

    @Test("the lenient gate passes everything — the measurement harness needs the raw output")
    func rawOptionsPassEverything() throws {
        let gate = TranscribeOptions.raw.gate
        _ = try gate.check(Self.tone(seconds: 0.05, amplitude: 0))
    }
}

import func Foundation.sin

@Suite("SpeechGate — the vDSP measurement must match the scalar reference")
struct LevelAccuracyTests {

    /// Moving to vDSP must not change the result; the scalar reference lives here.
    static func reference(_ samples: [Float]) -> (peak: Float, rms: Float) {
        var peak: Float = 0
        var sum: Double = 0
        for s in samples {
            peak = max(peak, abs(s))
            sum += Double(s) * Double(s)
        }
        return (peak, samples.isEmpty ? 0 : Float((sum / Double(samples.count)).squareRoot()))
    }

    @Test("vDSP and scalar agree on a sine wave")
    func matchesOnTone() {
        let samples = (0..<50_000).map { 0.3 * Float(sin(Double($0) * 0.01)) }
        let fast = SpeechGate.level(samples)
        let slow = Self.reference(samples)
        #expect(abs(fast.peak - slow.peak) < 1e-5)
        #expect(abs(fast.rms - slow.rms) < 1e-4)
    }

    @Test("a negative peak is taken as its absolute value")
    func peakUsesMagnitude() {
        let level = SpeechGate.level([-0.9, 0.1, 0.2])
        #expect(abs(level.peak - 0.9) < 1e-6)
    }

    @Test("a single-sample buffer does not crash")
    func singleSample() {
        let level = SpeechGate.level([0.5])
        #expect(abs(level.peak - 0.5) < 1e-6)
        #expect(abs(level.rms - 0.5) < 1e-6)
    }

    @Test("duration is computed correctly from the sample count")
    func durationIsCorrect() {
        let level = SpeechGate.level([Float](repeating: 0.1, count: 16_000))
        #expect(abs(level.seconds - 1.0) < 1e-9)
    }
}
