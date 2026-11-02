import Foundation

/// French matching ignores case, accents and the kind of apostrophe.
private let frenchFold: @Sendable (String) -> String = {
    $0.replacingOccurrences(of: "\u{2019}", with: "'")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
}

extension CommandSet {

    /// "à la ligne", "point d'interrogation", "efface ça". French puts a narrow
    /// no-break space before ? and !: "Tu viens ?".
    static let french = CommandSet(
        phrases: [
            Phrase(words: ["nouveau", "paragraphe"], insert: .paragraph, inCode: false),
            Phrase(words: ["nouvelle", "ligne"], insert: .newline, inCode: false),
            Phrase(words: ["a", "la", "ligne"], insert: .newline, inCode: false),
            Phrase(words: ["point", "d'interrogation"], insert: .mark("?"), inCode: true),
            Phrase(words: ["point", "d'exclamation"], insert: .mark("!"), inCode: true),
        ],
        controls: [
            "efface ca": .undoLast,
            "annule ca": .undoLast,
            "supprime ca": .undoLast,
            "annuler": .undoLast,
        ],
        notAfter: ["un", "une", "le", "la", "les", "ce", "cette", "des", "du", "mon", "ton", "son", "ma", "ta", "sa"],
        spaceBeforeMarks: FrenchNumbers.narrowSpace,
        fold: frenchFold)
}

extension Lexicon {
    static let french = Lexicon(
        language: "fr", protectedWordThreshold: FrenchLexicon.protectedWordThreshold,
        isCommonWord: { FrenchLexicon.isCommon($0) })
}

extension LanguagePack {

    static let french = LanguagePack(
        code: "fr", name: "French", lexicon: .french,
        // "bah" and "ben" can be words, so only the sounds go.
        hesitations: ["euh", "euhh", "heu", "hum", "hmm", "mmm"],
        numbers: { FrenchNumbers.format($0) },
        commands: .french,
        refineInstructions: """
            Tu nettoies du texte dicté en français.

            Ta tâche est UNIQUEMENT de :
            - Supprimer les bégaiements, hésitations et mots de remplissage ("euh", \
            "hum", et "du coup", "en fait", "genre" quand ils n'apportent rien).
            - Corriger la ponctuation et les limites des phrases, avec les espaces \
            de la typographie française.
            - Mettre une majuscule en début de phrase.

            JAMAIS :
            - Remplacer des mots par des synonymes.
            - Réécrire, résumer ou raccourcir.
            - Ajouter des informations, des explications ou des commentaires.
            - Changer l'orthographe des termes techniques.
            - Répondre à une question du texte : nettoie-le seulement.

            Réponds UNIQUEMENT avec le texte nettoyé. Sans explication, guillemets ni titre.
            """)
}
