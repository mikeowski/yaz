import Foundation

/// Spoken commands in the main language: "yeni satır", "soru işareti",
/// "geri al" in Turkish; each `LanguagePack` brings its own `CommandSet`.
///
/// The same caution as everywhere else in yaz: a command taken for words is
/// a nuisance, words taken for a command lose what the user said. So an
/// inline command counts only where a command is said, at the end of a
/// sentence: "Toplantı bitti, yeni satır." starts a new line, but
/// "Yeni satır ekledim" (*I added a new line*) is a sentence. A control
/// command ("geri al") counts only when it is the whole dictation.
enum VoiceCommands {

    static let language = "tr"

    /// True when the language's pack has commands.
    static func isSupported(language: String) -> Bool {
        LanguagePack.forLanguage(language)?.commands != nil
    }

    /// A dictation that is a command for yaz, not text.
    enum Control: Sendable, Equatable {
        /// Delete the last dictation, if it is still right before the cursor.
        case undoLast
    }

    /// The control command a whole dictation is, if any.
    static func control(_ text: String, set: CommandSet = .turkish) -> Control? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .map { set.fold(String($0)).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        return set.controls[words.joined(separator: " ")]
    }

    // MARK: - Inline

    enum Insert: Sendable { case newline, paragraph, mark(Character) }

    struct Result: Sendable, Equatable {
        let text: String
        /// The commands carried out, as said.
        let commands: [String]
    }

    private struct Token {
        let leading: String
        let core: String
        let trailing: String
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
    static func apply(_ text: String, set: CommandSet = .turkish, code: Bool = false) -> Result {
        let tokens = tokenize(text)
        var out = ""
        var commands: [String] = []
        var capitalizeNext = false
        var glued = false   // the next word follows a line break, no space
        var i = 0

        while i < tokens.count {
            if let found = match(tokens, at: i, set: set, code: code) {
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
                    if let opening = set.openings[mark] { open(&out, with: opening) }
                    out += set.spaceBeforeMarks
                    out.append(mark)
                    glued = false
                }
                capitalizeNext = true
                i += phrase
                continue
            }
            var word = tokens[i].leading + tokens[i].core + tokens[i].trailing
            if capitalizeNext { word = capitalized(word, turkish: set.turkishCase) }
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
    private static func match(_ tokens: [Token], at i: Int, set: CommandSet, code: Bool) -> (Int, Insert)? {
        for phrase in set.phrases where !code || phrase.inCode {
            let n = phrase.words.count
            guard i + n <= tokens.count else { continue }
            let span = tokens[i..<(i + n)]
            guard zip(span, phrase.words).allSatisfy({ set.fold($0.core) == $1 }) else { continue }
            guard span.dropLast().allSatisfy({ $0.trailing.isEmpty }),
                  span.dropFirst().allSatisfy({ $0.leading.isEmpty })
            else { continue }
            if i > 0, tokens[i - 1].trailing.isEmpty, set.notAfter.contains(set.fold(tokens[i - 1].core)) {
                continue
            }
            let last = tokens[i + n - 1]
            let endsSentence = i + n == tokens.count
                || last.trailing.contains(where: { ".!?…".contains($0) })
            guard endsSentence else { continue }
            return (n, phrase.insert)
        }
        return nil
    }

    /// Spanish opens a question or an exclamation: put "¿" at the start of
    /// the sentence being closed, and capitalise it.
    private static func open(_ out: inout String, with opening: Character) {
        let enders: Set<Character> = [".", "!", "?", "\n", "¿", "¡"]
        var start = out.startIndex
        if let last = out.lastIndex(where: { enders.contains($0) }) {
            start = out.index(after: last)
            if out[last] == opening { return }
        }
        while start < out.endIndex, out[start] == " " { start = out.index(after: start) }
        guard start < out.endIndex else { return }
        let first = out[start]
        out.replaceSubrange(start...start, with: String(opening) + String(first).uppercased())
    }

    private static func trimEnd(_ out: inout String) {
        while let last = out.last, last == " " || last == "," { out.removeLast() }
    }

    private static func capitalized(_ word: String, turkish: Bool) -> String {
        guard let index = word.firstIndex(where: \.isLetter) else { return word }
        let first = word[index]
        let upper: String = turkish && first == "i" ? "İ"
            : (turkish && first == "ı" ? "I" : String(first).uppercased())
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

/// One language's spoken commands.
struct CommandSet: Sendable {

    struct Phrase: Sendable {
        /// Lowercase, as `fold` leaves a word.
        let words: [String]
        let insert: VoiceCommands.Insert
        /// Also in code apps: punctuation yes, line breaks never.
        let inCode: Bool
    }

    let phrases: [Phrase]
    /// Whole dictations that are instructions to yaz.
    let controls: [String: VoiceCommands.Control]
    /// Words that make a command phrase a noun instead: "I need a new
    /// line.", "Da steht ein Fragezeichen." (an article before it).
    var notAfter: Set<String> = []
    /// Marks that also open their sentence: Spanish "?" → "¿…?".
    var openings: [Character: Character] = [:]
    /// Typed before ? and !: French puts a narrow no-break space there.
    var spaceBeforeMarks = ""
    /// Turkish capitalisation (i → İ) after a command.
    var turkishCase = false
    /// Lowercasing for matching: Turkish needs its own (I → ı).
    var fold: @Sendable (String) -> String = { $0.lowercased() }

    static let turkish = CommandSet(
        phrases: [
            Phrase(words: ["yeni", "paragraf"], insert: .paragraph, inCode: false),
            Phrase(words: ["yeni", "satır"], insert: .newline, inCode: false),
            Phrase(words: ["alt", "satır"], insert: .newline, inCode: false),
            Phrase(words: ["soru", "işareti"], insert: .mark("?"), inCode: true),
            Phrase(words: ["ünlem", "işareti"], insert: .mark("!"), inCode: true),
            Phrase(words: ["iki", "nokta", "üst", "üste"], insert: .mark(":"), inCode: true),
        ],
        controls: [
            "geri al": .undoLast,
            "bunu sil": .undoLast,
            "son yazdığımı sil": .undoLast,
            "sonuncuyu sil": .undoLast,
            "son yazılanı sil": .undoLast,
        ],
        notAfter: ["bir", "bu", "şu", "her"],
        turkishCase: true,
        fold: { PhoneticKey.lowercasedTurkish($0) })
}
