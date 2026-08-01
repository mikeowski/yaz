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

    /// Same protections as the Whisper path: one load under concurrent
    /// `prepare()` calls, and no overlapping inference.
    private let loader = SingleFlight()
    private let inference = SerialGate()

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
        if manager != nil { return }
        let version = self.version
        let modelID = self.model
        let box = ManagerBox()
        try await loader.run {
            do {
                let models = try await AsrModels.downloadAndLoad(version: version)
                let manager = AsrManager()
                try await manager.loadModels(models)
                box.value = manager
            } catch {
                throw YazError.modelLoadFailed(model: modelID, underlying: "\(error)")
            }
        }
        // A queued caller finds the winner already installed and skips its own.
        if manager == nil { manager = box.value }
    }

    /// Carries the loaded manager out of the `@Sendable` single-flight closure.
    /// `AsrManager` is an actor, so the reference itself is safe to move.
    private final class ManagerBox: @unchecked Sendable {
        var value: AsrManager?
    }

    func transcribe(
        _ samples: [Float], options: TranscribeOptions
    ) async throws -> TranscriptionOutput {
        let level = try options.gate.check(samples)
        guard let manager else { throw YazError.engineNotPrepared(engine: name) }

        let engineName = name
        let result: ASRResult
        do {
            result = try await inference.run {
                try await withTranscriptionTimeout(options.timeout, engine: engineName) {
                    var state = try TdtDecoderState()
                    return try await manager.transcribe(samples, decoderState: &state)
                }
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

        // Parakeet exposes no per-segment confidence. Passing `nil` rather
        // than a zeroed `Signals()` matters: the zero value reads as maximum
        // confidence, so the absence of data would otherwise wave every
        // Parakeet transcript through. Text-shaped checks still apply.
        return TranscriptionOutput(
            text: text,
            segments: segments,
            duration: level.seconds,
            level: level,
            quality: .assess(text: text, signals: nil, thresholds: options.thresholds)
        )
    }

    func release() async {
        // Drain queued inference before tearing the models down.
        _ = try? await inference.run { }
        if let manager { await manager.cleanup() }
        manager = nil
        await loader.reset()
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
