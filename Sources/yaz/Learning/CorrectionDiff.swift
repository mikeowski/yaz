import Foundation

/// What the user changed in a dictation after it was pasted.
///
/// The field around the dictation holds other text too, so the pasted words
/// are first located inside it (the window of field words that shares the
/// longest common subsequence with them), then the two word lists are
/// aligned and every replaced run is reported. Insertions and deletions on
/// their own are not mishearings and are left out.
enum CorrectionDiff {

    struct Edit: Sendable, Equatable {
        /// What yaz wrote.
        let heard: String
        /// What the user changed it to.
        let meant: String
    }

    /// How much of the dictation must still be recognisable in the field to
    /// trust the alignment at all.
    static let minimumOverlap = 0.6

    static func edits(pasted: String, field: String) -> [Edit] {
        let a = words(pasted)
        let fieldWords = words(field)
        guard !a.isEmpty, !fieldWords.isEmpty else { return [] }
        guard let b = locate(a, in: fieldWords) else { return [] }
        return replacements(a, b)
    }

    // MARK: -

    /// Whitespace-separated words, with outer punctuation trimmed for
    /// comparison but kept apart from the word itself.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func key(_ word: String) -> String {
        PhoneticKey.lowercasedTurkish(word)
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// The field window that best matches the dictation, or nil if none is
    /// close enough to be the same text.
    private static func locate(_ pasted: [String], in field: [String]) -> [String]? {
        let n = pasted.count
        var best: (score: Double, distance: Int, window: [String])?
        let sizes = max(1, n - 3)...(n + 3)
        for size in sizes where size <= field.count {
            for start in 0...(field.count - size) {
                let window = Array(field[start..<(start + size)])
                let common = lcs(pasted.map(key), window.map(key)).count
                let score = Double(common) / Double(max(n, size))
                // On a tie, the window closest in length to the dictation:
                // a shorter one scores the same by leaving the changed
                // words out, which is exactly what must be found.
                let distance = abs(size - n)
                if best == nil || score > best!.score
                    || (score == best!.score && distance < best!.distance) {
                    best = (score, distance, window)
                }
            }
        }
        guard let best, best.score >= minimumOverlap, best.score < 1 || best.window != pasted else {
            return nil
        }
        return best.window
    }

    /// Runs where both sides changed: between two anchors of the LCS, the
    /// pasted words that are gone and the field words that replaced them.
    private static func replacements(_ a: [String], _ b: [String]) -> [Edit] {
        let anchors = lcs(a.map(key), b.map(key))
        var edits: [Edit] = []
        var i = 0, j = 0
        for (ai, bj) in anchors + [(a.count, b.count)] {
            if ai > i && bj > j {
                edits.append(Edit(
                    heard: a[i..<ai].joined(separator: " "),
                    meant: b[j..<bj].joined(separator: " ")))
            }
            i = ai + 1
            j = bj + 1
        }
        return edits
    }

    /// Index pairs of a longest common subsequence.
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
