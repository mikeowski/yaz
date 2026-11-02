import Foundation

/// One timed span of recognised speech.
struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Result of one transcription pass, before any post-processing.
struct TranscriptionOutput: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    /// Seconds of audio that were transcribed.
    let duration: TimeInterval
    /// Input signal statistics, measured before inference.
    let level: SpeechGate.Level
    /// Whether the transcript is trustworthy enough to insert unattended.
    let quality: TranscriptionQuality

    var isUsable: Bool { quality.verdict.isUsable }
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
    /// Language codes this engine can actually handle. Empty means "any" —
    /// used by engines that auto-detect.
    var supportedLanguages: [String] { get }
    /// Whether the weights are already on disk, so callers can warn about a
    /// multi-hundred-megabyte download *before* the user is mid-sentence.
    var isDownloaded: Bool { get }

    /// Download and load the model. Safe to call more than once.
    func prepare() async throws

    /// Transcribe 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float], options: TranscribeOptions) async throws
        -> TranscriptionOutput

    /// Drop model weights. yaz is a daemon; it should not hold a
    /// multi-hundred-megabyte Core ML model resident while idle.
    func release() async
}

extension Transcriber {
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        try await transcribe(samples, options: .init())
    }

    /// Reject an unsupported language up front. Parakeet silently produces
    /// nonsense for Turkish rather than refusing, so the check has to live
    /// here rather than in the model.
    func validateLanguage(_ language: String) throws {
        guard !supportedLanguages.isEmpty else { return }
        guard supportedLanguages.contains(language) else {
            throw YazError.languageUnsupported(
                engine: name, language: language, supported: supportedLanguages)
        }
    }
}

/// Per-call knobs. Defaults suit the daemon; `yaz transcribe` loosens them so
/// the raw model output stays visible.
struct TranscribeOptions: Sendable {
    var gate = SpeechGate()
    /// The speech check after the level gate. `nil` skips it; the daemon and
    /// `yaz transcribe --strict` turn it on.
    var voice: VoiceCheck? = nil
    var thresholds = TranscriptionQuality.Thresholds.default
    /// Abandon a transcription that hangs. A wedged Core ML call must not take
    /// the daemon with it.
    var timeout: Duration = .seconds(120)
    /// The language for this recording, over the engine's own: a per-app
    /// profile (`AppProfile.language`). Whisper only.
    var language: String? = nil

    /// Show whatever the model produced, however bad.
    static let raw = TranscribeOptions(
        gate: SpeechGate(minSeconds: 0, silencePeak: 0),
        thresholds: .permissive
    )
}

enum TranscriberError: Error, CustomStringConvertible {
    case notPrepared
    case emptyAudio

    var description: String {
        switch self {
        case .notPrepared: "engine used before prepare()"
        case .emptyAudio: "no audio samples to transcribe"
        }
    }
}

/// Run `work`, throwing `YazError.transcriptionTimedOut` if it outlives
/// `timeout`.
///
/// The losing branch is cancelled, but Core ML inference is not itself
/// cancellable mid-prediction — the guarantee is that *the caller* is freed,
/// not that the ANE stops immediately.
func withTranscriptionTimeout<T: Sendable>(
    _ timeout: Duration,
    engine: String,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw YazError.transcriptionTimedOut(
                engine: engine,
                seconds: Double(timeout.components.seconds))
        }
        guard let result = try await group.next() else {
            throw YazError.transcriptionFailed(engine: engine, underlying: "no result produced")
        }
        group.cancelAll()
        return result
    }
}
