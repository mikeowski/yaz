import Foundation

/// Spoken Spanish numbers as digits: "quince mil euros" → "15.000 euros",
/// "cincuenta por ciento" → "50 %", "dos mil veintiséis" → "2026".
///
/// "un"/"una" is the article unless "un millón"; "mil veces" is an idiom
/// unless it is money; a single word converts only before a unit when it is
/// ten or more. A dot groups thousands from five digits; a space goes
/// before %, as the RAE recommends.
enum SpanishNumbers {

    private static let units: [String: Int] = [
        "uno": 1, "un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
    ]
    private static let teens: [String: Int] = [
        "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15, "dieciséis": 16, "diecisiete": 17,
        "dieciocho": 18, "diecinueve": 19, "veinte": 20, "veintiuno": 21, "veintiún": 21, "veintiuna": 21,
        "veintidós": 22, "veintitrés": 23, "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26, "veintisiete": 27,
        "veintiocho": 28, "veintinueve": 29,
    ]
    private static let tens: [String: Int] = [
        "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
    ]
    private static let hundreds: [String: Int] = [
        "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200, "trescientos": 300, "trescientas": 300,
        "cuatrocientos": 400, "cuatrocientas": 400, "quinientos": 500, "quinientas": 500, "seiscientos": 600,
        "seiscientas": 600, "setecientos": 700, "setecientas": 700, "ochocientos": 800, "ochocientas": 800,
        "novecientos": 900, "novecientas": 900,
    ]
    private static let scales: [String: Int] = ["mil": 1_000, "millón": 1_000_000, "millones": 1_000_000]
    private static let currencies: Set<String> = ["euros", "euro", "dólares", "dólar", "pesos", "peso", "céntimos", "libras"]
    private static let unitWords: Set<String> = currencies.union([
        "minutos", "segundos", "horas", "días", "semanas", "meses", "años", "personas", "usuarios", "veces", "archivos",
        "líneas", "pruebas", "páginas", "kilómetros", "metros", "kilos", "gramos", "gb", "mb", "ms", "peticiones",
        "commits", "puntos",
    ])

    private static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || hundreds[w] != nil || scales[w] != nil
    }

    private static func group(_ ws: [String], _ start: Int) -> (value: Int, next: Int, ok: Bool)? {
        let n = ws.count
        var i = start
        var v = 0
        if i < n, let h = hundreds[ws[i]] {
            v += h
            i += 1
            // "cien" stands alone; "ciento" goes before more.
            if ws[i - 1] == "cien", i < n, scales[ws[i]] == nil { return nil }
        }
        if i < n, let t = teens[ws[i]] {
            v += t
            i += 1
        } else if i < n, let t = tens[ws[i]] {
            v += t
            i += 1
            if i + 1 < n, ws[i] == "y", let u = units[ws[i + 1]] { v += u; i += 2 }
        } else if i < n, let u = units[ws[i]] {
            v += u
            i += 1
        }
        return (v, i, i > start)
    }

    private static func parse(_ ws: [String]) -> Int? {
        let n = ws.count
        var i = 0
        var total = 0
        var lastScale = Int.max
        while i < n {
            var g: Int
            var next: Int
            if ws[i] == "mil" {
                g = 1
                next = i
            } else {
                guard let r = group(ws, i), r.ok else { return nil }
                g = r.value
                next = r.next
            }
            if next < n, let scale = scales[ws[next]] {
                guard scale < lastScale else { return nil }
                if scale == 1_000 && g == 1 && next > i { return nil }     // "un mil" is not said
                if ws[next] == "millón" && g != 1 { return nil }
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

    private static let leadingPunctuation: Set<Character> = ["\"", "\u{201C}", "«", "(", "[", "{", "'", "\u{2018}", "¿", "¡"]
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
            let w = tokens[i].lower
            guard isNumberWord(w) else { i += 1; continue }
            // "un"/"una" is the article unless "un millón".
            if w == "un" || w == "una", !(i + 1 < n && ["millón", "millones"].contains(tokens[i + 1].lower)) {
                i += 1
                continue
            }
            var j = i
            var ws = [w]
            while tokens[j].trailing.isEmpty, j + 1 < n, tokens[j + 1].leading.isEmpty {
                let next = tokens[j + 1].lower
                if isNumberWord(next) { ws.append(next); j += 1; continue }
                if next == "y", tokens[j + 1].trailing.isEmpty, j + 2 < n, units[tokens[j + 2].lower] != nil,
                   let lastWord = ws.last, tens[lastWord] != nil {
                    ws += ["y", tokens[j + 2].lower]
                    j += 2
                    continue
                }
                break
            }
            let following = j + 1 < n ? tokens[j + 1].lower : ""
            let afterThat = j + 2 < n ? tokens[j + 2].lower : ""
            var ok = false
            var percent = false
            if let value = parse(ws) {
                let words = ws.filter { $0 != "y" }.count
                if following == "por", afterThat == "ciento" {
                    ok = true
                    percent = true
                } else if words >= 2 && value >= 10 {
                    ok = true
                } else if unitWords.contains(following) && value >= 10 {
                    ok = true
                }
                // "mil veces": an idiom, unless it is money.
                if ok, ws == ["mil"], !currencies.contains(following) { ok = false }
                if ok {
                    let end = percent ? j + 2 : j
                    let range = tokens[i].range.lowerBound..<tokens[end].range.upperBound
                    replacements.append((
                        range, tokens[i].leading + grouped(value) + (percent ? " %" : "") + tokens[end].trailing,
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
