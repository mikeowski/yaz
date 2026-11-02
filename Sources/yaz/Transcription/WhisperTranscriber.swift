import Foundation
import WhisperKit

/// Whisper via WhisperKit's Core ML port, running on the Apple Neural Engine.
///
/// This is yaz's default engine for one blunt reason: **Whisper is the only
/// on-device family in this stack that speaks Turkish.** Parakeet TDT v3 —
/// the obvious "faster, smaller, multilingual" alternative — covers 25
/// European languages plus Russian and Ukrainian, and Turkish is not among
/// them (verified against both NVIDIA's model card and FluidAudio's own
/// `Language` enum, which has no `tr` case).
///
/// Cost of that constraint: 1.6 GB of weights and ~500-900 ms per utterance,
/// versus Parakeet's ~600 MB and a much lower RTF. Parakeet stays available
/// through `--engine-name parakeet` for English-only dictation.
actor WhisperTranscriber: Transcriber {
    nonisolated let name = "whisper"
    nonisolated let model: String

    /// Whisper is multilingual and yaz pins the language explicitly, so there
    /// is no useful subset to advertise — an empty list means "any".
    nonisolated let supportedLanguages: [String] = []

    private let whisperKitID: String
    private let language: String

    /// `WhisperKit` is not `Sendable`, so an actor cannot pass a `self`-isolated
    /// reference into WhisperKit's own nonisolated methods. The box severs that
    /// isolation link.
    ///
    /// The lock is not ceremony: the pointer is written on the actor by
    /// `prepare()`/`release()` and read from a task-group child task inside the
    /// timeout wrapper, which is a genuine cross-thread access. `current()`
    /// returns a strong reference, so a concurrent `release()` cannot drop the
    /// pipeline out from under an in-flight transcription.
    private let box = PipelineBox()

    private final class PipelineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var kit: WhisperKit?

        func current() -> WhisperKit? { lock.withLock { kit } }
        func set(_ newValue: WhisperKit?) { lock.withLock { kit = newValue } }
        var isLoaded: Bool { lock.withLock { kit != nil } }
    }

    /// Collapses concurrent `prepare()` calls so the 1.6 GB model is loaded
    /// once, and serialises inference because WhisperKit makes no reentrancy
    /// guarantee.
    private let loader = SingleFlight()
    private let inference = SerialGate()

    init(model: WhisperModel = .largeV3Turbo, language: String = "tr") {
        self.model = model.id
        self.whisperKitID = model.whisperKitID
        self.language = language
    }

    /// True only when every component is on disk at a plausible size. A
    /// half-finished download must not read as ready — see `ModelStore`.
    nonisolated var isDownloaded: Bool {
        ModelStore.status(for: whisperKitID).isComplete
    }

    /// Full on-disk report, for `yaz doctor`.
    nonisolated var storeStatus: ModelStore.Status {
        ModelStore.status(for: whisperKitID)
    }

    func prepare() async throws {
        if box.isLoaded { return }
        let box = self.box
        let whisperKitID = self.whisperKitID
        let modelID = self.model
        try await loader.run {
            // Re-check inside the single-flight barrier: a queued caller may
            // arrive after the winning load already finished.
            if box.isLoaded { return }
            do {
                box.set(try await WhisperKit(WhisperKitConfig(
                    model: whisperKitID, verbose: false, prewarm: true, load: true
                )))
            } catch {
                throw YazError.modelLoadFailed(model: modelID, underlying: "\(error)")
            }
        }
    }

    func transcribe(
        _ samples: [Float], options: TranscribeOptions
    ) async throws -> TranscriptionOutput {
        // Cheap rejections first: a hotkey tap or a muted mic must not cost a
        // model round trip.
        let level = try options.gate.check(samples)
        // Then the voice check: loud is not the same as speech, and Whisper
        // invents text for noise as readily as for silence.
        try await options.voice?.check(samples)
        guard box.isLoaded else { throw YazError.engineNotPrepared(engine: name) }

        // Whisper's own decoder handles segmentation; we only pin the language
        // so it never wastes a pass auto-detecting, and pin temperature so
        // repeated runs over the same audio are comparable.
        let decodeOptions = DecodingOptions(language: options.language ?? language, temperature: 0)
        let engineName = name

        let results: [TranscriptionResult]
        do {
            // Capture the box (@unchecked Sendable), not the WhisperKit
            // instance, which is not Sendable and cannot cross into the group.
            let box = self.box
            results = try await inference.run {
                try await withTranscriptionTimeout(options.timeout, engine: engineName) {
                    guard let kit = box.current() else {
                        throw YazError.engineNotPrepared(engine: engineName)
                    }
                    return try await kit.transcribe(
                        audioArray: samples, decodeOptions: decodeOptions)
                }
            }
        } catch let error as YazError {
            throw error
        } catch {
            throw YazError.transcriptionFailed(engine: engineName, underlying: "\(error)")
        }

        let text = Self.sanitize(
            results.map { (r: TranscriptionResult) in r.text }.joined(separator: " ")
        )
        let segments = results.flatMap { (r: TranscriptionResult) in
            r.segments.map {
                TranscriptSegment(
                    start: TimeInterval($0.start),
                    end: TimeInterval($0.end),
                    text: Self.sanitize($0.text)
                )
            }
        }.filter { !$0.text.isEmpty }

        let signals = Self.signals(from: results)
        return TranscriptionOutput(
            text: text,
            segments: segments,
            duration: level.seconds,
            level: level,
            quality: .assess(text: text, signals: signals, thresholds: options.thresholds)
        )
    }

    func release() async {
        // Wait for any queued inference to finish before dropping the weights,
        // so release() cannot strand a transcription mid-flight.
        _ = try? await inference.run { }
        box.set(nil)
        await loader.reset()
    }

    // MARK: -

    /// Average the decoder's per-segment confidence signals, weighted by
    /// segment length so a stray one-word segment cannot drag the verdict.
    /// Returns `nil` when the decoder produced no segments — the caller must
    /// not read that as perfect confidence.
    static func signals(from results: [TranscriptionResult]) -> TranscriptionQuality.Signals? {
        let segments = results.flatMap { (r: TranscriptionResult) in r.segments }
        guard !segments.isEmpty else { return nil }

        var weightTotal: Float = 0
        var noSpeech: Float = 0
        var logProb: Float = 0
        var compression: Float = 0

        for segment in segments {
            let weight = max(segment.end - segment.start, 0.01)
            weightTotal += weight
            noSpeech += segment.noSpeechProb * weight
            logProb += segment.avgLogprob * weight
            compression = max(compression, segment.compressionRatio)
        }
        guard weightTotal > 0 else { return nil }

        return .init(
            noSpeechProb: noSpeech / weightTotal,
            avgLogProb: logProb / weightTotal,
            // Repetition is a per-segment failure: one looping segment is
            // enough to condemn the utterance, so take the worst rather than
            // diluting it in an average.
            compressionRatio: compression
        )
    }

    /// Strip Whisper's non-speech bracket tokens. Fed silence, the model emits
    /// `[BLANK_AUDIO]`, `(müzik)`, `<|nospeech|>` and friends as literal text —
    /// which is fine in a transcript file and unacceptable when the output is
    /// typed straight into whatever field the user is looking at.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"<\|[^|]*\|>"#,                       // <|nospeech|>, <|endoftext|>
            #"\[[^\]]{0,40}\]"#,                    // [BLANK_AUDIO], [MUSIC]
            #"\*[^*]{0,40}\*"#,                     // *arka plan gürültüsü*
        ]
        var out = text
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Parentheses get their own pass with a non-speech word list. Blanket
        // stripping of "(...)" also deletes legitimate speech — people dictate
        // asides in brackets — so only annotation-looking spans go.
        out = stripNonSpeechParentheticals(out)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's parenthetical annotations are short and drawn from a small
    /// vocabulary in whichever language it decoded. Anything longer, or made
    /// of ordinary words, is far more likely to be real dictated speech.
    static func stripNonSpeechParentheticals(_ text: String) -> String {
        let markers: Set<String> = [
            "silence", "music", "applause", "laughter", "inaudible", "noise",
            "sessizlik", "müzik", "alkış", "gülüşmeler", "anlaşılmıyor", "gürültü",
            "background noise", "music playing", "müzik çalıyor", "arka plan gürültüsü",
        ]
        guard let regex = try? NSRegularExpression(pattern: #"\(([^)]{0,40})\)"#) else { return text }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard
                let full = Range(match.range, in: result),
                let inner = Range(match.range(at: 1), in: result)
            else { continue }
            let body = result[inner]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if markers.contains(body) {
                result.replaceSubrange(full, with: " ")
            }
        }
        return result
    }
}

/// The Whisper checkpoints yaz offers.
///
/// English-only variants are deliberately absent: yaz's reason to exist is
/// Turkish dictation, and shipping a default that silently cannot handle it
/// is the exact trap parrot falls into.
enum WhisperModel: String, CaseIterable, Sendable {
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    var id: String { rawValue }

    var whisperKitID: String {
        switch self {
        case .largeV3Turbo: "openai_whisper-large-v3-v20240930_turbo"
        case .largeV3: "openai_whisper-large-v3"
        }
    }

    var sizeMB: Int {
        switch self {
        case .largeV3Turbo: 1620
        case .largeV3: 3100
        }
    }
}
