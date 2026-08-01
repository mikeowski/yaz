import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port, running on the Apple
/// Neural Engine.
///
/// v3 is the multilingual checkpoint (25 European languages including Turkish,
/// plus Japanese) and is the reason yaz exists — parrot ships English-only
/// Whisper by default, and Whisper's `promptTokens` biasing (the usual way to
/// teach an ASR your jargon) returns empty output on large-v3-turbo, so there
/// is no vocabulary story on that path at all. Parakeet gives us both.
actor ParakeetTranscriber: Transcriber {
    nonisolated let name = "parakeet"
    nonisolated let model: String

    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v3) {
        self.version = version
        self.model = switch version {
        case .v3: "parakeet-tdt-0.6b-v3-coreml"
        case .v2: "parakeet-tdt-0.6b-v2-coreml"
        @unknown default: "parakeet-unknown"
        }
    }

    /// True when the model is already in FluidAudio's cache, so `yaz doctor`
    /// can warn about a multi-hundred-megabyte download before the user is
    /// mid-sentence rather than after.
    nonisolated var isDownloaded: Bool {
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version),
            version: version
        )
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }
        guard let manager else { throw TranscriberError.notPrepared }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = result.tokenTimings ?? []
        let segments = words.isEmpty
            ? (text.isEmpty ? [] : [TranscriptSegment(start: 0, end: result.duration, text: text)])
            : Self.segments(from: words)

        return TranscriptionOutput(text: text, segments: segments, duration: result.duration)
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
            let t = word.token
            if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
