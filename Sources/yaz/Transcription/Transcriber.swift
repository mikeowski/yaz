import Foundation

/// One timed span of recognised speech.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Result of one transcription pass, before any post-processing.
struct TranscriptionOutput: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    /// Seconds of audio that were transcribed — used to report the real-time factor.
    let duration: TimeInterval
}

/// A speech-to-text engine yaz can run locally.
///
/// Dictation hands over an in-memory sample buffer rather than a file URL:
/// utterances are seconds long, and writing them to disk just to read them
/// back would add latency to the one path where latency is the product.
protocol Transcriber: Sendable {
    /// Short engine identifier, reported by `yaz doctor` and `--verbose`.
    var name: String { get }
    /// Concrete model identifier.
    var model: String { get }

    /// Download and load the model. Safe to call more than once.
    func prepare() async throws

    /// Transcribe 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput

    /// Drop model weights. yaz is a daemon; it should not hold a multi-hundred
    /// megabyte CoreML model resident while idle unless the user opted into it.
    func release() async
}

enum TranscriberError: Error, CustomStringConvertible {
    case notPrepared
    case emptyAudio

    var description: String {
        switch self {
        case .notPrepared: return "engine used before prepare()"
        case .emptyAudio: return "no audio samples to transcribe"
        }
    }
}
