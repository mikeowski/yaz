import Foundation

/// Everything that makes yaz more than a transcriber, for one language.
///
/// The main language (`language` in the config) picks its pack, and the pack
/// decides what runs after Whisper: term repair (guarded by the pack's list
/// of everyday words), filler removal, numbers as digits, spoken commands,
/// and the language model's clean-up instructions. A language without a pack
/// gets transcription only, which is the safe default: each layer's guard is
/// a list of that language's own words, and without one it protects nothing.
///
/// A part a pack does not have is nil or empty, and that layer is skipped:
/// a new pack can start with term repair and grow. Turkish is the
/// reference pack; every other pack is measured the same way, against its own
/// everyday sentences in `EvalCorpus`.
struct LanguagePack: Sendable {

    /// ISO 639-1, matched as a prefix ("de" also covers "de-AT").
    let code: String
    /// In English, for messages and Settings.
    let name: String
    /// Everyday words: the veto for term repair and screen terms, the end of
    /// a casing command, and what is not a mishearing.
    let lexicon: Lexicon
    /// Sounds that are never words in this language ("ıı", "um"). Empty: no
    /// filler removal.
    var hesitations: Set<String> = []
    /// Lowercasing for word lists: Turkish needs its own (I → ı).
    var fold: @Sendable (String) -> String = { $0.lowercased() }
    /// Spoken numbers as digits, or nil.
    var numbers: (@Sendable (String) -> TurkishNumbers.Result)?
    /// Spoken commands, or nil.
    var commands: CommandSet?
    /// Instructions for Apple's on-device model, written in this language.
    /// Nil: `refine: llm` does nothing here.
    var refineInstructions: String?

    static let turkish = LanguagePack(
        code: "tr", name: "Turkish", lexicon: .turkish,
        hesitations: FillerFilter.turkishHesitations,
        fold: { PhoneticKey.lowercasedTurkish($0) },
        numbers: { TurkishNumbers.format($0) },
        commands: .turkish,
        refineInstructions: FoundationModelsBackend.instructions)

    /// Every main language with more than transcription.
    static let all: [LanguagePack] = [.turkish, .english, .german]

    static func forLanguage(_ language: String) -> LanguagePack? {
        let code = language.lowercased()
        return all.first { code.hasPrefix($0.code) }
    }

    /// What this pack adds over transcription, for `yaz doctor` and Settings.
    var features: [String] {
        var out = ["term repair"]
        if !hesitations.isEmpty { out.append("filler removal") }
        if numbers != nil { out.append("numbers") }
        if commands != nil { out.append("voice commands") }
        if refineInstructions != nil { out.append("language-model clean-up") }
        return out
    }

    /// "Turkish (tr), German (de)".
    static var supportedList: String {
        all.map { "\($0.name) (\($0.code))" }.joined(separator: ", ")
    }
}
