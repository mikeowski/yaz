import Foundation

/// Spoken Turkish commands: "yeni satır", "soru işareti", "geri al".
///
/// The same caution as everywhere else in yaz: a command taken for words is
/// a nuisance, words taken for a command lose what the user said. So an
/// inline command counts only where a command is said, at the end of a
/// sentence: "Toplantı bitti, yeni satır." starts a new line, but
/// "Yeni satır ekledim" (*I added a new line*) is a sentence. A control
/// command ("geri al") counts only when it is the whole dictation.
enum VoiceCommands {

    static let language = "tr"

    static func isSupported(language: String) -> Bool {
        language.lowercased().hasPrefix(Self.language)
    }

    /// A dictation that is a command for yaz, not text.
    enum Control: Sendable, Equatable {
        /// Delete the last dictation, if it is still right before the cursor.
        case undoLast
    }

    private static let controls: [String: Control] = [
        "geri al": .undoLast,
        "bunu sil": .undoLast,
        "son yazdığımı sil": .undoLast,
        "sonuncuyu sil": .undoLast,
        "son yazılanı sil": .undoLast,
    ]

    /// The control command a whole dictation is, if any.
    static func control(_ text: String) -> Control? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { PhoneticKey.lowercasedTurkish(String($0)).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        return controls[words.joined(separator: " ")]
    }

    // MARK: - Inline

    private enum Insert { case newline, paragraph, mark(Character) }

    private static let phrases: [(words: [String], insert: Insert, inCode: Bool)] = [
        (["yeni", "paragraf"], .paragraph, false),
        (["yeni", "satır"], .newline, false),
        (["alt", "satır"], .newline, false),
        (["soru", "işareti"], .mark("?"), true),
        (["ünlem", "işareti"], .mark("!"), true),
        (["iki", "nokta", "üst", "üste"], .mark(":"), true),
    ]

    struct Result: Sendable, Equatable {
        let text: String
        /// The commands carried out, as said.
        let commands: [String]
    }

    private struct Token {
        let leading: String
        let core: String
        let trailing: String
        var key: String { PhoneticKey.lowercasedTurkish(core) }
    }

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:…\"'()«»“”‘’")

    private static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).map { piece in
            let word = String(piece)
            let scalars = Array(word.unicodeScalars)
            var lo = 0
            var hi = scalars.count
            while lo < hi, edgePunctuation.contains(scalars[lo]) { lo += 1 }
            while hi > lo, edgePunctuation.contains(scalars[hi - 1]) { hi -= 1 }
            func string(_ range: Range<Int>) -> String {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: scalars[range])
                return String(s)
            }
            return Token(leading: string(0..<lo), core: string(lo..<hi), trailing: string(hi..<scalars.count))
        }
    }

    /// Carry out the inline commands in `text`. `code`: no line breaks, only
    /// the punctuation commands. Set for a terminal or an editor, where a
    /// line break can run a command, and when text is typed key by key,
    /// where it is a Return that sends the message.
    static func apply(_ text: String, code: Bool = false) -> Result {
        let tokens = tokenize(text)
        var out = ""
        var commands: [String] = []
        var capitalizeNext = false
        var glued = false   // the next word follows a line break, no space
        var i = 0

        while i < tokens.count {
            if let found = match(tokens, at: i, code: code) {
                let (phrase, insert) = found
                let said = tokens[i..<(i + phrase)].map(\.core).joined(separator: " ")
                commands.append(said)
                trimEnd(&out)
                switch insert {
                case .newline:
                    out += "\n"
                    glued = true
                case .paragraph:
                    out += "\n\n"
                    glued = true
                case let .mark(mark):
                    if out.last == "," || out.last == "." || out.last == ";" { out.removeLast() }
                    out.append(mark)
                    glued = false
                }
                capitalizeNext = true
                i += phrase
                continue
            }
            var word = tokens[i].leading + tokens[i].core + tokens[i].trailing
            if capitalizeNext { word = capitalized(word) }
            if !out.isEmpty && !glued { out += " " }
            out += word
            capitalizeNext = false
            glued = false
            i += 1
        }
        guard !commands.isEmpty else { return Result(text: text, commands: []) }
        return Result(text: out, commands: commands)
    }

    /// A command phrase at `i` that ends a sentence: its last word carries
    /// sentence punctuation or ends the dictation, and the words inside it
    /// carry none.
    private static func match(_ tokens: [Token], at i: Int, code: Bool) -> (Int, Insert)? {
        for phrase in phrases where !code || phrase.inCode {
            let n = phrase.words.count
            guard i + n <= tokens.count else { continue }
            let span = tokens[i..<(i + n)]
            guard zip(span, phrase.words).allSatisfy({ $0.key == $1 }) else { continue }
            guard span.dropLast().allSatisfy({ $0.trailing.isEmpty }),
                  span.dropFirst().allSatisfy({ $0.leading.isEmpty })
            else { continue }
            let last = tokens[i + n - 1]
            let endsSentence = i + n == tokens.count
                || last.trailing.contains(where: { ".!?…".contains($0) })
            guard endsSentence else { continue }
            return (n, phrase.insert)
        }
        return nil
    }

    private static func trimEnd(_ out: inout String) {
        while let last = out.last, last == " " || last == "," { out.removeLast() }
    }

    private static func capitalized(_ word: String) -> String {
        guard let index = word.firstIndex(where: \.isLetter) else { return word }
        let first = word[index]
        let upper: String = first == "i" ? "İ" : (first == "ı" ? "I" : String(first).uppercased())
        return String(word[..<index]) + upper + String(word[word.index(after: index)...])
    }
}

/// Deleting the last dictation from the field it went into.
enum UndoDictation {

    /// The UTF-16 range to delete: the pasted text, if it ends exactly at
    /// the caret. Anything else (the user moved, typed or edited) is nil.
    static func range(value: String, caret: Int, pasted: String) -> NSRange? {
        let pasted = pasted.trimmingCharacters(in: .whitespaces)
        let utf16 = value.utf16
        let length = pasted.utf16.count
        guard length > 0, caret >= length, caret <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: caret - length)
        let end = utf16.index(utf16.startIndex, offsetBy: caret)
        guard let before = String(utf16[start..<end]), before == pasted else { return nil }
        return NSRange(location: caret - length, length: length)
    }
}
