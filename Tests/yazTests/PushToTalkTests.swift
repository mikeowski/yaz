import Testing

@testable import yaz

@Suite("PushToTalk — hold to talk, or tap twice for hands-free")
struct PushToTalkTests {

    @Test("hold, speak, release: start then stop")
    func holdAndRelease() {
        var ptt = PushToTalk()
        #expect(ptt.press(at: 0) == .start)
        #expect(ptt.release(at: 2.0) == .stop)
        #expect(ptt.state == .idle)
    }

    @Test("a double tap locks the recording, the next press stops it")
    func doubleTapLocks() {
        var ptt = PushToTalk()
        #expect(ptt.press(at: 0) == .start)
        #expect(ptt.release(at: 0.12) == .none)
        #expect(ptt.press(at: 0.3) == .lock)
        #expect(ptt.release(at: 0.4) == .none)
        #expect(ptt.state == .locked)
        #expect(ptt.tick(at: 5) == .none)
        #expect(ptt.press(at: 12) == .stop)
        #expect(ptt.release(at: 12.1) == .none)
        #expect(ptt.state == .idle)
    }

    @Test("a single accidental tap is discarded once the window passes")
    func singleTapIsDiscarded() {
        var ptt = PushToTalk()
        _ = ptt.press(at: 0)
        _ = ptt.release(at: 0.1)
        #expect(ptt.tick(at: 0.3) == .none)   // still inside the window
        #expect(ptt.tick(at: 0.6) == .discard)
        #expect(ptt.state == .idle)
    }

    @Test("a second tap after the window starts nothing new")
    func lateSecondTap() {
        var ptt = PushToTalk()
        _ = ptt.press(at: 0)
        _ = ptt.release(at: 0.1)
        #expect(ptt.press(at: 2) == .none)
        #expect(ptt.release(at: 3) == .stop)
    }

    @Test("with hands-free off, a short press is just a short hold")
    func handsFreeOff() {
        var ptt = PushToTalk(handsFree: false)
        #expect(ptt.press(at: 0) == .start)
        #expect(ptt.release(at: 0.1) == .stop)
        #expect(ptt.press(at: 0.2) == .start)
    }

    @Test("repeated press events while held do nothing")
    func repeatedPresses() {
        var ptt = PushToTalk()
        _ = ptt.press(at: 0)
        #expect(ptt.press(at: 0.5) == .none)
        #expect(ptt.release(at: 1) == .stop)
    }

    @Test("reset returns to idle from any state")
    func resetFromLocked() {
        var ptt = PushToTalk()
        _ = ptt.press(at: 0)
        _ = ptt.release(at: 0.1)
        _ = ptt.press(at: 0.2)
        _ = ptt.release(at: 0.3)
        ptt.reset()
        #expect(ptt.state == .idle)
        #expect(!ptt.isRecording)
    }
}
