import Foundation

/// High-frequency German words: the same veto `TurkishLexicon` is for
/// Turkish, for a German speaker who mixes in English terms.
///
/// Measured on the German precision set (`EvalCorpus.German`) with no list at
/// all, six of thirty everyday sentences changed: `Morgen` → merge, `Reis` →
/// Redis, `Kurs` → Cursor, `Doktor` → Docker, `war viel` → Vercel. Each is an
/// ordinary word scoring like a mangled term, which is exactly what a skeleton
/// threshold cannot tell apart and a word list can.
///
/// The list is general frequency (function words, then everyday nouns, verbs
/// and adjectives), not the evaluation sentences: it has to cover what people
/// say between technical terms, not what one test file says.
enum GermanLexicon {

    /// Similarity a protected word must reach before it can be replaced.
    static let protectedWordThreshold: Double = 0.90

    static func isCommon(_ word: String) -> Bool {
        let folded = word.lowercased()
            .trimmingCharacters(in: .punctuationCharacters)
        guard !folded.isEmpty else { return false }
        if common.contains(folded) { return true }

        // Inflection: `Morgens`, `kommt`, `Kurses`, `Doktors` are the listed
        // stems with an ending. A few common endings cover most of it.
        for suffix in suffixes where folded.count > suffix.count + 2 {
            if folded.hasSuffix(suffix) {
                let stem = String(folded.dropLast(suffix.count))
                if common.contains(stem) { return true }
            }
        }
        return false
    }

    /// Frequent noun, adjective and verb endings.
    private static let suffixes = [
        "en", "er", "es", "em", "e", "n", "s", "st", "t", "te", "ten", "et",
        "ern", "ung", "ungen", "chen",
    ]

