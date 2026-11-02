import Foundation
import Testing

@testable import yaz

/// A detector that returns fixed scores, or `nil` like a model that is not
/// loaded.
struct StubDetector: VoiceActivityDetector {
    let probabilities: [Float]?
    func speechProbabilities(_ samples: [Float]) async -> [Float]? { probabilities }
}

@Suite("VoiceActivityGate — loud is not the same as speech")
struct VoiceActivityGateTests {

    @Test("one window over the threshold is speech")
    func oneWindowIsEnough() {
        let verdict = VoiceActivityGate().verdict(for: [0.02, 0.05, 0.6, 0.1])
        #expect(verdict.hasSpeech)
        #expect(verdict.speechWindows == 1)
        #expect(verdict.windows == 4)
        #expect(verdict.peakProbability == 0.6)
    }

    @Test("every window under the threshold is not speech")
    func allLowIsNoSpeech() {
        let verdict = VoiceActivityGate().verdict(for: [0.01, 0.12, 0.29])
        #expect(!verdict.hasSpeech)
        #expect(verdict.speechWindows == 0)
    }

    @Test("the threshold itself counts as speech")
    func thresholdIsInclusive() {
        let gate = VoiceActivityGate(threshold: 0.5)
        #expect(gate.verdict(for: [0.5]).hasSpeech)
    }

    /// No windows means no evidence. Dropping the recording on no evidence
    /// would lose dictation for nothing.
    @Test("no scores keep the recording")
    func noScoresKeep() {
        #expect(VoiceActivityGate().verdict(for: []).hasSpeech)
    }

    @Test("the default is lenient")
    func defaultIsLenient() {
        #expect(VoiceActivityGate.defaultThreshold <= 0.4)
        #expect(VoiceActivityGate.defaultThreshold > 0)
    }
}

@Suite("VoiceCheck — the detector is a filter, never a requirement")
struct VoiceCheckTests {

    static let samples = [Float](repeating: 0.1, count: 16_000)

    @Test("speech passes and reports its verdict")
    func speechPasses() async throws {
        let check = VoiceCheck(detector: StubDetector(probabilities: [0.9, 0.8]))
        let verdict = try await check.check(Self.samples)
        #expect(verdict?.hasSpeech == true)
    }

    @Test("noise is rejected with a benign error")
    func noiseIsRejected() async {
        let check = VoiceCheck(detector: StubDetector(probabilities: [0.05, 0.1]))
        await #expect(throws: YazError.noSpeechDetected(probability: 0.1, threshold: 0.3)) {
            try await check.check(Self.samples)
        }
        #expect(YazError.noSpeechDetected(probability: 0.1, threshold: 0.3).isBenignInput)
    }

    /// The model downloads in the background, and can fail to load. In both
    /// cases yaz must behave as it did before the detector existed.
    @Test("a detector that cannot answer lets everything through")
    func unavailableDetectorPasses() async throws {
        let check = VoiceCheck(detector: StubDetector(probabilities: nil))
        let verdict = try await check.check(Self.samples)
        #expect(verdict == nil)
    }

    @Test("the threshold from the check is used")
    func usesItsThreshold() async throws {
        let strict = VoiceCheck(
            detector: StubDetector(probabilities: [0.5]),
            gate: VoiceActivityGate(threshold: 0.7))
        await #expect(throws: YazError.self) { try await strict.check(Self.samples) }

        let lenient = VoiceCheck(
            detector: StubDetector(probabilities: [0.5]),
            gate: VoiceActivityGate(threshold: 0.2))
        _ = try await lenient.check(Self.samples)
    }

    @Test("the default options do not run a voice check")
    func defaultOptionsSkipIt() {
        #expect(TranscribeOptions().voice == nil)
        #expect(TranscribeOptions.raw.voice == nil)
    }
}

@Suite("Config — the voice check settings")
struct VoiceActivityConfigTests {

    /// The threshold is not yet measured on real microphones, and a wrong
    /// one loses dictation silently. Opt-in until it is.
    @Test("off by default, with the default threshold")
    func defaults() {
        let config = Config()
        #expect(!config.vad)
        #expect(config.voiceCheck == nil)
        #expect(config.vadThreshold == VoiceActivityGate.defaultThreshold)
    }

    @Test("both keys are read")
    func readsKeys() {
        var config = Config()
        config.apply(["vad": true, "vad_threshold": 0.5], source: "test")
        #expect(config.vad)
        #expect(config.vadThreshold == 0.5)
        #expect(config.voiceCheck?.gate.threshold == 0.5)
    }

    @Test("a threshold outside (0, 1) is ignored")
    func rejectsBadThreshold() {
        let values: [Any] = [0, 1, 1.5, -0.2, "high"]
        for raw in values {
            var config = Config()
            config.apply(["vad_threshold": raw], source: "test")
            #expect(config.vadThreshold == VoiceActivityGate.defaultThreshold)
        }
    }

    @Test("the settings survive a write and a read")
    func roundTrips() throws {
        var config = Config()
        config.vad = true
        config.vadThreshold = 0.45
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-vad-\(UUID().uuidString)")
            .appending(path: "config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try config.save(to: url)
        let loaded = Config.load(from: url)
        #expect(loaded.vad == true)
        #expect(loaded.vadThreshold == 0.45)
    }
}
