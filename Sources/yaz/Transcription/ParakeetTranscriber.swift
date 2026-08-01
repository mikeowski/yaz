import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port, running on the Apple
/// Neural Engine.
///
/// Kept as the fast path for languages it actually covers. **It does not cover
/// Turkish** — see `supportedLanguages` — so it is not, and cannot be, yaz's
/// default. Where it applies it is roughly an order of magnitude cheaper than
/// Whisper: ~600 MB of weights against 1.6 GB, and a far lower real-time
/// factor.
actor ParakeetTranscriber: Transcriber {
    nonisolated let name = "parakeet"
    nonisolated let model: String

    /// Parakeet TDT v3's language list: 25 EU languages plus Russian and
    /// Ukrainian. Turkish is absent — confirmed against NVIDIA's model card
    /// and FluidAudio's own `Language` enum, which has no `tr` case. Listing
    /// it here turns a silently wrong transcript into a refusal.
    nonisolated let supportedLanguages: [String]

    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v3) {
        self.version = version
        switch version {
        case .v3:
            self.model = "parakeet-tdt-0.6b-v3-coreml"
            self.supportedLanguages = [
                "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el",
                "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es",
                "sv", "ru", "uk",
            ]
        case .v2:
            self.model = "parakeet-tdt-0.6b-v2-coreml"
            self.supportedLanguages = ["en"]
        @unknown default:
            self.model = "parakeet-unknown"
            self.supportedLanguages = ["en"]
        }
    }

    nonisolated var isDownloaded: Bool {
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version),
            version: version
        )
    }

    func prepare() async throws {
        guard manager == nil else { return }
        do {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            self.manager = manager
        } catch {
            throw YazError.modelLoadFailed(model: model, underlying: "\(error)")
        }
    }

    func transcribe(
        _ samples: [Float], options: TranscribeOptions
    ) async throws -> TranscriptionOutput {
        let level = try options.gate.check(samples)
        guard let manager else { throw YazError.engineNotPrepared(engine: name) }

        let engineName = name
        let result: ASRResult
        do {
            result = try await withTranscriptionTimeout(options.timeout, engine: engineName) {
                var state = try TdtDecoderState()
                return try await manager.transcribe(samples, decoderState: &state)
            }
        } catch let error as YazError {
            throw error
        } catch {
            throw YazError.transcriptionFailed(engine: engineName, underlying: "\(error)")
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = result.tokenTimings ?? []
        let segments = words.isEmpty
            ? (text.isEmpty ? [] : [TranscriptSegment(start: 0, end: result.duration, text: text)])
            : Self.segments(from: words)

        // Parakeet exposes no per-segment confidence, so the decoder-signal
        // gates cannot fire. Repetition is still detectable from the text
        // itself, which is the failure mode that actually reaches the cursor.
        let signals = TranscriptionQuality.Signals()
        return TranscriptionOutput(
            text: text,
            segments: segments,
            duration: level.seconds,
            level: level,
            quality: .assess(text: text, signals: signals, thresholds: options.thresholds)
        )
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation, on a silence gap, or at a hard length cap so a run-on
    /// speaker still wraps.
    private static func segments(from words: [TokenTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TokenTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.token).joined().trimmingCharacters(in: .whitespaces)
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 { flush() }
            current.append(word)
            let token = word.token
            if token.hasSuffix(".") || token.hasSuffix("?") || token.hasSuffix("!")
                || current.count >= 60
            {
                flush()
            }
        }
        flush()
        return out
    }
}
