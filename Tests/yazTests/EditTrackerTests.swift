import Foundation
import Testing
@testable import yaz

@Suite("EditTracker — following a dictation while the user fixes it")
struct EditTrackerTests {

    @Test("a fix followed by Return still counts")
    func fixThenSend() {
        var tracker = EditTracker(pasted: "Sılacık üzerinden yaz")
        #expect(tracker.observe("Sılacık üzerinden yaz") == .untouched)
        #expect(tracker.observe("Slack üzerinden yaz") == .edited)
        #expect(tracker.observe("") == .gone)
        #expect(tracker.edits == [CorrectionDiff.Edit(heard: "Sılacık", meant: "Slack")])
        #expect(!tracker.wasKept)
    }

    @Test("a short dictation with its word deleted and retyped")
    func shortRetype() {
        var tracker = EditTracker(pasted: "Sılacık aç")
        _ = tracker.observe("Merhaba, Sılacık aç")
        _ = tracker.observe("Merhaba,  aç")          // the word deleted
        _ = tracker.observe("Merhaba, Sl aç")        // being typed
        _ = tracker.observe("Merhaba, Slack aç")
        #expect(tracker.edits == [CorrectionDiff.Edit(heard: "Sılacık", meant: "Slack")])
        // The search without anchors gives up on so short a dictation.
        #expect(CorrectionDiff.edits(pasted: "Sılacık aç", field: "Merhaba, Slack aç").isEmpty)
    }

    @Test("typing on after the dictation does not hide the fix")
    func typedOn() {
        var tracker = EditTracker(pasted: "Körsır ile yazdım")
        _ = tracker.observe("Körsır ile yazdım")
        _ = tracker.observe("Cursor ile yazdım, çok hızlı")
        #expect(tracker.edits == [CorrectionDiff.Edit(heard: "Körsır", meant: "Cursor")])
    }

    @Test("text around the dictation that changes ends the watch")
    func surroundingChanged() {
        var tracker = EditTracker(pasted: "Sılacık aç")
        _ = tracker.observe("Selam Sılacık aç")
        #expect(tracker.observe("Başka bir şey") == .gone)
        #expect(tracker.wasKept)
    }

    @Test("left alone, it was right")
    func kept() {
        var tracker = EditTracker(pasted: "deploy ettim")
        #expect(tracker.observe(nil) == .waiting)
        #expect(tracker.observe("deploy ettim") == .untouched)
        #expect(tracker.observe("") == .gone)
        #expect(tracker.wasKept)
        #expect(tracker.edits.isEmpty)
    }

    @Test("deleted outright, it was not right either")
    func deleted() {
        var tracker = EditTracker(pasted: "deploy ettim")
        _ = tracker.observe("Not: deploy ettim")
        #expect(tracker.observe("Not: ") == .gone)
        #expect(!tracker.wasKept)
        #expect(tracker.edits.isEmpty)
    }

    @Test("never seen as pasted: the search over the field is the fallback")
    func unanchored() {
        var tracker = EditTracker(pasted: "Ahmet'e Sılacık üzerinden yaz")
        #expect(tracker.observe("Merhaba. Ahmet'e Slack üzerinden yaz") == .waiting)
        #expect(tracker.edits == [CorrectionDiff.Edit(heard: "Sılacık", meant: "Slack")])
        #expect(!tracker.wasKept)
    }

    @Test("an anchored region is diffed in place")
    func regionDiff() {
        #expect(CorrectionDiff.edits(pasted: "Puhrıkı Esti açtım", region: "pull request açtım")
            == [CorrectionDiff.Edit(heard: "Puhrıkı Esti", meant: "pull request")])
    }
}
