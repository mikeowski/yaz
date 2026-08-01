import Foundation

/// Post-processing applied to a finished transcript.
enum RefineMode: String, CaseIterable, Sendable {
    /// Nothing beyond what the engine produced.
    case off
    /// Deterministic hesitation removal only. No model, no measurable latency.
    case fillers
    /// Hesitation removal plus on-device language-model cleanup: contextual
    /// filler words, punctuation, sentence boundaries.
    case llm

    var displayName: String {
        switch self {
        case .off: "off"
        case .fillers: "hesitation sounds (deterministic)"
        case .llm: "language model (FoundationModels)"
        }
    }
}

struct RefineResult: Sendable, Equatable {
    let text: String
    let changed: Bool
    /// Why the model's output was discarded, when it was. Surfaced under
    /// `--verbose` so a refusal is visible rather than mysterious.
    let rejection: String?

    static func unchanged(_ text: String) -> RefineResult {
        RefineResult(text: text, changed: false, rejection: nil)
    }
}

/// Cleans up a transcript without changing what was said.
///
/// The measured value is real: fed a stumbling Turkish sentence, Apple's
/// on-device model produced a clean one.
///
/// ```
/// "ıı yarın şey saat ikide yani toplantımız var hani o proje için ee hazırlık yapmamız lazım"
/// → "Yarın saat ikide toplantımız var. O proje için hazırlık yapmamız lazım."
/// ```
///
/// So is the cost: 0.3–1.4 s on an M4 Pro depending on length, on top of the
/// 0.5–0.9 s the engine already spent. That is why `.fillers` — which does the
/// unambiguous part of the job in about a millisecond — is the default, and
/// `.llm` is opt-in.
///
/// The measured *limit* is equally real: given a vocabulary list, the same
/// model could not repair `Sılacık` into `Slack`. Fuzzy phonetic repair is not
/// its job — that belongs to `Vocabulary`, which is deterministic. This layer
/// only removes and punctuates.
///
/// Everything here fails soft. A refinement that errors, times out, or comes
/// back looking wrong returns the original text: dictation must never be lost
/// to a cleanup step.
actor Refiner {

    private let mode: RefineMode
    private let timeout: Duration
    private let backend: RefinerBackend?

    init(mode: RefineMode, timeout: Duration = .seconds(8), backend: RefinerBackend? = nil) {
        self.mode = mode
        self.timeout = timeout
        self.backend = backend ?? (mode == .llm ? FoundationModelsBackend() : nil)
    }

    /// Whether the configured mode can actually run right now.
    nonisolated static func availability(for mode: RefineMode) -> RefinerAvailability {
        switch mode {
        case .off, .fillers: .available
        case .llm: FoundationModelsBackend.availability()
        }
    }

    func refine(_ text: String) async -> RefineResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mode != .off else { return .unchanged(text) }

        let stripped = FillerFilter.strip(trimmed)
        guard mode == .llm, let backend else {
            return RefineResult(text: stripped, changed: stripped != text, rejection: nil)
        }

        let produced: String
        do {
            produced = try await withRefinementTimeout(timeout) {
                try await backend.rewrite(stripped)
            }
        } catch {
            return RefineResult(
                text: stripped, changed: stripped != text,
                rejection: "the model did not respond (\(error))")
        }

        let candidate = RefinementGuard.clean(produced)
        if let reason = RefinementGuard.reject(original: stripped, candidate: candidate) {
            return RefineResult(text: stripped, changed: stripped != text, rejection: reason)
        }
        return RefineResult(text: candidate, changed: candidate != text, rejection: nil)
    }
}

enum RefinerAvailability: Sendable, Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
}

/// The model call, behind a protocol so the guards can be tested without a
/// device that has Apple Intelligence switched on.
protocol RefinerBackend: Sendable {
    func rewrite(_ text: String) async throws -> String
}

/// Discards a model response that does not look like a cleanup of the input.
///
/// A language model asked to tidy text can also summarise it, translate it,
/// answer it, or refuse. Any of those reaching the user's cursor would be
/// worse than the stumbles it was asked to remove, so the output has to earn
/// its way in.
enum RefinementGuard {

    /// Cleanup may shorten (that is the point) but not by much, and must not
    /// grow — growth means the model added something.
    static let minLengthRatio = 0.55
    static let maxLengthRatio = 1.25
    /// Share of the original's content words that must survive.
    static let minRetention = 0.75

    /// Strip the wrapper a chat-tuned model likes to add.
    static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading "İşte düzeltilmiş metin:" style preamble.
        if let range = out.range(of: #"^[^\n:]{0,60}:\s*\n"#, options: .regularExpression) {
            out = String(out[range.upperBound...])
        }
        // Surrounding quotation marks.
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'")]
        for (open, close) in quotePairs
        where out.count >= 2 && out.first == open && out.last == close {
            out = String(out.dropFirst().dropLast())
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns a reason to discard, or nil to accept.
    static func reject(original: String, candidate: String) -> String? {
        if candidate.isEmpty { return "the model returned nothing" }

        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        if ratio < minLengthRatio {
            return String(format: "output shrank too far (%.2f×)", ratio)
        }
        if ratio > maxLengthRatio {
            return String(format: "output grew — the model added something (%.2f×)", ratio)
        }

        let retention = contentRetention(original: original, candidate: candidate)
        if retention < minRetention {
            return String(format: "%.0f%% of the content words disappeared", (1 - retention) * 100)
        }
        return nil
    }

    /// Share of the original's substantial words that still appear.
    ///
    /// Comparison is on normalised stems so Turkish suffix changes
    /// (`toplantımız` → `toplantı`) do not read as loss, and short words are
    /// ignored because they are the ones cleanup legitimately removes.
    static func contentRetention(original: String, candidate: String) -> Double {
        let originalWords = contentWords(original)
        guard !originalWords.isEmpty else { return 1 }

        let candidateKey = PhoneticKey.normalize(candidate)
        let survivors = originalWords.filter { candidateKey.contains($0) }
        return Double(survivors.count) / Double(originalWords.count)
    }

    /// Words the refiner is *asked* to remove, and which therefore must not
    /// count as lost content.
    ///
    /// Without this the guard punishes success: the model correctly dropped
    /// `yani` and `hani` from a stumbling sentence, the retention check read
    /// that as 30% content loss, and a good refinement was discarded.
    private static let removable: Set<String> = [
        "yani", "hani", "iste", "sei", "sey", "falan", "filan", "boile",
        "boyle", "soile", "soyle", "oile", "oyle", "canim", "valla", "iahu",
        "iahi", "abi", "ia", "ha", "he", "iaa",
    ]

    private static func contentWords(_ text: String) -> [String] {
        Tokenizer.tokenize(text)
            .map { PhoneticKey.normalize($0.stem) }
            // Four characters and up: long enough to be content, and long
            // enough that a chance substring match is unlikely.
            .filter { $0.count >= 4 }
            .filter { !removable.contains($0) }
            // Compare on the stem so a changed suffix is not counted as loss.
            .map { String($0.prefix(max(4, $0.count - 2))) }
    }
}

/// Run `work`, giving up after `timeout`.
func withRefinementTimeout<T: Sendable>(
    _ timeout: Duration,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw YazError.refinementTimedOut(seconds: Double(timeout.components.seconds))
        }
        guard let result = try await group.next() else {
            throw YazError.refinementTimedOut(seconds: Double(timeout.components.seconds))
        }
        group.cancelAll()
        return result
    }
}
