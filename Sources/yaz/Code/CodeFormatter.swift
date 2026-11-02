import Foundation

/// Rewrites spoken code into written code, for text going to an editor, a
/// terminal or a coding agent.
///
/// Two rules, both deterministic:
///
/// - **Casing commands.** "camel case user name" → `userName`. The command
///   takes the English words after it: up to four, and never past the end of
///   the clause or a Turkish word ("camel case user name olsun" keeps
///   "olsun").
/// - **File mentions.** "app delegate dosyasına bak" → "@App/AppDelegate.swift
///   dosyasına bak". Before the Turkish word *dosya* (with any suffix), German
///   *Datei*, or the
///   English *file*, the one to three words are matched against the project's
///   file names, and the best match above the threshold becomes an `@` path,
///   the form Claude Code, Cursor and Codex read as a file reference.
struct CodeFormatter: Sendable {

    var files: [ProjectIndex.File] = []
    /// How close the spoken words must be to a file name.
    var fileThreshold: Double = 0.82
    /// Ordinary words of the dictation language end a casing command:
    /// "camel case user name olsun" stops before "olsun".
    var lexicon: Lexicon = .turkish

    struct Change: Sendable, Equatable {
        let from: String
        let to: String
    }

    struct Result: Sendable, Equatable {
        let text: String
        let changes: [Change]
    }

    static let maxCasedWords = 4

    func format(_ text: String) -> Result {
        var changes: [Change] = []
        var out = applyCasing(text, changes: &changes)
        out = applyFileMentions(out, changes: &changes)
        return Result(text: out, changes: changes)
    }

    // MARK: - Casing

    private func applyCasing(_ text: String, changes: inout [Change]) -> String {
        let tokens = Tokenizer.tokenize(text)
        guard tokens.count >= 3 else { return text }
        let before = changes.count
        var pieces: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, let style = Self.style(tokens[i], tokens[i + 1]),
               tokens[i + 1].trailing.isEmpty {
                var words: [String] = []
                var j = i + 2
                var trailing = ""
                while j < tokens.count, words.count < Self.maxCasedWords,
                      isIdentifierWord(tokens[j].stem) {
                    words.append(contentsOf: Identifier.words(tokens[j].stem))
                    trailing = tokens[j].trailing
                    j += 1
                    if !trailing.isEmpty { break }
                }
                if !words.isEmpty {
                    let joined = Identifier.join(words, style: style)
                    let from = tokens[i..<j].map(\.core).joined(separator: " ")
                    changes.append(Change(from: from, to: joined))
                    pieces.append(tokens[i].leading + joined + trailing)
                    i = j
                    continue
                }
            }
            pieces.append(String(text[tokens[i].range]))
            i += 1
        }
        // Nothing found: the text exactly as it came, whitespace included.
        return changes.count == before ? text : pieces.joined(separator: " ")
    }

    /// A word that can be part of an identifier: ASCII letters and digits,
    /// and not an ordinary word of the dictation language.
    private func isIdentifierWord(_ word: String) -> Bool {
        !word.isEmpty
            && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && !lexicon.isCommon(word)
    }

    /// The style two tokens name, if they are a casing command. Compared on
    /// the phonetic key, so a Turkish-accented "kemıl keys" still counts.
    private static func style(_ a: Tokenizer.Token, _ b: Tokenizer.Token) -> Identifier.Style? {
        let spoken = PhoneticKey.normalize(a.stem + " " + b.stem)
        for style in Identifier.Style.allCases {
            let trigger = PhoneticKey.normalize(style.spokenTrigger)
            if EditDistance.similarity(spoken, trigger) >= 0.8 { return style }
        }
        return nil
    }

    // MARK: - File mentions

    private func applyFileMentions(_ text: String, changes: inout [Change]) -> String {
        guard !files.isEmpty else { return text }
        let tokens = Tokenizer.tokenize(text)
        guard tokens.count >= 2 else { return text }

        var replace: [Int: (count: Int, path: String)] = [:]  // start index → span
        var consumed = Set<Int>()
        for (k, token) in tokens.enumerated() where Self.isFileWord(token.stem) && k > 0 {
            var best: (score: Double, count: Int, path: String)?
            for count in 1...min(3, k) {
                let start = k - count
                guard !(start..<k).contains(where: consumed.contains) else { continue }
                // A clause boundary before the file word ends the name.
                guard !tokens[start..<(k - 1)].contains(where: { !$0.trailing.isEmpty }) else {
                    continue
                }
                let phrase = tokens[start..<k]
                    .flatMap { Identifier.words($0.stem) }
                    .joined(separator: " ")
                guard let match = bestFile(for: phrase) else { continue }
                if best == nil || match.score > best!.score {
                    best = (match.score, count, match.path)
                }
            }
            if let best {
                replace[k - best.count] = (best.count, best.path)
                for index in (k - best.count)..<k { consumed.insert(index) }
            }
        }
        guard !replace.isEmpty else { return text }

        var pieces: [String] = []
        var i = 0
        while i < tokens.count {
            if let span = replace[i] {
                let last = tokens[i + span.count - 1]
                let from = tokens[i..<(i + span.count)].map(\.core).joined(separator: " ")
                let mention = "@" + span.path
                changes.append(Change(from: from, to: mention))
                pieces.append(tokens[i].leading + mention + last.trailing)
                i += span.count
                continue
            }
            pieces.append(String(text[tokens[i].range]))
            i += 1
        }
        return pieces.joined(separator: " ")
    }

    private func bestFile(for phrase: String) -> (score: Double, path: String)? {
        let spoken = PhoneticKey.normalize(phrase)
        guard spoken.count >= 4 else { return nil }
        var best: (score: Double, path: String)?
        for file in files {
            let score = EditDistance.similarity(spoken, PhoneticKey.normalize(file.spoken))
            if score >= fileThreshold, best == nil || score > best!.score
                // the same name in two folders: the shorter path wins a tie
                || (score == best!.score && file.path.count < best!.path.count) {
                best = (score, file.path)
            }
        }
        return best
    }

    /// "dosya" with any Turkish suffix (dosyası, dosyasına, dosyadaki…),
    /// German "Datei" (Dateien), or English "file".
    static func isFileWord(_ stem: String) -> Bool {
        let word = PhoneticKey.lowercasedTurkish(stem)
        return word.hasPrefix("dosya") || word.hasPrefix("datei")
            || word == "file" || word == "files"
    }
}