    private static let common: Set<String> = [
        // Pronouns, articles, conjunctions, prepositions, particles
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mich", "dich", "sich",
        "mir", "dir", "uns", "euch", "ihm", "ihn", "ihnen", "mein", "meine",
        "meinen", "meinem", "meiner", "dein", "deine", "deinen", "sein", "seine",
        "unser", "unsere", "euer", "der", "die", "das", "den", "dem", "des",
        "ein", "eine", "einen", "einem", "einer", "eines", "kein", "keine",
        "dieser", "diese", "dieses", "diesen", "jeder", "jede", "jedes", "alle",
        "und", "oder", "aber", "denn", "doch", "sondern", "weil", "dass", "wenn",
        "als", "ob", "obwohl", "damit", "bevor", "nachdem", "während", "bis",
        "in", "im", "an", "am", "auf", "aus", "bei", "beim", "mit", "nach",
        "von", "vom", "zu", "zum", "zur", "für", "über", "unter", "vor", "hinter",
        "neben", "zwischen", "durch", "gegen", "ohne", "um", "seit", "wegen",
        "nicht", "auch", "noch", "schon", "nur", "sehr", "so", "wie", "was",
        "wer", "wo", "wann", "warum", "wohin", "woher", "hier", "da", "dort",
        "jetzt", "dann", "gleich", "bald", "immer", "nie", "oft", "selten",
        "wieder", "mal", "gerade", "eben", "etwa", "fast", "ganz", "gar",
        "vielleicht", "wirklich", "endlich", "sofort", "später", "heute",
        "gestern", "morgen", "früh", "spät", "bitte", "danke", "ja", "nein",
        "genau", "also", "sonst", "trotzdem", "deshalb", "dafür", "dabei",
        "etwas", "nichts", "alles", "viel", "viele", "wenig", "mehr", "weniger",
        "jemand", "niemand", "man", "los", "fertig", "wohl", "eigentlich",

        // Auxiliaries, modals and very common verbs
        "bin", "bist", "ist", "sind", "seid", "war", "warst", "waren", "wart",
        "habe", "hast", "hat", "haben", "habt", "hatte", "hatten", "werde",
        "wirst", "wird", "werden", "wurde", "wurden", "geworden", "gewesen",
        "kann", "kannst", "können", "konnte", "muss", "musst", "müssen",
        "musste", "soll", "sollst", "sollen", "sollte", "will", "willst",
        "wollen", "wollte", "darf", "dürfen", "mag", "möchte", "möchten",
        "machen", "gemacht", "gehen", "gehe", "geht", "ging", "gegangen",
        "kommen", "komme", "kommt", "kam", "gekommen", "sagen", "gesagt",
        "geben", "gibt", "gab", "gegeben", "sehen", "sieht", "sah", "gesehen",
        "wissen", "weiß", "wusste", "denken", "dachte", "glauben", "finden",
        "fand", "gefunden", "nehmen", "nimmt", "nahm", "genommen", "bringen",
        "gebracht", "bleiben", "geblieben", "lassen", "fahren", "gefahren",
        "laufen", "gelaufen", "spielen", "gespielt", "arbeiten", "gearbeitet",
        "warten", "gewartet", "brauchen", "gebraucht", "kaufen", "gekauft",
        "bestellen", "bestellt", "schreiben", "geschrieben", "lesen", "gelesen",
        "essen", "gegessen", "trinken", "schlafen", "rufen", "angerufen",
        "fragen", "gefragt", "antworten", "helfen", "geholfen", "zeigen",
        "vergessen", "vergiss", "erinnern", "verstehen", "verstanden",
        "bestanden", "beantragt", "gewaschen", "geschnitten", "verschoben",
        "abgesagt", "regnet", "schneit", "freuen", "gefreut", "sitzen", "stehen",
        "liegen", "legen", "stellen", "setzen", "öffnen", "schließen", "suchen",
        "gesucht", "zahlen", "bezahlt", "lernen", "gelernt", "wohnen", "leben",
        "lieben", "mögen", "hoffen", "versuchen", "beginnen", "aufhören",

        // Everyday nouns
        "tag", "tage", "woche", "wochenende", "monat", "jahr", "stunde",
        "minute", "zeit", "uhr", "abend", "nacht", "mittag", "nachmittag",
        "vormittag", "frühstück", "mittagessen", "abendessen",
        "haus", "hause", "wohnung", "zimmer", "küche", "bad", "garten", "balkon",
        "tür", "fenster", "straße", "stadt", "land", "dorf", "weg", "platz",
        "arbeit", "büro", "schule", "uni", "kurs", "kurse", "prüfung", "buch",
        "bücher", "brief", "karte", "geld", "bank", "kredit", "miete",
        "rechnung", "preis", "laden", "markt", "supermarkt", "liste",
        "auto", "bus", "bahn", "zug", "fahrrad", "verkehr", "stau", "reise",
        "urlaub", "ferien", "wetter", "regen", "sonne", "schnee", "wind",
        "mann", "frau", "kind", "kinder", "mutter", "vater", "eltern",
        "bruder", "schwester", "sohn", "tochter", "oma", "opa", "großeltern",
        "freund", "freundin", "freunde", "nachbar", "nachbarn", "chef",
        "kollege", "kollegin", "arzt", "ärztin", "doktor", "tierarzt",
        "friseur", "lehrer", "lehrerin", "hund", "katze", "tier",
        "brot", "milch", "käse", "butter", "wasser", "kaffee", "tee", "bier",
        "wein", "suppe", "reis", "fleisch", "fisch", "obst", "gemüse", "kuchen",
        "hunger", "durst", "kopf", "hand", "haare", "auge", "augen", "herz",
        "handy", "telefon", "computer", "fernseher", "kabel", "ladekabel",
        "schuhe", "kleid", "hose", "jacke", "schirm", "regenschirm", "tasche",
        "spiel", "tor", "film", "musik", "lied", "rolle", "theater", "sport",
        "baum", "bäume", "blume", "blumen", "berg", "see", "meer", "fluss",
        "frage", "antwort", "problem", "idee", "grund", "sache", "dinge",
        "ende", "anfang", "hälfte", "rest", "teil", "seite", "fall",
        "morgens", "abends", "paket", "post", "lieferung", "termin",
        "besprechung", "treffen", "party", "geburtstag", "hochzeit",
        "strom", "licht", "heizung", "vorhang", "vorhänge", "bett", "tisch",
        "stuhl", "schrank", "tablette", "tabletten", "medikament", "strecke",
        "lauf", "runde", "quittung", "widerspruch", "antrag",

        // Days, months, seasons
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag",
        "sonntag", "januar", "februar", "märz", "april", "mai", "juni", "juli",
        "august", "september", "oktober", "november", "dezember", "frühling",
        "sommer", "herbst", "winter",

        // Home, office and town
        "drucker", "schlüssel", "kino", "hof", "keller", "dach", "treppe",
        "aufzug", "garage", "parkplatz", "bahnhof", "flughafen", "hotel",
        "restaurant", "kneipe", "apotheke", "krankenhaus", "kirche", "museum",
        "bibliothek", "papier", "stift", "bildschirm", "tastatur",
        "nudeln", "soße", "salat", "zucker", "salz", "pfeffer", "ei", "eier",
        "kartoffel", "kartoffeln", "apfel", "tomate", "tomaten", "zwiebel",
        "hausaufgaben", "verspätung", "sitzung", "projekt", "aufgabe", "plan",
        "nachricht", "nachrichten", "zeitung", "geschenk", "dokument", "akte",
        "kunde", "kunden", "firma", "vertrag", "gehalt", "steuer", "versicherung",
        "polizei", "feuerwehr", "rente", "rentner", "doktorarbeit",

        // Everyday adjectives and adverbs
        "gut", "besser", "schlecht", "schön", "groß", "klein", "neu", "alt",
        "jung", "lang", "kurz", "hoch", "tief", "schnell", "langsam", "laut",
        "leise", "leer", "voll", "warm", "kalt", "heiß", "teuer", "billig",
        "einfach", "schwer", "leicht", "richtig", "falsch", "wichtig",
        "müde", "krank", "gesund", "froh", "traurig", "nett", "lieb", "eng",
        "weit", "nah", "letzte", "letzten", "erste", "ersten", "nächste",
        "nächsten", "regelmäßig", "bisschen", "zusammen", "allein", "sicher",
    ]
}
