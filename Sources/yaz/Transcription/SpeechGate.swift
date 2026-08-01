import Accelerate
import Foundation

/// Cheap checks run on raw samples *before* paying for inference.
///
/// Two measured facts drive this. Whisper returns an empty string for
/// utterances under about a second, so a tap of the hotkey costs a model round
/// trip and yields nothing. And fed silence it does not stay quiet — it emits
/// `[BLANK_AUDIO]`, `(müzik)`, or an outright invented sentence, which is
/// intolerable when the output is typed straight into the user's cursor.
///
/// Rejecting here costs microseconds; rejecting after inference costs ~500 ms.
struct SpeechGate: Sendable {

    /// Below this, Whisper reliably returns nothing.
    static let defaultMinSeconds: Double = 0.35

    /// Peak amplitude under which we treat the buffer as silence. Chosen well
    /// under normal speech (peaks 0.05–0.5 on a built-in mic) but above the
    /// noise floor of a muted or disconnected input.
    static let defaultSilencePeak: Float = 0.005

    var minSeconds: Double = defaultMinSeconds
    var silencePeak: Float = defaultSilencePeak

    /// Signal statistics, also useful for the recording indicator.
    struct Level: Sendable {
        let peak: Float
        let rms: Float
        let seconds: Double
    }

    /// Peak and RMS over the buffer.
    ///
    /// vDSP rather than a scalar loop: this runs on every utterance, and on a
    /// long file the buffer is tens of millions of samples (one hour at
    /// 16 kHz is 57.6 M). A gate that is supposed to be cheaper than inference
    /// should not be the thing that costs.
    static func level(_ samples: [Float]) -> Level {
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        guard !samples.isEmpty else { return Level(peak: 0, rms: 0, seconds: 0) }

        var peak: Float = 0
        var rms: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(buffer.count))
            vDSP_rmsqv(base, 1, &rms, vDSP_Length(buffer.count))
        }
        return Level(peak: peak, rms: rms, seconds: seconds)
    }

    /// Throw a benign `YazError` when this buffer is not worth transcribing.
    func check(_ samples: [Float]) throws -> Level {
        let level = Self.level(samples)
        guard level.seconds >= minSeconds else {
            throw YazError.audioTooShort(seconds: level.seconds, minimum: minSeconds)
        }
        guard level.peak >= silencePeak else {
            throw YazError.audioSilent(peak: level.peak, threshold: silencePeak)
        }
        return level
    }
}
