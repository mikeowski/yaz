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
/// through `--engine parakeet` for English-only dictation.
actor WhisperTranscriber: Transcriber {
    nonisolated let name = "whisper"
    nonisolated let model: String

    private let whisperKitID: String
    private let language: String

    /// `WhisperKit` is not `Sendable`, so an actor cannot pass a `self`-isolated
    /// reference into WhisperKit's own nonisolated methods. Holding it in an
    /// explicitly-unchecked box severs that isolation link; serialisation is
    /// still real, because every path to the box runs on this actor.
    private let box = PipelineBox()

    private final class PipelineBox: @unchecked Sendable {
        var kit: WhisperKit?
    }

    init(model: WhisperModel = .largeV3Turbo, language: String = "tr") {
        self.model = model.id
        self.whisperKitID = model.whisperKitID
        self.language = language
    }

    func prepare() async throws {
        guard box.kit == nil else { return }
        box.kit = try await WhisperKit(WhisperKitConfig(
            model: whisperKitID, verbose: false, prewarm: true, load: true
        ))
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        guard !samples.isEmpty else { throw TranscriberError.emptyAudio }
        guard let pipeline = box.kit else { throw TranscriberError.notPrepared }

        // Whisper's own decoder handles segmentation; we only pin the language
        // so it never wastes a pass auto-detecting, and pin temperature so
        // repeated runs over the same audio are comparable.
        let options = DecodingOptions(language: language, temperature: 0)
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)

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

        return TranscriptionOutput(
            text: text,
            segments: segments,
            duration: Double(samples.count) / 16_000
        )
    }

    func release() async {
        box.kit = nil
    }

    /// Strip Whisper's non-speech bracket tokens. Fed silence, the model emits
    /// `[BLANK_AUDIO]`, `(müzik)`, `<|nospeech|>` and friends as literal text —
    /// which is fine in a transcript file and unacceptable when the output is
    /// typed straight into whatever field the user is looking at.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,     // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,       // (silence), (müzik çalıyor)
            #"<\|[^|]*\|>"#,     // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,       // *arka plan gürültüsü*
        ]
        var out = text
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
