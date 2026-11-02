import Foundation

/// Learns from what the user fixes after a dictation.
///
/// The online half of yaz's autoresearch loop. A fix the user makes is an
/// observation; an observation seen twice becomes a candidate rule; a
/// candidate is **kept only if** `Evaluator.gate` says it fixes its own case
/// and leaves the fixed evaluation no worse — otherwise it is rejected and
/// never proposed again. Keep or revert, against one number, with nothing
/// tuned allowed to touch the evaluation.
///
/// Two lessons:
///
/// - **A mishearing.** The user replaced "Sılacık" with "Slack": after the
///   second time, "Sılacık" becomes an alias of "Slack".
/// - **A wrong repair.** yaz turned "doktor" into "Docker" and the user put
///   "doktor" back: that pair is blocked at once. Undoing a change is
///   explicit; it needs no second sighting.
struct Learner: Sendable {

    static let promoteAfter = 2
    /// How alike what yaz wrote and what the user meant must sound for the
    /// edit to be a mishearing, not a change of mind.
    static let minimumSimilarity = 0.45
    static let maxWords = 3

    var rules: LearnedRules

    enum Event: Sendable, Equatable {
        case noted(heard: String, meant: String, count: Int)
        case learned(heard: String, meant: String)
        case rejected(heard: String, meant: String, reason: String)
        case blocked(heard: String, term: String)
    }

    /// Feed one dictation: what was pasted, the repairs yaz made in it, and
    /// the user's edits found afterwards. `userTerms` are the configured
    /// terms, for the gate.
    mutating func observe(
        edits: [CorrectionDiff.Edit],
        corrections: [Vocabulary.Correction],
        userTerms: [VocabularyTerm],
        now: Date = Date()
    ) -> [Event] {
        var events: [Event] = []
        for edit in edits {
            let heard = Self.stem(edit.heard)
            let meant = Self.stem(edit.meant)
            guard !heard.isEmpty, !meant.isEmpty, heard.lowercased() != meant.lowercased() else {
                continue
            }

            // A repair undone: the user restored what was heard.
            if let undone = corrections.first(where: {
                Self.stem($0.to).lowercased() == heard.lowercased()
                    && PhoneticKey.normalize(Self.stem($0.from)) == PhoneticKey.normalize(meant)
            }) {
                let block = Vocabulary.Block(heard: Self.stem(undone.from), term: heard)
                if !rules.blocks.contains(block) {
                    rules.blocks.append(block)
                    events.append(.blocked(heard: block.heard, term: block.term))
                }
                continue
            }

            guard Self.isMishearing(heard: heard, meant: meant) else { continue }
            guard !rules.isKnown(heard: heard, meant: meant) else { continue }

            let count = rules.note(heard: heard, meant: meant, at: now)
            guard count >= Self.promoteAfter else {
                events.append(.noted(heard: heard, meant: meant, count: count))
                continue
            }

            let candidate = VocabularyTerm(canonical: meant, aliases: [heard])
            let verdict = Evaluator.gate(
                candidate, heard: heard, existing: userTerms + rules.terms)
            if verdict.accepted {
                rules.learn(heard: heard, meant: meant, at: now)
                events.append(.learned(heard: heard, meant: meant))
            } else {
                rules.reject(heard: heard, meant: meant, reason: verdict.reason)
                events.append(.rejected(heard: heard, meant: meant, reason: verdict.reason))
            }
        }
        return events
    }

    /// A replacement that looks like a mishearing of a term: short, sounds
    /// alike, and the new words are not ordinary Turkish (that is an edit of
    /// meaning, not of spelling).
    static func isMishearing(heard: String, meant: String) -> Bool {
        let heardWords = heard.split(separator: " ").map(String.init)
        let meantWords = meant.split(separator: " ").map(String.init)
        guard (1...maxWords).contains(heardWords.count),
              (1...maxWords).contains(meantWords.count),
              meant.count >= Vocabulary.minimumTermLength
        else { return false }
        guard !TurkishLexicon.containsCommonWord(meantWords) else { return false }
        let full = EditDistance.similarity(PhoneticKey.normalize(heard), PhoneticKey.normalize(meant))
        let skeleton = EditDistance.similarity(PhoneticKey.skeleton(heard), PhoneticKey.skeleton(meant))
        return max(full, skeleton) >= minimumSimilarity
    }

    /// The words without outer punctuation and without a Turkish apostrophe
    /// suffix: "Slack'ten," → "Slack".
    static func stem(_ text: String) -> String {
        Tokenizer.tokenize(text).map(\.stem).joined(separator: " ")
    }
}

/// What has been learned, on disk at `~/Library/Application Support/yaz/
/// learned.json`. Separate from the config file, which stays the user's own.
struct LearnedRules: Codable, Sendable, Equatable {

    struct Rule: Codable, Sendable, Equatable {
        let heard: String
        let meant: String
        let learnedAt: Date
    }

    struct Observation: Codable, Sendable, Equatable {
        let heard: String
        let meant: String
        var count: Int
        var lastSeen: Date
        var rejectedBecause: String?
    }

    var rules: [Rule] = []
    var observations: [Observation] = []
    var blocks: [Vocabulary.Block] = []

    /// Learned rules as vocabulary terms, aliases grouped under their term.
    var terms: [VocabularyTerm] {
        var order: [String] = []
        var aliases: [String: [String]] = [:]
        for rule in rules {
            if aliases[rule.meant] == nil { order.append(rule.meant) }
            aliases[rule.meant, default: []].append(rule.heard)
        }
        return order.map { VocabularyTerm(canonical: $0, aliases: aliases[$0] ?? []) }
    }

    func isKnown(heard: String, meant: String) -> Bool {
        rules.contains { $0.heard == heard && $0.meant == meant }
            || observations.contains {
                $0.heard == heard && $0.meant == meant && $0.rejectedBecause != nil
            }
    }

    mutating func note(heard: String, meant: String, at date: Date) -> Int {
        if let i = observations.firstIndex(where: { $0.heard == heard && $0.meant == meant }) {
            observations[i].count += 1
            observations[i].lastSeen = date
            return observations[i].count
        }
        observations.append(Observation(heard: heard, meant: meant, count: 1, lastSeen: date))
        return 1
    }

    mutating func learn(heard: String, meant: String, at date: Date) {
        observations.removeAll { $0.heard == heard && $0.meant == meant }
        rules.append(Rule(heard: heard, meant: meant, learnedAt: date))
    }

    mutating func reject(heard: String, meant: String, reason: String) {
        if let i = observations.firstIndex(where: { $0.heard == heard && $0.meant == meant }) {
            observations[i].rejectedBecause = reason
        }
    }

    /// Forget everything learned for a term, its blocks included.
    mutating func forget(term: String) {
        rules.removeAll { $0.meant.lowercased() == term.lowercased() }
        observations.removeAll { $0.meant.lowercased() == term.lowercased() }
        blocks.removeAll { $0.term.lowercased() == term.lowercased() }
    }

    // MARK: - Storage

    static var path: URL { AppEnvironment.supportDirectory.appending(path: "learned.json") }

    static func load(from url: URL = LearnedRules.path) -> LearnedRules {
        guard let data = try? Data(contentsOf: url) else { return LearnedRules() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LearnedRules.self, from: data)) ?? LearnedRules()
    }

    func save(to url: URL = LearnedRules.path) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
