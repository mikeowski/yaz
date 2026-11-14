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
