import Foundation

/// Turns a word into forms that can be compared across the gap between how a
/// term is spelled and how Turkish ASR hears it.
///
/// The problem this solves is measured, not hypothetical. Dictating Turkish
/// with English technical terms, Whisper large-v3-turbo produced:
///
/// ```
/// "Slack"        → "Sılacık"
/// "pull request" → "Puhrıkı Esti"
/// "CI pipeline"  → "C.I.P. eline"
/// ```
///
/// Two forces are at work, and each gets its own defence:
///
/// 1. **Vowel epenthesis.** Turkish phonotactics dislike consonant clusters, so
///    speakers and the acoustic model break them with vowels: `sl` becomes
///    `sıl`. Vowels are therefore the least trustworthy part of the signal, and
///    the consonant skeleton is the most trustworthy.
/// 2. **Grapheme mismatch.** English spelling conventions (`ck`, `ph`, `qu`,
///    `x`) have no Turkish counterpart and are transcribed the way they sound.
enum PhoneticKey {

    /// Case-folded, diacritic-folded, English digraphs rewritten the way
    /// Turkish spells the same sound.
    ///
    /// Order matters: digraphs are rewritten before single letters, or `ph`
    /// would become `p`+`h` and never reach `f`.
    static func normalize(_ word: String) -> String {
        var text = lowercasedTurkish(word)

        // Drop everything that is not a letter or digit. Whisper writes
        // acronyms as "C.I.P." and the dots carry no sound.
        text = String(text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        })

        for (from, to) in digraphs {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = resolveHardAndSoftC(text)

        // Folded last, on purpose. Turkish `ç` is its own sound (/tʃ/); folding
        // it to `c` before the rule above would let it be rewritten as `k`, and
        // "saç" would start looking like "Slack".
        text = foldTurkishDiacritics(text)

        for (from, to) in singleLetters {
            text = text.replacingOccurrences(of: from, with: to)
        }

        return collapseRuns(text)
    }

    /// The consonant skeleton — normalisation with the vowels removed.
    ///
    /// This is the workhorse. `slack` and `sılacık` share almost nothing as
    /// spelled, but reduce to `slk` and `slck`: one edit apart. Throwing away
    /// vowels throws away exactly the information epenthesis corrupts.
    static func skeleton(_ word: String) -> String {
        let normalized = normalize(word)
        return String(normalized.filter { !vowels.contains($0) && $0 != " " })
    }

    // MARK: -

    /// Turkish case folding. `I` lowercases to `ı` and `İ` to `i` — using the
    /// default locale here would turn `İSTANBUL` into `i̇stanbul` and break the
    /// comparison before it starts.
    static func lowercasedTurkish(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "I": out.append("ı")
            case "İ": out.append("i")
            default: out.append(contentsOf: String(character).lowercased())
            }
        }
        return out
    }

    /// English `c` is /k/ before a back vowel or a consonant and /s/ before a
    /// front vowel. Turkish spells those `k` and `s`, so `Cursor` is heard and
    /// written `Körsır` — the same word, one letter apart, but `c` versus `k`
    /// makes them look unrelated to a skeleton comparison.
    ///
    /// Applied to both sides. Turkish `c` is really /dʒ/, so rewriting it is
    /// phonetically wrong for native words; what matters here is that the rule
    /// is deterministic and identical on term and transcript, and that it
    /// brings English loanwords into alignment.
    private static func resolveHardAndSoftC(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(characters.count)

        for (index, character) in characters.enumerated() {
            guard character == "c" else {
                out.append(character)
                continue
            }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch next {
            case "e", "i", "y": out.append("s")
            default: out.append("k")
            }
        }
        return out
    }

    private static func foldTurkishDiacritics(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            out.append(diacritics[character] ?? character)
        }
        return out
    }

    /// Squash repeated letters: `parrot` and `parot` must agree.
    private static func collapseRuns(_ text: String) -> String {
        var out = ""
        var previous: Character?
        for character in text where character != previous || character == " " {
            out.append(character)
            previous = character
        }
        return out
    }

    private static let diacritics: [Character: Character] = [
        "ç": "c", "ğ": "g", "ı": "i", "ö": "o", "ş": "s", "ü": "u",
        "â": "a", "î": "i", "û": "u",
        // German: Whisper writes an English `a` as `ä` ("Släck"), and `ß` is
        // one `s` sound (runs collapse anyway).
        "ä": "a", "ß": "s",
    ]

    /// English spellings rewritten to the Turkish letter carrying that sound.
    private static let digraphs: [(String, String)] = [
        ("ck", "k"),      // slack → slak
        ("ch", "c"),      // branch → branc
        ("sh", "s"),      // shell → sel
        ("ph", "f"),      // php → fp
        ("th", "t"),      // github → gitub
        ("qu", "k"),      // query → kery
        ("gh", "g"),      // github handled above; light → ligt
        ("kn", "n"),      // knight
        ("wr", "r"),      // write
        ("ee", "i"), ("oo", "u"), ("ea", "i"), ("ou", "u"),
    ]

    private static let singleLetters: [(String, String)] = [
        ("q", "k"),
        ("w", "v"),
        ("x", "ks"),
        ("j", "c"),       // Turkish `c` carries the English `j` sound
        ("y", "i"),
    ]

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
}

/// Levenshtein distance and the similarity ratio built on it.
enum EditDistance {

    /// Classic dynamic-programming edit distance over two rows.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let source = Array(a), target = Array(b)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            for j in 1...target.count {
                let substitution = previous[j - 1] + (source[i - 1] == target[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }

    /// 1.0 for identical strings, 0.0 for nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }
}
