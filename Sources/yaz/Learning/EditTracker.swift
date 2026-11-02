import Foundation

/// Follows one dictation in its field while the user edits it.
///
/// A single look some seconds later misses most fixes: in a chat app the
/// user corrects the word and presses Return, and by then the field is
/// empty. So the field is read about once a second. The first reading that
/// still holds the pasted text exactly fixes two anchors, the text before
/// it and the text after it, which the user did not dictate. In every later
/// reading, whatever lies between the anchors is the dictation as the user
/// has edited it, however much changed: deleting a word and typing another
/// shows up as exactly that. When the anchors go (the message was sent, the
/// field cleared), the last edited state is what counts.
struct EditTracker: Sendable {

    enum Status: Sendable, Equatable {
        /// The field has not shown the dictation yet.
        case waiting
        /// The dictation is there, as pasted.
        case untouched
        /// The dictation is there, edited.
        case edited
        /// The dictation is no longer in the field (sent, cleared, moved on).
        case gone
    }

    let pasted: String
    private var before: String?
    private var after: String?
    /// The dictation as last seen, between the anchors, or the whole text
    /// after the first anchor when the user typed on past the dictation.
    private(set) var region: String?
    private var regionIsExact = false
    /// A reading that never showed the pasted text: the fallback.
    private var unanchored: String?
    /// The dictation was deleted while the rest of the field stayed: not a
    /// sign it was right. (A sent message empties the whole field instead.)
    private var removed = false

    init(pasted: String) {
        self.pasted = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isAnchored: Bool { before != nil }

    mutating func observe(_ field: String?) -> Status {
        guard let field else { return isAnchored ? .gone : .waiting }
        guard let before, let after else {
            // The last occurrence: a paste lands at the cursor, usually last.
            if let range = field.range(of: pasted, options: .backwards) {
                self.before = String(field[..<range.lowerBound])
                self.after = String(field[range.upperBound...])
                region = pasted
                regionIsExact = true
                return .untouched
            }
            unanchored = field
            return .waiting
        }
        let candidate: String
        let exact: Bool
        if field.hasPrefix(before), field.hasSuffix(after),
           field.count >= before.count + after.count {
            let start = field.index(field.startIndex, offsetBy: before.count)
            let end = field.index(field.endIndex, offsetBy: -after.count)
            candidate = String(field[start..<end])
            exact = true
        } else if field.hasPrefix(before) {
            candidate = String(field.dropFirst(before.count))
            exact = false
        } else {
            return .gone
        }
        // Nothing left where the dictation was: sent or deleted. The last
        // reading with text in it stands.
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !(before + after).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { removed = true }
            return .gone
        }
        region = candidate
        regionIsExact = exact
        return region?.trimmingCharacters(in: .whitespacesAndNewlines) == pasted ? .untouched : .edited
    }

    /// True when the dictation was seen and was never changed.
    var wasKept: Bool {
        isAnchored && !removed && region?.trimmingCharacters(in: .whitespacesAndNewlines) == pasted
    }

    /// What the user replaced, from the last reading that still held the
    /// dictation.
    var edits: [CorrectionDiff.Edit] {
        if let region, isAnchored {
            let edited = region.trimmingCharacters(in: .whitespacesAndNewlines)
            guard edited != pasted, !edited.isEmpty else { return [] }
            return regionIsExact
                ? CorrectionDiff.edits(pasted: pasted, region: edited)
                : CorrectionDiff.edits(pasted: pasted, field: edited)
        }
        if let unanchored { return CorrectionDiff.edits(pasted: pasted, field: unanchored) }
        return []
    }
}
