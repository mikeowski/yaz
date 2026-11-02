import Foundation

/// Spoken English numbers as digits, for the words Whisper leaves spelled
/// out: "fifteen thousand dollars" → "15,000 dollars", "fifty percent" →
/// "50%", "three hundred and twelve tests" → "312 tests".
///
/// Whisper writes most English numbers as digits already, so this only
/// finishes the job, and conservatively, the way `TurkishNumbers` does:
///
/// - A run of number words converts only as a well-formed numeral of ten or
///   more ("twenty-five", "a hundred and twenty").
/// - A single word converts only before "percent", or before a unit when it
///   is ten or more ("thirty seconds"). "one" is a pronoun, "five minutes"
///   reads fine, "at nine" is a time: they stay words.
/// - "a hundred times", "a thousand thanks" are idioms and stay words, except
///   before money ("a thousand euros").
/// - Commas group thousands from five digits, so "1000" and a year stay
///   as they are.
enum EnglishNumbers {

    private static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let currencies: Set<String> = [
        "dollar", "dollars", "euro", "euros", "pound", "pounds", "cent", "cents", "lira", "yen",
    ]
    private static let unitWords: Set<String> = currencies.union([
        "percent", "minute", "minutes", "second", "seconds", "hour", "hours", "day", "days", "week", "weeks",
        "month", "months", "year", "years", "people", "users", "times", "items", "files", "lines", "tests",
        "pages", "kilometers", "miles", "meters", "kilos", "kg", "gb", "mb", "ms", "px", "requests", "commits",
        "points",
    ])

    private static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil || w == "hundred"
    }

    private struct Token {
        let range: Range<String.Index>
        let leading: String
        let core: String
        let trailing: String
        var lower: String { core.lowercased() }
    }

    private static let leadingPunctuation: Set<Character> = ["\"", "\u{201C}", "(", "[", "{", "«", "'", "\u{2018}"]
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

    /// "twenty-five" → [twenty, five]; nil if any piece is not a number word.
    private static func pieces(_ core: String) -> [String]? {
        let parts = core.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(isNumberWord) else { return nil }
        return parts
    }

    /// The value of a well-formed numeral, or nil.
    private static func parse(_ ws: [String]) -> Int? {
        let n = ws.count
        var i = 0
        var total = 0
        var lastScale = Int.max

        func group(_ start: Int) -> (value: Int, next: Int, ok: Bool) {
            var k = start
            var v = 0
            if k < n, let u = units[ws[k]], k + 1 < n, ws[k + 1] == "hundred" {
                v += u * 100
                k += 2
            } else if k < n, ws[k] == "hundred" {
                return (0, k, false)            // a bare "hundred" is said "a hundred"
            }
            if v > 0, k < n, ws[k] == "and" { k += 1 }
            if k < n, let t = teens[ws[k]] {
                v += t
                k += 1
            } else {
                if k < n, let t = tens[ws[k]] { v += t; k += 1 }
                if k < n, let u = units[ws[k]] { v += u; k += 1 }
            }
            return (v, k, k > start)
        }

        while i < n {
            let (g, next, ok) = group(i)
            guard ok else { return nil }
            if next < n, let scale = scales[ws[next]] {
                guard scale < lastScale else { return nil }
                total += g * scale
                lastScale = scale
                i = next + 1
                if i < n, ws[i] == "and" { i += 1 }
                continue
            }
            total += g
            i = next
            if i < n { return nil }
        }
        return total
    }

    private static func grouped(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        var digits = Array(String(value))
        var out: [Character] = []
        while digits.count > 3 {
            out = [","] + Array(digits.suffix(3)) + out
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
            var article = false
            var first = pieces(tokens[i].core)
            // "a hundred": the article is the one.
            if first == nil, tokens[i].lower == "a", tokens[i].trailing.isEmpty, i + 1 < n,
               ["hundred", "thousand", "million", "billion"].contains(tokens[i + 1].lower) {
                first = ["one"]
                article = true
            }
            guard var words = first else { i += 1; continue }

            // The run: number words, "and" between them; punctuation ends it.
            var j = i
            while tokens[j].trailing.isEmpty, j + 1 < n, tokens[j + 1].leading.isEmpty {
                if let more = pieces(tokens[j + 1].core) {
                    words += more
                    j += 1
                    continue
                }
                if tokens[j + 1].lower == "and", tokens[j + 1].trailing.isEmpty, j + 2 < n,
                   pieces(tokens[j + 2].core) != nil {
                    words.append("and")
                    j += 1
                    continue
                }
                break
            }
            if words.last == "and" { words.removeLast(); j -= 1 }

            let following = j + 1 < n ? tokens[j + 1].lower : ""
            var ok = false
            var percent = false
            if let value = parse(words) {
                if following == "percent" {
                    ok = true
                    percent = true
                } else if words.count >= 2 && value >= 10 {
                    ok = true
                } else if unitWords.contains(following) && value >= 10 {
                    ok = true
                }
                // "a hundred times": an idiom, unless it is money.
                if ok, article, words.count == 2, !currencies.contains(following) { ok = false }
                if ok {
                    let end = percent ? j + 1 : j
                    let range = tokens[i].range.lowerBound..<tokens[end].range.upperBound
                    let written = tokens[i].leading + grouped(value) + (percent ? "%" : "") + tokens[end].trailing
                    replacements.append((range, written, String(text[range])))
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
