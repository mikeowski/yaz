import Foundation

/// Spoken French numbers as digits: "quinze mille euros" → "15 000 euros",
/// "soixante-dix-huit" → "78", "quatre-vingt-dix" → "90", "vingt et un" →
/// "21", "cinquante pour cent" → "50 %".
///
/// French counts in twenties above sixty, so the grammar is spelled out:
/// "soixante" takes 10–19 after it, "quatre-vingt(s)" is 80 and takes 1–19.
/// "un"/"une" is the article unless "un million"; "mille fois" is an idiom
/// unless it is money; a single word converts only before a unit when it is
/// ten or more. Thousands are grouped from five digits with a narrow
/// no-break space, which also goes before %, as French typography has it.
enum FrenchNumbers {

    static let narrowSpace = "\u{202F}"

    private static let units: [String: Int] = [
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9,
    ]
    private static let teens: [String: Int] = [
        "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16,
    ]
    private static let tens: [String: Int] = [
        "vingt": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
    ]
    private static let scales: [String: Int] = [
        "mille": 1_000, "million": 1_000_000, "millions": 1_000_000, "milliard": 1_000_000_000, "milliards": 1_000_000_000,
    ]
    private static let numberWords: Set<String> = Set(units.keys).union(teens.keys).union(tens.keys)
        .union(scales.keys).union(["cent", "cents", "vingts", "et"])
    private static let currencies: Set<String> = ["euros", "euro", "dollars", "dollar", "francs", "centimes", "livres"]
    private static let unitWords: Set<String> = currencies.union([
        "minutes", "secondes", "heures", "jours", "semaines", "mois", "ans", "années", "personnes", "utilisateurs",
        "fois", "fichiers", "lignes", "tests", "pages", "kilomètres", "mètres", "kilos", "grammes", "go", "mo", "ms",
        "requêtes", "commits", "points",
    ])

    /// "quatre-vingt-dix" → [quatre, vingt, dix]; nil unless all are number words.
    private static func pieces(_ core: String) -> [String]? {
        let parts = core.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(separator: "-").map(String.init)
        guard !parts.isEmpty, parts != ["et"], parts.allSatisfy(numberWords.contains) else { return nil }
        return parts
    }

    private static func below100(_ ws: [String], _ start: Int) -> (value: Int, next: Int, ok: Bool) {
        let n = ws.count
        var i = start
        func word(_ k: Int) -> String? { k < n ? ws[k] : nil }
        let lateTeens: Set<String> = ["sept", "huit", "neuf"]

        if word(i) == "quatre", let v = word(i + 1), v == "vingt" || v == "vingts" {
            var value = 80
            i += 2
            if v == "vingt" {
                if word(i) == "dix", let u = word(i + 1), lateTeens.contains(u) {
                    value += 10 + units[u]!
                    i += 2
                } else if let w = word(i), let t = teens[w] {
                    value += t
                    i += 1
                } else if let w = word(i), w != "une", let u = units[w] {
                    value += u
                    i += 1
                }
            }
            return (value, i, true)
        }
        if let w = word(i), let t = tens[w] {
            let value = t
            i += 1
            if t == 60 {
                if word(i) == "dix", let u = word(i + 1), lateTeens.contains(u) { return (70 + units[u]!, i + 2, true) }
                if word(i) == "et", word(i + 1) == "onze" { return (71, i + 2, true) }
                if let w2 = word(i), let teen = teens[w2] { return (60 + teen, i + 1, true) }
            }
            if word(i) == "et", let u = word(i + 1), u == "un" || u == "une" { return (value + 1, i + 2, true) }
            if let w2 = word(i), w2 != "un", w2 != "une", let u = units[w2] { return (value + u, i + 1, true) }
            return (value, i, true)
        }
        if word(i) == "dix", let u = word(i + 1), lateTeens.contains(u) { return (10 + units[u]!, i + 2, true) }
        if let w = word(i), let t = teens[w] { return (t, i + 1, true) }
        if let w = word(i), let u = units[w] { return (u, i + 1, true) }
        return (0, i, false)
    }

