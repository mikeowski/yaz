import Testing

@testable import yaz

/// A pasteboard with a change count and nothing else. `nil` is an empty
/// pasteboard.
@MainActor
final class FakePasteboard: RestorablePasteboard {
    private(set) var contents: String?
    private(set) var changeCount = 0

    init(_ contents: String?) {
        self.contents = contents
    }

    func snapshot() -> String? { contents }

    func write(_ text: String) -> Int {
        contents = text
        changeCount += 1
        return changeCount
    }

    func restore(_ snapshot: String?) {
        contents = snapshot
        changeCount += 1
    }

    /// The user pressing ⌘C somewhere else.
    func userCopies(_ text: String) {
        _ = write(text)
    }
}

@Suite("PasteboardRestore — dictation must never cost the user their clipboard")
@MainActor
struct PasteboardRestoreTests {

    @Test("the user's contents come back after a dictation")
    func restoresAfterOneDictation() {
        let board = FakePasteboard("user's text")
        let restore = PasteboardRestore(board: board)

        let token = restore.put("dictation")
        #expect(board.contents == "dictation")

        #expect(restore.restore(after: token) == .restored)
        #expect(board.contents == "user's text")
    }

    @Test("a copy made during the delay is not overwritten")
    func keepsACopyMadeAfterThePaste() {
        let board = FakePasteboard("old")
        let restore = PasteboardRestore(board: board)

        let token = restore.put("dictation")
        board.userCopies("new copy")

        #expect(restore.restore(after: token) == .pasteboardChanged)
        #expect(board.contents == "new copy")
    }

    /// The bug this type exists for: the second snapshot used to capture the
    /// first dictation, so the last restore put a dictation back and the
    /// user's own contents were gone.
    @Test("two dictations in a row still give back the original contents")
    func backToBackDictationsKeepTheOriginal() {
        let board = FakePasteboard("original")
        let restore = PasteboardRestore(board: board)

        let first = restore.put("first dictation")
        let second = restore.put("second dictation")

        #expect(restore.restore(after: first) == .superseded)
        #expect(board.contents == "second dictation")

        #expect(restore.restore(after: second) == .restored)
        #expect(board.contents == "original")
    }

    @Test("a copy between two dictations is what comes back")
    func copyBetweenDictationsWins() {
        let board = FakePasteboard("original")
        let restore = PasteboardRestore(board: board)

        let first = restore.put("first dictation")
        board.userCopies("copied in between")
        let second = restore.put("second dictation")

        #expect(restore.restore(after: first) == .superseded)
        #expect(restore.restore(after: second) == .restored)
        #expect(board.contents == "copied in between")
    }

    @Test("an empty pasteboard is empty again afterwards")
    func emptyStaysEmpty() {
        let board = FakePasteboard(nil)
        let restore = PasteboardRestore(board: board)

        let token = restore.put("dictation")
        #expect(restore.restore(after: token) == .restored)
        #expect(board.contents == nil)
    }

    @Test("the record is cleared, so a later dictation snapshots afresh")
    func laterDictationSnapshotsAgain() {
        let board = FakePasteboard("one")
        let restore = PasteboardRestore(board: board)

        restore.restore(after: restore.put("dictation"))
        board.userCopies("two")

        let token = restore.put("dictation")
        #expect(restore.restore(after: token) == .restored)
        #expect(board.contents == "two")
    }

    @Test("a stale token does nothing")
    func staleTokenDoesNothing() {
        let board = FakePasteboard("original")
        let restore = PasteboardRestore(board: board)

        let token = restore.put("dictation")
        #expect(restore.restore(after: token) == .restored)
        // Restoring twice must not touch the pasteboard again.
        board.userCopies("later")
        #expect(restore.restore(after: token) == .pasteboardChanged)
        #expect(board.contents == "later")
    }
}
