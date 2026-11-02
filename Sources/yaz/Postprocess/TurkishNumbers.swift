import Foundation

/// Spoken Turkish numbers written as digits: "saat on beş otuzda" →
/// "saat 15.30'da", "yüzde elli" → "%50", "iki bin yirmi altıda" → "2026'da".
///
/// Whisper writes numbers as words about as often as digits, and a message
/// with "on beş bin dolar" in it reads like a cheque. Global dictation apps
/// do not do Turkish numbers at all.
///
/// The hard part is not the arithmetic but the words that only look like
/// numbers: "onu" is *him*, "altında" is *under*, "yedi" is *ate*, "bin" is
/// *get on*, "yüz" is *face*, and "bir" is the article. So, as with term
/// repair, a wrong digit is worse than a word left alone:
///
/// - Two or more number words convert only if they form a well-formed Turkish
///   numeral ("altı yedi kişi", *six or seven people*, does not).
/// - A single word converts only with context: after "saat" or "yüzde",
///   before a unit or a currency, or when it is an unambiguous number of ten
///   or more ("otuz yaşında"). Single digits stay words in prose, and "bir"
///   never becomes "1" on its own.
/// - Only the last word may carry a suffix, which moves behind an apostrophe:
///   "on beşte" → "15'te". When the reading changes ("iki buçukta" is read
///   "iki virgül beş" once written "2,5"), the suffix follows the new reading.
///
/// Turkish style: a dot groups thousands from five digits (15.000; a year
/// stays 2026), a comma is the decimal mark, and the time is 15.30.
enum TurkishNumbers {

    static let language = "tr"

    static func isSupported(language: String) -> Bool {
        language.lowercased().hasPrefix(Self.language)
    }

    struct Change: Sendable, Equatable {
        let from: String
        let to: String
    }

