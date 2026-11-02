import Foundation

extension CommandSet {

    /// "neue Zeile", "Fragezeichen", "lösch das". "Fragezeichen" is one word,
    /// so the article rule matters most here: "Da steht ein Fragezeichen."
    /// is a sentence, "Kommst du Fragezeichen" a question.
    static let german = CommandSet(
        phrases: [
            Phrase(words: ["neuer", "absatz"], insert: .paragraph, inCode: false),
            Phrase(words: ["neue", "zeile"], insert: .newline, inCode: false),
            Phrase(words: ["fragezeichen"], insert: .mark("?"), inCode: true),
            Phrase(words: ["ausrufezeichen"], insert: .mark("!"), inCode: true),
        ],
        controls: [
            "lösch das": .undoLast,
            "das löschen": .undoLast,
            "rückgängig": .undoLast,
            "streich das": .undoLast,
        ],
        notAfter: ["ein", "eine", "einen", "einem", "einer", "der", "die", "das", "den", "dem", "kein", "keine", "dieses", "diese", "jedes"])
}

extension LanguagePack {

    static let german = LanguagePack(
        code: "de", name: "German", lexicon: .german,
        // "mhm" means yes, so it stays.
        hesitations: ["äh", "ähm", "äähm", "öh", "öhm", "ehm", "hm", "hmm"],
        numbers: { GermanNumbers.format($0) },
        commands: .german,
        refineInstructions: """
            Du bereinigst diktierten deutschen Text.

            Deine Aufgabe ist NUR:
            - Stottern, Zögerlaute und Füllwörter entfernen ("äh", "ähm", und \
            "halt", "sozusagen", "quasi", wo sie nichts bedeuten).
            - Zeichensetzung und Satzgrenzen korrigieren.
            - Satzanfänge großschreiben.

            NIEMALS:
            - Wörter durch Synonyme ersetzen.
            - Umschreiben, zusammenfassen oder kürzen.
            - Informationen, Erklärungen oder Kommentare hinzufügen.
            - Die Schreibweise von Fachbegriffen ändern.
            - Eine Frage im Text beantworten: nur bereinigen.

            Antworte NUR mit dem bereinigten Text. Keine Erklärung, keine Anführungszeichen, keine Überschriften.
            """)
}
