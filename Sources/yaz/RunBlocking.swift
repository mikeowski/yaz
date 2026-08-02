import Foundation

/// Runs async work to completion from a synchronous context.
///
/// Every command in yaz is a synchronous `ParsableCommand`, which looks
/// backwards for a codebase full of `async` and needs explaining.
///
/// `NSApplication.run()` never returns. Called from inside an
/// `AsyncParsableCommand`, it blocks a Swift concurrency task that owns the
/// MainActor — and the cooperative executor will not run any *other* MainActor
/// work until that task finishes, which it never does. Measured: CFRunLoop
/// timers kept firing while the main dispatch queue was never drained once, so
/// the model-ready callback never ran and the daemon sat there with `ready`
/// permanently false.
///
/// Making the root command synchronous hands the main thread to AppKit with no
/// task owning it. Async subcommands then need a bridge, and this is it. The
/// blocking is deliberate and harmless here: a CLI subcommand has nothing else
/// to do while it waits.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)

    // Detached on purpose: inheriting the caller's context would put this back
    // on the actor we are trying to stay off.
    Task.detached(priority: .userInitiated) {
        do {
            box.set(.success(try await work()))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }

    semaphore.wait()
    return try box.take().get()
}

/// Carries one result across the semaphore.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func set(_ value: Result<T, Error>) {
        lock.withLock { result = value }
    }

    func take() -> Result<T, Error> {
        lock.withLock {
            result ?? .failure(
                YazError.transcriptionFailed(engine: "cli", underlying: "no result produced"))
        }
    }
}
