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

    static func level(_ samples: [Float]) -> Level {
        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = samples.isEmpty ? 0 : Float((sumSquares / Double(samples.count)).squareRoot())
        return Level(peak: peak, rms: rms, seconds: Double(samples.count) / AudioLoader.sampleRate)
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
