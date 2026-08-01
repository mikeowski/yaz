import Foundation

/// Collapses concurrent calls for the same expensive resource into one.
///
/// Without this, `prepare()` has a reentrancy hole that costs real money in
/// RAM: an actor suspends at `await`, so a second caller can pass the
/// `guard box.kit == nil` check while the first load is still in flight and
/// start a *second* 1.6 GB model load. The actor serialises statements, not
/// operations spanning a suspension.
///
/// Callers awaiting an in-flight load all observe its result — success or
/// failure. A failed load is not cached: the next caller retries, because the
/// usual cause is a transient download.
actor SingleFlight {
    private var inFlight: Task<Void, Error>?

    /// Run `work` unless it is already running, in which case await that run.
    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }

    /// Drop any memory of a completed run, so the next `run` executes again.
    func reset() {
        inFlight?.cancel()
        inFlight = nil
    }
}

/// Runs async work strictly one at a time.
///
/// Actors do not provide this on their own: an actor method that awaits lets
/// another call in, so two `transcribe()` calls can reach the underlying
/// Core ML pipeline concurrently. WhisperKit makes no reentrancy guarantee, so
/// overlapping inference is undefined behaviour rather than merely slow.
///
/// Work is queued in arrival order and never dropped. A failing job does not
/// break the chain — the next one still runs.
actor SerialGate {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let job = Task<T, Error> {
            // Wait for the queue ahead of us. `previous` never throws, so a
            // failed predecessor cannot cancel this job.
            await previous?.value
            return try await work()
        }
        // Keep a non-throwing handle as the new tail so the chain survives a
        // job that throws.
        tail = Task { _ = try? await job.value }
        return try await job.value
    }
}
