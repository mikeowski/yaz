import FluidAudio
import Foundation

/// Decides from per-window speech probabilities whether a recording holds
/// speech.
///
/// `SpeechGate` only looks at loudness. A loud room, a fan, keyboard noise or
/// a cough pass it easily, and Whisper invents a sentence for them. A voice
/// activity detector tells speech from noise of the same level. Hex uses
/// Silero for the same reason.
///
/// This type is pure logic so that it can be tested without the model.
struct VoiceActivityGate: Sendable, Equatable {

    /// Lenient on purpose. A missed utterance is lost dictation; a noise
    /// recording that gets through still meets the decoder-signal checks in
    /// `TranscriptionQuality`. Hex uses 0.4 on Silero; this is lower because
    /// FluidAudio scores 256 ms windows, and a short word can fall across two
    /// of them. Calibrate with `yaz transcribe`, which prints the scores.
    static let defaultThreshold: Float = 0.3

    var threshold: Float = defaultThreshold

    struct Verdict: Sendable, Equatable {
        let hasSpeech: Bool
        /// The highest window probability.
        let peakProbability: Float
        /// Windows at or above the threshold.
        let speechWindows: Int
        let windows: Int
    }

    /// One window at or above the threshold is enough. No windows means no
    /// evidence, and no evidence must never drop a recording.
    func verdict(for probabilities: [Float]) -> Verdict {
        let peak = probabilities.max() ?? 0
        let speech = probabilities.filter { $0 >= threshold }.count
        return Verdict(
            hasSpeech: probabilities.isEmpty || speech > 0,
            peakProbability: peak,
            speechWindows: speech,
            windows: probabilities.count)
    }
}

/// Something that scores 16 kHz mono audio for speech.
protocol VoiceActivityDetector: Sendable {
    /// One probability per window, or `nil` when the detector cannot answer
    /// (the model is not loaded yet, or failed). Callers must then keep the
    /// recording: the detector is an extra filter, never a requirement.
    func speechProbabilities(_ samples: [Float]) async -> [Float]?
}

/// The voice check that runs after the level gate.
struct VoiceCheck: Sendable {
    var detector: any VoiceActivityDetector
    var gate = VoiceActivityGate()

    /// Throws `YazError.noSpeechDetected` when the detector is sure there is
    /// no speech. Returns `nil` when the detector could not answer.
    @discardableResult
    func check(_ samples: [Float]) async throws -> VoiceActivityGate.Verdict? {
        guard let probabilities = await detector.speechProbabilities(samples) else {
            return nil
        }
        let verdict = gate.verdict(for: probabilities)
        guard verdict.hasSpeech else {
            throw YazError.noSpeechDetected(
                probability: verdict.peakProbability, threshold: gate.threshold)
        }
        return verdict
    }
}

/// Silero VAD from FluidAudio, on the Neural Engine.
///
/// The model is small and comes from the same place as the Parakeet weights.
/// FluidAudio stores it in `~/Library/Application Support/FluidAudio`, outside
/// `~/Documents`, so iCloud does not upload it.
///
/// Until `prepare()` has finished, and if it fails, every answer is `nil`, and
/// yaz behaves as it did without a detector.
actor SileroVoiceActivity: VoiceActivityDetector {

    static let shared = SileroVoiceActivity()

    private var manager: VadManager?
    private var loading: Task<VadManager?, Never>?
    private var reportedFailure = false

    var isReady: Bool { manager != nil }

    /// Download if needed and load. Safe to call more than once; concurrent
    /// callers share one load. A failed load is not cached, so a later call
    /// retries — the usual cause is a network failure.
    func prepare() async {
        if manager != nil { return }
        if let loading {
            _ = await loading.value
            return
        }
        let task = Task<VadManager?, Never> {
            do {
                return try await VadManager()
            } catch {
                log("voice activity detector unavailable: \(error) — using the level gate only")
                return nil
            }
        }
        loading = task
        let loaded = await task.value
        if manager == nil { manager = loaded }
        loading = nil
    }

    func speechProbabilities(_ samples: [Float]) async -> [Float]? {
        guard let manager, !samples.isEmpty else { return nil }
        do {
            return try await manager.process(samples).map(\.probability)
        } catch {
            // Log once: a broken detector would otherwise write a line for
            // every utterance.
            if !reportedFailure {
                reportedFailure = true
                log("voice activity detector failed: \(error) — using the level gate only")
            }
            return nil
        }
    }
}