    struct Result: Sendable, Equatable {
        let text: String
        let changes: [Change]
    }

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9,
    ]
    private static let tens: [String: Int] = [
        "on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60, "yetmiş": 70,
        "seksen": 80, "doksan": 90,
    ]
    private static let scales: [String: Int] = ["bin": 1_000, "milyon": 1_000_000, "milyar": 1_000_000_000]
    private static let hundred = "yüz"

    private static func value(of word: String) -> Int? {
        units[word] ?? tens[word] ?? scales[word] ?? (word == hundred ? 100 : nil)
    }

    /// Spellings a number word takes before a suffix: "dördü", "dördüncü".
    private static let stems: [(stem: String, word: String)] = {
        var list: [(stem: String, word: String)] =
            (Array(units.keys) + Array(tens.keys) + Array(scales.keys) + [hundred]).map { (stem: $0, word: $0) }
        list.append((stem: "dörd", word: "dört"))
        return list.sorted { $0.stem.count > $1.stem.count }
    }()

    /// Words that are something else too: a lone one never converts without
    /// context ("onu", "altında", "yedi", "bin", "yüzü", "bir").
    private static let ambiguous: Set<String> = ["bir", "on", "altı", "yedi", "yüz", "bin"]

    private static let caseSuffixes: Set<String> = [
        "de", "da", "te", "ta", "e", "a", "ye", "ya", "i", "ı", "u", "ü", "yi", "yı", "yu", "yü",
        "in", "ın", "un", "ün", "nin", "nın", "nun", "nün", "den", "dan", "ten", "tan",
        "nde", "nda", "ndan", "nden", "le", "la", "yle", "yla",
        "dir", "dır", "dur", "dür", "tir", "tır", "tur", "tür",
    ]
    private static let ordinalSuffixes: Set<String> = [
        "inci", "ıncı", "uncu", "üncü", "nci", "ncı", "ncu", "ncü",
    ]

    private static let currencies: Set<String> = [
        "lira", "tl", "dolar", "euro", "avro", "sterlin", "kuruş",
    ]
    private static let unitWords: Set<String> = currencies.union([
        "dakika", "saniye", "saat", "gün", "hafta", "ay", "yıl", "sene", "kişi", "metre",
        "kilometre", "santim", "kilo", "kilogram", "gram", "litre", "adet", "tane", "kez", "defa",
        "sefer", "yaşında", "yaş", "derece", "sayfa", "madde", "bölüm", "numara", "kat", "katı",
        "mb", "gb", "tb", "ms", "piksel",
    ])

    private static let vowels: Set<Character> = ["a", "e", "ı", "i", "o", "ö", "u", "ü"]

    // MARK: - Tokens

    private struct Token {
        let range: Range<String.Index>
        let leading: String
        let core: String
        let trailing: String
        var lower: String { PhoneticKey.lowercasedTurkish(core) }
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
            while hi > lo, trailingPunctuation.contains(word[word.index(before: hi)]) {
                hi = word.index(before: hi)
            }
            tokens.append(Token(
                range: start..<index,
                leading: String(word[word.startIndex..<lo]),
                core: String(word[lo..<hi]),
                trailing: String(word[hi..<word.endIndex])))
        }
        return tokens
    }

    /// A token read as a number word.
    private struct Reading {
        /// The dictionary word ("dört" for "dördü"), or nil for digits.
        let word: String?
        let value: Int
        let suffix: String
        let ordinal: Bool
    }

    private static func read(_ token: Token) -> Reading? {
        let w = token.lower
        guard !w.isEmpty else { return nil }
        if w.allSatisfy(\.isASCII), w.allSatisfy(\.isNumber), let digits = Int(w), w.count <= 9 {
            return Reading(word: nil, value: digits, suffix: "", ordinal: false)
        }
        for (stem, word) in stems where w.hasPrefix(stem) {
            let rest = String(w.dropFirst(stem.count))
            if stem == "dörd" && rest.isEmpty { continue }
            if stem == "dört", let first = rest.first, vowels.contains(first) { continue }
            guard let value = value(of: word) else { continue }
            if rest.isEmpty { return Reading(word: word, value: value, suffix: "", ordinal: false) }
            if ordinalSuffixes.contains(rest) {
                return Reading(word: word, value: value, suffix: "", ordinal: true)
            }
            if caseSuffixes.contains(rest) {
                return Reading(word: word, value: value, suffix: rest, ordinal: false)
            }
        }
        return nil
    }

    // MARK: - Grammar

    /// One numeral element: a dictionary word, or digits before a scale
    /// ("15 bin").
    private enum Element { case word(String), digits(Int) }

    /// The value of a well-formed numeral, or nil. Magnitudes must fall:
    /// "iki bin yüz elli" is 2150, "bir bin" and "altı yedi" are not numbers.
    private static func parse(_ elements: [Element]) -> Int? {
        let n = elements.count
        var i = 0
        var total = 0
        var lastScale = Int.max

        func word(_ k: Int) -> String? {
            guard k < n, case let .word(w) = elements[k] else { return nil }
            return w
        }

        func group(_ start: Int) -> (value: Int, next: Int) {
            var k = start
            var v = 0
            if let w = word(k), let u = units[w], u >= 2, word(k + 1) == hundred {
                v += u * 100
                k += 2
            } else if word(k) == hundred {
                v += 100
                k += 1
            }
            if let w = word(k), let t = tens[w] { v += t; k += 1 }
            if let w = word(k), let u = units[w] { v += u; k += 1 }
            return (v, k)
        }

        while i < n {
            var g: Int
            var next: Int
            var fromDigits = false
            if case let .digits(d) = elements[i] {
                guard let w = word(i + 1), scales[w] != nil, d < 1000 else { return nil }
                g = d
                next = i + 1
                fromDigits = true
            } else {
                (g, next) = group(i)
            }
            let consumed = next > i
            if let w = word(next), let scale = scales[w] {
                guard scale < lastScale else { return nil }
                if !consumed {
                    guard scale == 1_000 else { return nil }
                    g = 1                                   // "bin" alone is 1000
                } else if scale == 1_000 && g == 1 && !fromDigits {
                    return nil                              // "bir bin" is not said
                }
                total += g * scale
                lastScale = scale
                i = next + 1
                continue
            }
            guard consumed else { return nil }
            total += g
            i = next
            if i < n { return nil }
        }
        return total
    }

    // MARK: - Writing

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

    /// A suffix said after "buçuk", moved onto the word the digits are now
    /// read with: "otuz" for a time (2.30), "beş" for a decimal (2,5).
    private static func reharmonize(_ suffix: String, back: Bool) -> String {
        var s = suffix
        if s.first == "y" { s.removeFirst() }
        if back, s.first == "t" { s = "d" + s.dropFirst() }
        if !back, s.first == "d" { s = "t" + s.dropFirst() }
        return String(s.map { c -> Character in
            switch c {
            case "e", "a": return back ? "a" : "e"
            case "i", "ı", "u", "ü", "o", "ö": return back ? "u" : "i"
            default: return c
            }
        })
    }

    private static func time(_ elements: [Element], half: Bool) -> String? {
        for case .digits in elements { return nil }
        let whole = parse(elements)
        if half {
            guard let whole, (0...24).contains(whole) else { return nil }
            return "\(whole).30"
        }
        if let whole, (0...24).contains(whole), elements.count <= 2 { return String(whole) }
        if elements.count >= 2 {
            for cut in stride(from: elements.count - 1, to: 0, by: -1) {
                if let h = parse(Array(elements[..<cut])), let m = parse(Array(elements[cut...])),
                   (0...24).contains(h), (1...59).contains(m) {
                    return "\(h)." + (m < 10 ? "0\(m)" : "\(m)")
                }
            }
        }
        if let whole, (0...24).contains(whole) { return String(whole) }
        return nil
    }

    private static func isUnit(_ word: String) -> (unit: Bool, currency: Bool) {
        let root = word.split(separator: "'", maxSplits: 1).first.map(String.init) ?? word
        for unit in unitWords where root == unit
            || (root.hasPrefix(unit) && caseSuffixes.contains(String(root.dropFirst(unit.count)))) {
            return (true, currencies.contains(unit))
        }
        return (false, false)
    }

    // MARK: -

    static func format(_ text: String) -> Result {
        let tokens = tokenize(text)
        let readings = tokens.map(read)
        let n = tokens.count
        var replacements: [(range: Range<String.Index>, text: String, from: String)] = []

        var i = 0
        while i < n {
            guard let first = readings[i] else { i += 1; continue }
            // Digits matter only before a scale word: "15 bin".
            if first.word == nil {
                guard i + 1 < n, let next = readings[i + 1], let w = next.word, scales[w] != nil,
                      tokens[i].trailing.isEmpty
                else { i += 1; continue }
            }

            // The run: number words in a row. Only the last may carry a
            // suffix or punctuation; only the first may open with punctuation.
            var j = i
            while true {
                let r = readings[j]!
                let ends = !r.suffix.isEmpty || r.ordinal || !tokens[j].trailing.isEmpty
                if ends || j + 1 >= n || readings[j + 1] == nil || !tokens[j + 1].leading.isEmpty { break }
                j += 1
            }

            // "buçuk" (and "buçuğa") right after: a half.
            var half = false
            var end = j
            var suffix = readings[j]!.suffix
            if readings[j]!.suffix.isEmpty, !readings[j]!.ordinal, tokens[j].trailing.isEmpty, j + 1 < n,
               tokens[j + 1].leading.isEmpty {
                let b = tokens[j + 1].lower
                let rest = String(b.dropFirst(5))
                let restStartsWithVowel = rest.first.map { vowels.contains($0) } ?? false
                if (b.hasPrefix("buçuk") && (rest.isEmpty || (caseSuffixes.contains(rest) && !restStartsWithVowel)))
                    || (b.hasPrefix("buçuğ") && caseSuffixes.contains(rest) && restStartsWithVowel) {
                    half = true
                    end = j + 1
                    suffix = rest
                }
            }

            let elements: [Element] = (i...j).map { k in
                let r = readings[k]!
                return r.word.map(Element.word) ?? .digits(r.value)
            }
            let ordinal = readings[j]!.ordinal
            let previous = i > 0 && tokens[i - 1].trailing.isEmpty ? tokens[i - 1].lower : ""
            let following = end + 1 < n ? tokens[end + 1].lower : ""

            var written: String?
            var percent = false
            if previous == "saat", !ordinal, let clock = time(elements, half: half) {
                written = clock
                if half && !suffix.isEmpty { suffix = reharmonize(suffix, back: true) }
            }
            if written == nil, let value = parse(elements) {
                let count = elements.count + (half ? 1 : 0)
                let firstWord: String? = { if case let .word(w) = elements[0] { return w } else { return nil } }()
                let unit = isUnit(following)
                var ok = false
                if previous == "yüzde" {
                    ok = true
                    percent = true
                } else if count >= 2 {
                    ok = true
                } else if ordinal {
                    ok = value >= 10
                } else if unit.unit {
                    ok = firstWord != "bir" && (value >= 10 || unit.currency)
                } else if let firstWord, !ambiguous.contains(firstWord), value >= 10 {
                    ok = true
                }
                if ok && !(ordinal && half) {
                    var digits = grouped(value)
                    if half {
                        digits += ",5"
                        if !suffix.isEmpty { suffix = reharmonize(suffix, back: false) }
                    }
                    written = (percent ? "%" : "") + digits + (ordinal ? "." : "")
                }
            }

            guard var replacement = written else { i = j + 1; continue }
            if !suffix.isEmpty { replacement += "'" + suffix }
            let startToken = percent ? i - 1 : i
            let range = tokens[startToken].range.lowerBound..<tokens[end].range.upperBound
            let full = tokens[startToken].leading + replacement + tokens[end].trailing
            replacements.append((range, full, String(text[range])))
            i = end + 1
        }

        guard !replacements.isEmpty else { return Result(text: text, changes: []) }
        var result = text
        for r in replacements.reversed() { result.replaceSubrange(r.range, with: r.text) }
        return Result(
            text: result,
            changes: replacements.map { Change(from: $0.from, to: $0.text) })
    }
}
