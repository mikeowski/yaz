import AppKit
import Foundation

/// The parts of a pasteboard that `PasteboardRestore` needs. `NSPasteboard`
/// in the app; a fake in the tests, which have no window server.
@MainActor
protocol RestorablePasteboard: AnyObject {
    associatedtype Snapshot
    /// Goes up on every write, by anyone. The only way to tell whether the
    /// user copied something after we did.
    var changeCount: Int { get }
    func snapshot() -> Snapshot
    /// Replace the contents with `text`. Returns the new change count.
    func write(_ text: String) -> Int
    func restore(_ snapshot: Snapshot)
}

/// Puts the dictation on the pasteboard and gives the user's own contents
/// back afterwards, without ever overwriting something newer.
///
/// The first version restored the snapshot unconditionally after a delay.
/// That loses data in two ordinary cases:
///
/// - **The user copies during the delay.** The restore then overwrites what
///   they just copied with what they had before.
/// - **Two dictations in a row.** The second snapshot is taken while the
///   pasteboard still holds the *first dictation*, so the last restore puts
///   the dictation back and the user's real contents are gone for good.
///
/// So the restore is conditional. A generation counter makes only the newest
/// paste restore, and the pasteboard's `changeCount` shows whether anybody
/// wrote to it after us. When the pasteboard still holds our previous
/// dictation, the snapshot from before that dictation is kept, not replaced.
@MainActor
final class PasteboardRestore<Board: RestorablePasteboard> {

    enum Outcome: Equatable, Sendable {
        /// The user's earlier contents are back.
        case restored
        /// A newer dictation owns the restore now.
        case superseded
        /// Somebody wrote to the pasteboard after the dictation. Their
        /// contents are newer than the snapshot, so they stay.
        case pasteboardChanged
    }

    private let board: Board
    private var generation = 0
    /// What the user had before the first of the pending dictations.
    private var original: Board.Snapshot?
    /// The change count right after our last write.
    private var insertedChangeCount: Int?

    init(board: Board) {
        self.board = board
    }

    /// Write `text`, remembering what was there. Returns the token to pass to
    /// `restore(after:)`.
    func put(_ text: String) -> Int {
        // Only re-snapshot when the pasteboard holds something other than
        // our own previous dictation.
        if original == nil || board.changeCount != insertedChangeCount {
            original = board.snapshot()
        }
        insertedChangeCount = board.write(text)
        generation += 1
        return generation
    }

    /// Give the user's contents back, if nothing newer is there.
    @discardableResult
    func restore(after token: Int) -> Outcome {
        guard token == generation else { return .superseded }
        defer {
            self.original = nil
            self.insertedChangeCount = nil
        }
        guard let original, board.changeCount == insertedChangeCount else {
            return .pasteboardChanged
        }
        board.restore(original)
        return .restored
    }
}

/// `NSPasteboard.general`, seen through `RestorablePasteboard`.
@MainActor
final class SystemPasteboard: RestorablePasteboard {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    /// Everything on the pasteboard, per type — not only the string. The
    /// user's clipboard can hold an image or a file, and coming back to find
    /// it replaced by dictation is worse than the dictation failing.
    func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func write(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func restore(_ snapshot: [NSPasteboardItem]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.writeObjects(snapshot)
    }
}
