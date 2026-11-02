import Foundation

/// Spanish matching ignores accents: Whisper may or may not write them.
private let spanishFold: @Sendable (String) -> String = {
    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
}

extension CommandSet {

    /// "nueva línea", "signo de interrogación", "borra eso". A Spanish
    /// question or exclamation also opens: "¿Vienes hoy?".
    static let spanish = CommandSet(
        phrases: [
            Phrase(words: ["nuevo", "parrafo"], insert: .paragraph, inCode: false),
            Phrase(words: ["punto", "y", "aparte"], insert: .paragraph, inCode: false),
            Phrase(words: ["nueva", "linea"], insert: .newline, inCode: false),
            Phrase(words: ["signo", "de", "interrogacion"], insert: .mark("?"), inCode: true),
            Phrase(words: ["signo", "de", "exclamacion"], insert: .mark("!"), inCode: true),
        ],
        controls: [
            "borra eso": .undoLast,
            "bórralo": .undoLast,
            "borralo": .undoLast,
            "deshacer": .undoLast,
            "elimina eso": .undoLast,
        ],
        notAfter: ["un", "una", "el", "la", "los", "las", "este", "esta", "ese", "esa", "otro", "otra", "mi", "tu", "su"],
        openings: ["?": "¿", "!": "¡"],
        fold: spanishFold)
}

extension Lexicon {
    static let spanish = Lexicon(
        language: "es", protectedWordThreshold: SpanishLexicon.protectedWordThreshold,
        isCommonWord: { SpanishLexicon.isCommon($0) })
}

extension LanguagePack {

    static let spanish = LanguagePack(
        code: "es", name: "Spanish", lexicon: .spanish,
        // "eh" can be "hey", so only the longer sounds go.
        hesitations: ["ehm", "ehh", "eeh", "eee", "em", "emm", "mmm", "hmm"],
        numbers: { SpanishNumbers.format($0) },
        commands: .spanish,
        refineInstructions: """
            Limpias texto dictado en español.

            Tu tarea es SOLO:
            - Quitar tartamudeos, titubeos y muletillas ("eh", "em", y "o sea", \
            "bueno", "pues" cuando no aportan nada).
            - Corregir la puntuación y los límites de las frases, con los signos \
            de apertura ¿ y ¡.
            - Poner mayúscula al inicio de cada frase.

            NUNCA:
            - Cambiar palabras por sinónimos.
            - Reescribir, resumir o acortar.
            - Añadir información, explicaciones o comentarios.
            - Cambiar cómo se escriben los términos técnicos.
            - Responder a una pregunta del texto: solo límpialo.

            Responde SOLO con el texto limpio. Sin explicaciones, comillas ni títulos.
            """)
}
