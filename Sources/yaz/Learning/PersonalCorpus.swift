import Foundation

/// The user's own evaluation set, built from their dictations.
///
/// `EvalCorpus` is fixed and shared: 7 measured manglings and everyday
/// sentences that no one's settings may break. This is the private half,
/// made of what the read-back sees:
///
/// - **Fixes**: a word the user replaced after a dictation (a mishearing, as
///   `Learner` judges it), with the sentence it was in. A case is right once
///   the vocabulary turns that sentence into the meant term.
/// - **Kept**: a dictation the user left exactly as pasted. It was right, so
///   it must stay unchanged.
///
/// `Evaluator.gate` scores a candidate rule against both, so a rule that
/// would break one of the user's own sentences is not kept, and
/// `yaz eval --personal` reports the score. The file stays on this Mac, next
/// to the history, and is written only while history and learning are on.
struct PersonalCorpus: Codable, Sendable, Equatable {

    struct Fix: Codable, Sendable, Equatable {
        /// What yaz pasted.
        let sentence: String
        let heard: String
        let meant: String
        let date: Date
    }

    static let maxFixes = 300
    static let maxKept = 300
    /// Shorter dictations say too little to be worth keeping as a case.
    static let minimumKeptWords = 3

    var fixes: [Fix] = []
    var kept: [String] = []

    var isEmpty: Bool { fixes.isEmpty && kept.isEmpty }

    mutating func recordFix(sentence: String, heard: String, meant: String, at date: Date = Date()) {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty,
              !fixes.contains(where: { $0.sentence == sentence && $0.heard == heard && $0.meant == meant })
        else { return }
        fixes.append(Fix(sentence: sentence, heard: heard, meant: meant, date: date))
        if fixes.count > Self.maxFixes { fixes.removeFirst(fixes.count - Self.maxFixes) }
    }

    mutating func recordKept(_ sentence: String) {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.split(whereSeparator: \.isWhitespace).count >= Self.minimumKeptWords,
              !kept.contains(sentence)
        else { return }
        kept.append(sentence)
        if kept.count > Self.maxKept { kept.removeFirst(kept.count - Self.maxKept) }
    }

    /// Forget the fixes for a term (`yaz learned --forget`).
    mutating func forget(term: String) {
        fixes.removeAll { $0.meant.lowercased() == term.lowercased() }
    }

    /// The same metric as the fixed set: a kept sentence that changes is a
    /// false match, a fix the vocabulary does not make is a miss.
    func score(_ vocabulary: Vocabulary) -> Evaluator.Score {
        var score = Evaluator.Score(
            falseMatches: 0, misses: 0, recallCases: fixes.count, precisionCases: kept.count)
        for sentence in kept {
            let result = vocabulary.correct(sentence)
            if result.didChange {
                score.falseMatches += 1
                score.offenders.append(
                    "[personal] " + result.corrections.map { "\($0.from) → \($0.to)" }
                        .joined(separator: ", "))
            }
        }
        for fix in fixes where !vocabulary.correct(fix.sentence).text.contains(fix.meant) {
            score.misses += 1
        }
        return score
    }

    // MARK: - Storage

    static var path: URL { AppEnvironment.supportDirectory.appending(path: "personal.json") }

    static func load(from url: URL = PersonalCorpus.path) -> PersonalCorpus {
        guard let data = try? Data(contentsOf: url) else { return PersonalCorpus() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersonalCorpus.self, from: data)) ?? PersonalCorpus()
    }

    func save(to url: URL = PersonalCorpus.path) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func remove(at url: URL = PersonalCorpus.path) {
        try? FileManager.default.removeItem(at: url)
    }
}
