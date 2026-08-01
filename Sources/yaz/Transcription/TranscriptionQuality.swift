import Foundation

/// Post-inference verdict on whether a transcript is trustworthy enough to
/// paste at the user's cursor.
///
/// Whisper never says "I don't know" — it always returns text. On silence,
/// music, or a half-caught word it invents something fluent and wrong. The
/// decoder does hand back three signals per segment, and this type turns them
/// into a decision rather than leaving them on the floor:
///
/// - `noSpeechProb` — the decoder's own "this isn't speech" estimate.
/// - `avgLogProb` — mean token confidence; collapses on invented text.
/// - `compressionRatio` — high when the text repeats itself, which is exactly
///   what a hallucination loop looks like ("teşekkürler teşekkürler …").
struct TranscriptionQuality: Sendable, Equatable {

    enum Verdict: Sendable, Equatable {
        /// Confident enough to use as-is.
        case good
        /// Usable, but the caller may want to warn or skip auto-insertion.
        case lowConfidence(reason: String)
        /// Almost certainly not real speech — discard.
        case rejected(reason: String)

        var isUsable: Bool {
            if case .rejected = self { return false }
            return true
        }
    }

    /// Thresholds. Defaults follow OpenAI's reference decoder, which treats
    /// `compressionRatio > 2.4` and `avgLogProb < -1.0` as failed decodes, and
    /// `noSpeechProb > 0.6` as non-speech.
    struct Thresholds: Sendable, Equatable {
        var maxNoSpeechProb: Float = 0.6
        var minAvgLogProb: Float = -1.0
        var maxCompressionRatio: Float = 2.4
        /// Below this, treat as "the model was guessing" without discarding.
        var lowConfidenceLogProb: Float = -0.7
        /// A single token repeated this many times in a row is a decode loop
        /// even when the compression ratio has not caught up yet.
        var maxTokenRepeats: Int = 4

        static let `default` = Thresholds()

        /// Never discard anything — for `yaz transcribe`, where seeing the raw
        /// output is the point.
        static let permissive = Thresholds(
            maxNoSpeechProb: 1.1,
            minAvgLogProb: -.greatestFiniteMagnitude,
            maxCompressionRatio: .greatestFiniteMagnitude,
            lowConfidenceLogProb: -.greatestFiniteMagnitude,
            maxTokenRepeats: .max
        )
    }

    /// Per-segment decoder signals, averaged over the utterance.
    ///
    /// Every field defaults to a value that reads as *maximum* confidence
    /// (`avgLogProb: 0` is log(1.0); `noSpeechProb: 0` is "definitely speech").
    /// That is why callers pass `nil` rather than `Signals()` when an engine
    /// exposes no confidence data — an absence of evidence must not be
    /// mistaken for evidence of quality. Parakeet is exactly this case.
    struct Signals: Sendable, Equatable {
        var noSpeechProb: Float = 0
        var avgLogProb: Float = 0
        var compressionRatio: Float = 0
    }

    let verdict: Verdict
    /// `nil` when the engine reports no per-segment confidence.
    let signals: Signals?

    /// True when the verdict rests only on the text, because the engine gave
    /// us nothing else to go on.
    var isTextOnlyJudgement: Bool { signals == nil }

    /// Judge a finished transcript.
    ///
    /// With `signals == nil` only the text-shaped checks apply (empty output,
    /// repetition loops). Those are the failure modes that survive into the
    /// user's cursor regardless of engine, so the gate still earns its keep.
    static func assess(
        text: String,
        signals: Signals?,
        thresholds: Thresholds = .default
    ) -> TranscriptionQuality {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return .init(verdict: .rejected(reason: "boş çıktı"), signals: signals)
        }
        if let signals {
            if signals.noSpeechProb > thresholds.maxNoSpeechProb {
                return .init(
                    verdict: .rejected(
                        reason: String(format: "konuşma değil (noSpeech %.2f)", signals.noSpeechProb)),
                    signals: signals)
            }
            if signals.compressionRatio > thresholds.maxCompressionRatio {
                return .init(
                    verdict: .rejected(
                        reason: String(
                            format: "tekrar döngüsü (sıkıştırma %.2f)", signals.compressionRatio)),
                    signals: signals)
            }
        }

        // Text-shaped checks run for every engine, with or without signals.
        if repeatsExcessively(trimmed, limit: thresholds.maxTokenRepeats) {
            return .init(verdict: .rejected(reason: "aynı kelime üst üste tekrarlandı"), signals: signals)
        }

        if let signals {
            if signals.avgLogProb < thresholds.minAvgLogProb {
                return .init(
                    verdict: .rejected(
                        reason: String(format: "güven çok düşük (logProb %.2f)", signals.avgLogProb)),
                    signals: signals)
            }
            if signals.avgLogProb < thresholds.lowConfidenceLogProb {
                return .init(
                    verdict: .lowConfidence(
                        reason: String(format: "düşük güven (logProb %.2f)", signals.avgLogProb)),
                    signals: signals)
            }
        }
        return .init(verdict: .good, signals: signals)
    }

    /// Detect the "kelime kelime kelime kelime" decode loop directly, so a
    /// short utterance catches it before the compression ratio would.
    static func repeatsExcessively(_ text: String, limit: Int) -> Bool {
        guard limit < .max else { return false }
        let words = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count > limit else { return false }

        var run = 1
        for i in 1..<words.count {
            run = words[i] == words[i - 1] ? run + 1 : 1
            if run > limit { return true }
        }
        return false
    }
}
