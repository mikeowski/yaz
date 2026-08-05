import Foundation
import Testing

@testable import yaz

/// The timeout wrapper is the only thing standing between a wedged Core ML
/// call and a daemon that never dictates again. It had no test until now.
@Suite("withTranscriptionTimeout — surviving a wedged inference")
struct TimeoutTests {

    @Test("work that finishes in time returns its result")
    func fastWorkReturns() async throws {
        let value = try await withTranscriptionTimeout(.seconds(5), engine: "test") { 42 }
        #expect(value == 42)
    }

    @Test("wedged work times out and releases the caller")
    func hungWorkTimesOut() async {
        let started = Date()
        do {
            _ = try await withTranscriptionTimeout(.milliseconds(120), engine: "test") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            Issue.record("expected a timeout")
        } catch let error as YazError {
            guard case .transcriptionTimedOut(let engine, _) = error else {
                Issue.record("transcriptionTimedOut bekleniyordu, gelen: \(error)")
                return
            }
            #expect(engine == "test")
        } catch {
            Issue.record("YazError bekleniyordu, gelen: \(error)")
        }
        // This is the actual guarantee: the caller did not wait 30 s.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("an error from the work is not turned into a timeout error")
    func workErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTranscriptionTimeout(.seconds(5), engine: "test") {
                throw Boom()
            }
        }
    }

    @Test("wedged work is cancelled after the timeout — it must not leak")
    func losingBranchIsCancelled() async throws {
        let cancelled = CancellationFlag()
        do {
            _ = try await withTranscriptionTimeout(.milliseconds(80), engine: "test") {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.set()          // Task.sleep throws on cancellation
                    throw error
                }
                return 1
            }
        } catch {}

        // Give cancellation a short window to propagate.
        try await Task.sleep(for: .milliseconds(150))
        #expect(cancelled.value)
    }

    @Test("the timeout duration appears in the error message")
    func messageNamesTheLimit() async {
        do {
            _ = try await withTranscriptionTimeout(.seconds(1), engine: "whisper") {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        } catch let error as YazError {
            #expect(error.description.contains("whisper"))
            #expect(error.description.contains("1"))
        } catch {
            Issue.record("expected a YazError")
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
