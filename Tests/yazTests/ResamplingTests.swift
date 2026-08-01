import Foundation
import Testing

@testable import yaz

/// Real microphones are not 16 kHz mono. Built-in inputs report 48 kHz, USB
/// interfaces 44.1 kHz, headsets sometimes 8 kHz, and quill's rca-001 found a
/// route reporting **nine** channels. Every one of those has to arrive at the
/// engine as 16 kHz mono, or the transcript is silence.
@Suite("AudioLoader — örnekleme hızı ve kanal dönüşümü")
struct ResamplingTests {

    static func path(_ name: String) -> String { AudioLoaderTests.path(name) }

    /// Kaynak dosyaların hepsi aynı 5.57 sn'lik konuşmadan üretildi.
    static let expectedSeconds = 5.57
    static let tolerance = 0.15

    @Test(
        "her giriş formatı 16 kHz mono'ya doğru sürede iner",
        arguments: [
            "t1.wav",              // 16 kHz mono — dönüşüm yok
            "t1-mono-48k.wav",     // aşağı örnekleme, tam katsayı
            "t1-stereo-44k.wav",   // aşağı örnekleme + stereo→mono, kesirli oran
            "t1-mono-8k.wav",      // yukarı örnekleme
        ]
    )
    func convertsToCanonicalFormat(_ name: String) throws {
        let samples = try AudioLoader.load(Self.path(name))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        #expect(
            abs(seconds - Self.expectedSeconds) < Self.tolerance,
            "\(name): \(seconds) sn, beklenen ~\(Self.expectedSeconds) sn")
    }

    @Test(
        "dönüşüm sonrası sinyal hayatta kalır — sessiz dosya üretmiyoruz",
        arguments: ["t1-mono-48k.wav", "t1-stereo-44k.wav", "t1-mono-8k.wav"]
    )
    func signalSurvivesConversion(_ name: String) throws {
        let samples = try AudioLoader.load(Self.path(name))
        let level = SpeechGate.level(samples)
        // rca-001'in tuzağı tam buydu: doğru süreli ama dijital olarak sessiz
        // dosya. Süre kontrolü tek başına yeterli değil.
        #expect(level.peak > 0.05, "\(name) tepe \(level.peak)")
        #expect(level.rms > 0.01, "\(name) rms \(level.rms)")
        #expect(try SpeechGate().check(samples).peak > 0)
    }

    @Test("stereo kaynak tek kanala iner, iki katına çıkmaz")
    func stereoDownmixesRatherThanConcatenates() throws {
        let mono = try AudioLoader.load(Self.path("t1.wav"))
        let stereo = try AudioLoader.load(Self.path("t1-stereo-44k.wav"))
        let ratio = Double(stereo.count) / Double(mono.count)
        // Kanallar birleştirilseydi oran ~2 olurdu.
        #expect(ratio > 0.9 && ratio < 1.1, "oran \(ratio)")
    }

    @Test("pencere sınırında kare kaybı yok — 32768'lik pencereler bütünü kapsamalı")
    func windowBoundariesLoseNoFrames() throws {
        // t2 12 sn: 16 kHz'de ~193k örnek, yani 6 pencereden fazla.
        let samples = try AudioLoader.load(Self.path("t2.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        #expect(abs(seconds - 12.08) < 0.15, "\(seconds) sn")
    }
}
