import Foundation
import Testing

@testable import yaz

@Suite("Config — hands-free, microphone and live text")
struct RecordingSettingsTests {

    @Test("defaults: hands-free on, system microphone, no live text")
    func defaults() {
        let config = Config()
        #expect(config.handsFree)
        #expect(config.microphone == nil)
        #expect(!config.liveText)
    }

    @Test("the keys are read")
    func readsKeys() {
        var config = Config()
        config.apply(
            ["hands_free": false, "live_text": true, "microphone": "BuiltInMicrophoneDevice"],
            source: "test")
        #expect(!config.handsFree)
        #expect(config.liveText)
        #expect(config.microphone == "BuiltInMicrophoneDevice")
    }

    @Test("an empty or null microphone means the system default")
    func emptyMicrophone() {
        var config = Config()
        config.microphone = "x"
        config.apply(["microphone": NSNull()], source: "test")
        #expect(config.microphone == nil)
        config.apply(["microphone": ""], source: "test")
        #expect(config.microphone == nil)
    }

    @Test("the settings survive a write and a read")
    func roundTrips() throws {
        var config = Config()
        config.handsFree = false
        config.liveText = true
        config.microphone = "AppleUSBAudioEngine:Headset:1"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-rec-\(UUID().uuidString)")
            .appending(path: "config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try config.save(to: url)
        let loaded = Config.load(from: url)
        #expect(loaded.handsFree == false)
        #expect(loaded.liveText == true)
        #expect(loaded.microphone == "AppleUSBAudioEngine:Headset:1")
    }
}

@Suite("LivePreview — the newest words, never half a word")
struct LivePreviewTests {

    @Test("short text is shown whole")
    func shortText() {
        #expect(LivePreview.tail(of: "Yarın saat ikide") == "Yarın saat ikide")
    }

    @Test("long text keeps the end and starts on a whole word")
    func longText() {
        let text = "Yarın saat on dörtte toplantı var Ahmete Slack üzerinden mesaj atmayı unutma"
        let tail = LivePreview.tail(of: text, max: 30)
        #expect(tail.hasPrefix("…"))
        #expect(text.hasSuffix(String(tail.dropFirst())))
        #expect(tail.count <= 31)
        // the first shown word is a whole word of the original
        let first = tail.dropFirst().split(separator: " ").first.map(String.init) ?? ""
        #expect(text.split(separator: " ").map(String.init).contains(first))
    }

    @Test("annotation markers are cleaned like the final text")
    func sanitized() {
        #expect(!LivePreview.tail(of: "[BLANK_AUDIO] merhaba").contains("BLANK"))
    }
}
