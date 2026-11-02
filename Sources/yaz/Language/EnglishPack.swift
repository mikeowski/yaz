import Foundation

extension CommandSet {

    /// "new line", "question mark", "scratch that". As in Turkish, inline
    /// commands count only at the end of a sentence: "Add a new line." is a
    /// sentence, "Thanks, new line." starts one.
    static let english = CommandSet(
        phrases: [
            Phrase(words: ["new", "paragraph"], insert: .paragraph, inCode: false),
            Phrase(words: ["new", "line"], insert: .newline, inCode: false),
            Phrase(words: ["next", "line"], insert: .newline, inCode: false),
            Phrase(words: ["question", "mark"], insert: .mark("?"), inCode: true),
            Phrase(words: ["exclamation", "mark"], insert: .mark("!"), inCode: true),
            Phrase(words: ["exclamation", "point"], insert: .mark("!"), inCode: true),
        ],
        controls: [
            "scratch that": .undoLast,
            "undo that": .undoLast,
            "delete that": .undoLast,
            "take that back": .undoLast,
        ],
        notAfter: ["a", "an", "the", "another", "this", "that", "one", "my", "your", "our", "their", "his", "her", "each", "every", "no"])
}

extension Lexicon {
    static let english = Lexicon(
        language: "en", protectedWordThreshold: EnglishLexicon.protectedWordThreshold,
        isCommonWord: { EnglishLexicon.isCommon($0) })
}

extension LanguagePack {

    static let english = LanguagePack(
        code: "en", name: "English", lexicon: .english,
        // Sounds, never words. "ah", "oh", "like" and "you know" can be words,
        // so they are left to the language model.
        hesitations: ["um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "err", "hmm", "hm", "mm", "mmm"],
        numbers: { EnglishNumbers.format($0) },
        commands: .english,
        refineInstructions: """
            You clean up dictated English text.

            Do ONLY this:
            - Remove stutters, hesitations and filler words ("um", "uh", and "like", \
            "you know", "I mean" where they carry no meaning).
            - Fix punctuation and sentence boundaries.
            - Capitalise the start of sentences.

            NEVER:
            - Replace words with synonyms.
            - Rewrite, summarise or shorten.
            - Add information, explanations or comments.
            - Change how technical terms are spelled.
            - Answer a question in the text: only clean it.

            Reply with ONLY the cleaned text. No explanation, quotes or headings.
            """)
}