    private static func group(_ ws: [String], _ start: Int) -> (value: Int, next: Int, ok: Bool) {
        let n = ws.count
        var i = start
        var value = 0
        if i + 1 < n, ws[i] != "un", ws[i] != "une", let u = units[ws[i]], ws[i + 1] == "cent" || ws[i + 1] == "cents" {
            value = u * 100
            i += 2
        } else if i < n, ws[i] == "cent" {
            value = 100
            i += 1
        }
        let rest = below100(ws, i)
        if rest.ok {
            value += rest.value
            i = rest.next
        }
        return (value, i, i > start)
    }

    private static func parse(_ ws: [String]) -> Int? {
        let n = ws.count
        var i = 0
        var total = 0
        var lastScale = Int.max
        while i < n {
            var g = 1
            var next = i
            if ws[i] != "mille" {
                let r = group(ws, i)
                guard r.ok else { return nil }
                g = r.value
                next = r.next
            }
            if next < n, let scale = scales[ws[next]] {
                guard scale < lastScale else { return nil }
                if scale == 1_000 && g == 1 && next > i { return nil }      // "un mille" is not said
                total += g * scale
                lastScale = scale
                i = next + 1
                continue
            }
            total += g
            i = next
            if i < n { return nil }
        }
        return total
    }

    private struct Token {
        let range: Range<String.Index>
        let leading: String
        let core: String
        let trailing: String
        var lower: String { core.lowercased() }
    }

    private static let leadingPunctuation: Set<Character> = ["\"", "\u{201C}", "«", "(", "[", "{", "'", "\u{2018}"]
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
        var out = ""
        while digits.count > 3 {
            out = narrowSpace + String(digits.suffix(3)) + out
            digits.removeLast(3)
        }
        return String(digits) + out
    }

    static func format(_ text: String) -> TurkishNumbers.Result {
        let tokens = tokenize(text)
        let n = tokens.count
        var replacements: [(range: Range<String.Index>, text: String, from: String)] = []
        var i = 0
        while i < n {
            guard let first = pieces(tokens[i].core) else { i += 1; continue }
            // "un"/"une" is the article unless "un million".
            if first == ["un"] || first == ["une"],
               !(i + 1 < n && ["million", "millions", "milliard", "milliards"].contains(tokens[i + 1].lower)) {
                i += 1
                continue
            }
            var j = i
            var ws = first
            while tokens[j].trailing.isEmpty, j + 1 < n, tokens[j + 1].leading.isEmpty {
                if let more = pieces(tokens[j + 1].core) {
                    ws += more
                    j += 1
                    continue
                }
                // "vingt et un", "soixante et onze"
                if tokens[j + 1].lower == "et", tokens[j + 1].trailing.isEmpty, j + 2 < n,
                   ["un", "une", "onze"].contains(tokens[j + 2].lower) {
                    ws += ["et", tokens[j + 2].lower]
                    j += 2
                    continue
                }
                break
            }
            while ws.last == "et" { ws.removeLast(); j -= 1 }

            let following = j + 1 < n ? tokens[j + 1].lower : ""
            let afterThat = j + 2 < n ? tokens[j + 2].lower : ""
            if let value = parse(ws) {
                var ok = false
                var percent = false
                if following == "pour", afterThat == "cent" {
                    ok = true
                    percent = true
                } else if ws.filter({ $0 != "et" }).count >= 2 && value >= 10 {
                    ok = true
                } else if unitWords.contains(following) && value >= 10 {
                    ok = true
                }
                // "mille fois": an idiom, unless it is money.
                if ok, ws == ["mille"], !currencies.contains(following) { ok = false }
                if ok {
                    let end = percent ? j + 2 : j
                    let range = tokens[i].range.lowerBound..<tokens[end].range.upperBound
                    replacements.append((
                        range,
                        tokens[i].leading + grouped(value) + (percent ? narrowSpace + "%" : "") + tokens[end].trailing,
                        String(text[range])))
                    i = end + 1
                    continue
                }
            }
            i = j + 1
        }
        guard !replacements.isEmpty else { return TurkishNumbers.Result(text: text, changes: []) }
        var result = text
        for r in replacements.reversed() { result.replaceSubrange(r.range, with: r.text) }
        return TurkishNumbers.Result(
            text: result, changes: replacements.map { TurkishNumbers.Change(from: $0.from, to: $0.text) })
    }
}
