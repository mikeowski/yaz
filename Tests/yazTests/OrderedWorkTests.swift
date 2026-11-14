import Foundation
import Testing

@testable import yaz

@Suite("OrderedWork — recordings finish one at a time, in order")
@MainActor
struct OrderedWorkTests {

    @Test("a job added while another runs waits for it, and order is kept")
    func keepsOrder() async {
        let work = OrderedWork()
        var log: [String] = []
        work.enqueue {
            log.append("first start")
            try? await Task.sleep(for: .milliseconds(50))
            log.append("first end")
        }
        let last = work.enqueue { log.append("second") }
        #expect(work.pending == 2)
        await last.value
        #expect(log == ["first start", "first end", "second"])
        #expect(work.pending == 0)
    }

    @Test("pending counts the running job until it returns")
    func pendingDuringJob() async {
        let work = OrderedWork()
        var seen = -1
        await work.enqueue { seen = work.pending }.value
        #expect(seen == 1)
        #expect(work.pending == 0)
    }
}

@Suite("TranscribeOptions — the timeout follows the recording")
struct TimeoutScalingTests {

    @Test("never under 120 s, never under the recording")
    func scales() {
        #expect(TranscribeOptions.timeout(forAudioSeconds: 3) == .seconds(120))
        #expect(TranscribeOptions.timeout(forAudioSeconds: 119.2) == .seconds(120))
        #expect(TranscribeOptions.timeout(forAudioSeconds: 600) == .seconds(600))
    }
}

@Suite("HotkeyMonitor — a key-up the tap missed")
struct MissedReleaseTests {

    @Test("down but no longer held is a missed release")
    func missed() {
        #expect(HotkeyMonitor.missedRelease(isDown: true, flagHeld: false, keyHeld: nil))
        #expect(HotkeyMonitor.missedRelease(isDown: true, flagHeld: true, keyHeld: false))
    }

    @Test("held, or already up, is not")
    func notMissed() {
        #expect(!HotkeyMonitor.missedRelease(isDown: true, flagHeld: true, keyHeld: nil))
        #expect(!HotkeyMonitor.missedRelease(isDown: true, flagHeld: true, keyHeld: true))
        #expect(!HotkeyMonitor.missedRelease(isDown: false, flagHeld: false, keyHeld: false))
    }
}

@Suite("withDeadline — a call that ignores cancellation still ends")
struct DeadlineTests {

    @Test("work that never returns and ignores cancellation times out")
    func neverReturns() async {
        let started = Date()
        await #expect(throws: YazError.self) {
            _ = try await withDeadline(.milliseconds(100), {
                // Not cancellable: a semaphore wait that nothing signals,
                // like a Core ML call that hangs.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }, onTimeout: { YazError.transcriptionTimedOut(engine: "test", seconds: 0.1) })
        }
        // Ends, rather than never: under the full suite the pool is busy and
        // the 100 ms deadline fires late, so the bound is loose.
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("a result before the deadline is returned")
    func returns() async throws {
        let value = try await withDeadline(.seconds(5), { 42 }, onTimeout: {
            YazError.transcriptionTimedOut(engine: "test", seconds: 5)
        })
        #expect(value == 42)
    }
}
