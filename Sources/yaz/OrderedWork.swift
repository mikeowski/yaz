import Foundation

/// Runs async jobs one at a time, in the order they were added, and counts
/// the ones not finished yet. The daemon finishes recordings through it: a
/// recording made while an earlier one is still being transcribed waits its
/// turn instead of being refused, and pastes keep the order they were
/// spoken in.
@MainActor
final class OrderedWork {
    /// Jobs added and not yet finished, the running one included.
    private(set) var pending = 0
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ job: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        pending += 1
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await job()
            self.pending -= 1
        }
        tail = task
        return task
    }
}
