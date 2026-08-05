import Foundation
import Testing

@testable import yaz

/// Real microphones are not 16 kHz mono. Built-in inputs report 48 kHz, USB
/// interfaces 44.1 kHz, headsets sometimes 8 kHz, and quill's rca-001 found a
/// route reporting **nine** channels. Every one of those has to arrive at the
/// engine as 16 kHz mono, or the transcript is silence.
@Suite("AudioLoader — sample rate and channel conversion")
struct ResamplingTests {

    static func path(_ name: String) -> String { AudioLoaderTests.path(name) }

    /// Every source file was produced from the same 5.57 s of speech.
    static let expectedSeconds = 5.57
    static let tolerance = 0.15

    @Test(
        "every input format lands at 16 kHz mono with the right duration",
        arguments: [
            "t1.wav",              // 16 kHz mono — no conversion
            "t1-mono-48k.wav",     // downsample, integer ratio
            "t1-stereo-44k.wav",   // downsample + stereo→mono, fractional ratio
            "t1-mono-8k.wav",      // upsample
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
        "the signal survives conversion — we are not producing silent files",
        arguments: ["t1-mono-48k.wav", "t1-stereo-44k.wav", "t1-mono-8k.wav"]
    )
    func signalSurvivesConversion(_ name: String) throws {
        let samples = try AudioLoader.load(Self.path(name))
        let level = SpeechGate.level(samples)
        // Exactly the trap in rca-001: a file of the right duration that is
        // digitally silent. Checking duration alone is not enough.
        #expect(level.peak > 0.05, "\(name) tepe \(level.peak)")
        #expect(level.rms > 0.01, "\(name) rms \(level.rms)")
        #expect(try SpeechGate().check(samples).peak > 0)
    }

    @Test("a stereo source collapses to one channel rather than doubling")
    func stereoDownmixesRatherThanConcatenates() throws {
        let mono = try AudioLoader.load(Self.path("t1.wav"))
        let stereo = try AudioLoader.load(Self.path("t1-stereo-44k.wav"))
        let ratio = Double(stereo.count) / Double(mono.count)
        // Summing the channels instead would have made the ratio ~2.
        #expect(ratio > 0.9 && ratio < 1.1, "oran \(ratio)")
    }

    @Test("no frames lost at a window boundary — 32768-frame windows must cover the whole file")
    func windowBoundariesLoseNoFrames() throws {
        // t2 is 12 s: ~193k samples at 16 kHz, so more than six windows.
        let samples = try AudioLoader.load(Self.path("t2.wav"))
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        #expect(abs(seconds - 12.08) < 0.15, "\(seconds) sn")
    }
}
