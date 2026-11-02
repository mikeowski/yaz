import Foundation

/// The safety veto of term repair for one dictation language: ordinary words
/// that may not be overwritten on skeleton evidence (see `TurkishLexicon`).
///
/// Term repair runs only for a language that has one. Without it the guard
/// protects nothing: measured on English, `into main` became `Notion`; on
/// German with no list, `Doktor` became `Docker` and `Morgen` became `merge`.
struct Lexicon: Sendable {

    /// ISO 639-1 code, matched as a prefix (`de` also covers `de-AT`).
    let language: String
    let protectedWordThreshold: Double
    private let isCommonWord: @Sendable (String) -> Bool

    init(language: String, protectedWordThreshold: Double, isCommonWord: @escaping @Sendable (String) -> Bool) {
        self.language = language
        self.protectedWordThreshold = protectedWordThreshold
        self.isCommonWord = isCommonWord
    }

    func isCommon(_ word: String) -> Bool { isCommonWord(word) }

    /// True when any word in the window is common enough to protect.
    func containsCommonWord(_ stems: [String]) -> Bool {
        stems.contains { isCommonWord($0) }
    }

    static let turkish = Lexicon(
        language: "tr", protectedWordThreshold: TurkishLexicon.protectedWordThreshold,
        isCommonWord: { TurkishLexicon.isCommon($0) })

    static let german = Lexicon(
        language: "de", protectedWordThreshold: GermanLexicon.protectedWordThreshold,
        isCommonWord: { GermanLexicon.isCommon($0) })

    /// One per `LanguagePack`: adding a pack adds its lexicon.
    static var all: [Lexicon] { LanguagePack.all.map(\.lexicon) }

    static func forLanguage(_ language: String) -> Lexicon? {
        let code = language.lowercased()
        return all.first { code.hasPrefix($0.language) }
    }

    /// "tr, de", for messages.
    static var supportedList: String { all.map(\.language).joined(separator: ", ") }
}
