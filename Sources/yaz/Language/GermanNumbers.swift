import Foundation

/// Spoken German numbers as digits: "fünfzehntausend Euro" → "15.000 Euro",
/// "fünfzig Prozent" → "50 %", "um fünfzehn Uhr dreißig" → "um 15:30 Uhr".
///
/// German writes a number below a million as one word
/// ("zweitausendsechsundzwanzig"), so each word is taken apart: thousands,
/// hundreds, then "<unit>und<tens>". The words that only look like numbers
/// stay: "ein"/"eine" is the article, "Acht" in "Gib Acht" is attention,
/// "zweiten" is an ordinal, "hundertmal" is "a hundred times".
///
/// - A compound ("fünfundzwanzig", "dreihundertzwölf") of ten or more
///   converts; so does "zwei Millionen".
/// - A plain word converts only before "Prozent", before a unit when it is
///   ten or more ("dreißig Sekunden"), or as a time with "Uhr".
/// - A dot groups thousands from five digits, so a year stays "2026"; a
///   space goes before %, as German typesetting has it.
enum GermanNumbers {

    private static let units: [String: Int] = [
        "eins": 1, "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]
    private static let teens: [String: Int] = [
        "zehn": 10, "elf": 11, "zwölf": 12, "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15, "sechzehn": 16,
        "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
    ]
    private static let tens: [String: Int] = [
        "zwanzig": 20, "dreißig": 30, "vierzig": 40, "fünfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
    ]
    private static let big: [String: Int] = [
        "million": 1_000_000, "millionen": 1_000_000, "milliarde": 1_000_000_000, "milliarden": 1_000_000_000,
    ]
    private static let currencies: Set<String> = ["euro", "dollar", "franken", "cent", "pfund", "lira"]
    private static let unitWords: Set<String> = currencies.union([
        "prozent", "minuten", "minute", "sekunden", "stunden", "stunde", "tage", "tag", "wochen", "monate", "jahre",
        "jahren", "leute", "nutzer", "menschen", "mal", "dateien", "zeilen", "tests", "seiten", "kilometer", "meter",
        "kilo", "gramm", "gb", "mb", "ms", "anfragen", "commits", "punkte", "stück",
    ])

    private static func below100(_ w: String) -> Int? {
        if let v = teens[w] ?? tens[w] { return v }
        if w != "ein", let v = units[w] { return v }
        if let r = w.range(of: "und") {
            let a = String(w[..<r.lowerBound]), b = String(w[r.upperBound...])
            if let u = units[a], let t = tens[b] { return u + t }
        }
        return nil
    }

    private static func below1000(_ w: String) -> Int? {
        guard let r = w.range(of: "hundert") else { return below100(w) }
        let a = String(w[..<r.lowerBound]), b = String(w[r.upperBound...])
        let h: Int
        if a.isEmpty || a == "ein" { h = 1 } else if a != "eins", let u = units[a] { h = u } else { return nil }
        if b.isEmpty { return h * 100 }
        if b == "eins" { return h * 100 + 1 }
        guard let rest = below100(b) else { return nil }
        return h * 100 + rest
    }

    /// The value of one number word, or nil.
    static func value(of word: String) -> Int? {
        let w = word.lowercased()
        guard !w.isEmpty, w.allSatisfy(\.isLetter) else { return nil }
        guard let r = w.range(of: "tausend") else { return below1000(w) }
        let a = String(w[..<r.lowerBound]), b = String(w[r.upperBound...])
        let t: Int
        if a.isEmpty || a == "ein" { t = 1 } else if let v = below1000(a) { t = v } else { return nil }
        if b.isEmpty { return t * 1000 }
        guard let rest = below1000(b) else { return nil }
        return t * 1000 + rest
    }

    private static func isCompound(_ word: String) -> Bool {
        let w = word.lowercased()
        return w.contains("hundert") || w.contains("tausend") || (w.contains("und") && below100(w) != nil)
    }

    private struct Token {
        let range: Range<String.Index>
        let leading: String
        let core: String
        let trailing: String
        var lower: String { core.lowercased() }
    }

    private static let leadingPunctuation: Set<Character> = ["\"", "\u{201C}", "\u{201E}", "(", "[", "{", "«", "'", "\u{2018}"]
    private static let trailingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "\"", "\u{201D}", ")", "]", "}", "»", "…",
    ]

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            let word = text[start..<index]
            var lo = word.startIndex
            while lo < word.endIndex, leadingPunctuation.contains(word[lo]) { lo = word.index(after: lo) }
            var hi = word.endIndex
            while hi > lo, trailingPunctuation.contains(word[word.index(before: hi)]) { hi = word.index(before: hi) }
            tokens.append(Token(
                range: start..<index, leading: String(word[word.startIndex..<lo]),
                core: String(word[lo..<hi]), trailing: String(word[hi..<word.endIndex])))
        }
        return tokens
    }

    private static func grouped(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        var digits = Array(String(value))
        var out: [Character] = []
        while digits.count > 3 {
            out = ["."] + Array(digits.suffix(3)) + out
            digits.removeLast(3)
        }
        return String(digits + out)
    }

    static func format(_ text: String) -> TurkishNumbers.Result {
        let tokens = tokenize(text)
        let n = tokens.count
        var replacements: [(range: Range<String.Index>, text: String, from: String)] = []
        var i = 0
        while i < n {
            guard var v = value(of: tokens[i].core) else { i += 1; continue }
            var end = i
            var scaled = false
            if tokens[i].trailing.isEmpty, i + 1 < n, let scale = big[tokens[i + 1].lower] {
                v *= scale
                end = i + 1
                scaled = true
            }
            let following = end + 1 < n ? tokens[end + 1].lower : ""
            let previous = i > 0 && tokens[i - 1].trailing.isEmpty ? tokens[i - 1].lower : ""
            var written: String?
            var last = end

            if following == "prozent" {
                written = grouped(v) + " %"
                last = end + 1
            } else if following == "uhr", v <= 24, tokens[end].trailing.isEmpty {
                // "fünfzehn Uhr dreißig" → 15:30 Uhr
                if end + 2 < n, tokens[end + 1].trailing.isEmpty, let m = value(of: tokens[end + 2].core), (1...59).contains(m) {
                    written = "\(v):" + (m < 10 ? "0\(m)" : "\(m)") + " Uhr"
                    last = end + 2
                } else if v >= 10 || previous == "um" {
                    written = "\(v) Uhr"
                    last = end + 1
                }
            } else if scaled {
                written = grouped(v)
            } else if isCompound(tokens[i].core) && v >= 10 {
                written = grouped(v)
            } else if unitWords.contains(following) && v >= 10 {
                written = grouped(v)
            }

            guard let digits = written else { i += 1; continue }
            let range = tokens[i].range.lowerBound..<tokens[last].range.upperBound
            replacements.append((range, tokens[i].leading + digits + tokens[last].trailing, String(text[range])))
            i = last + 1
        }
        guard !replacements.isEmpty else { return TurkishNumbers.Result(text: text, changes: []) }
        var result = text
        for r in replacements.reversed() { result.replaceSubrange(r.range, with: r.text) }
        return TurkishNumbers.Result(
            text: result, changes: replacements.map { TurkishNumbers.Change(from: $0.from, to: $0.text) })
    }
}
