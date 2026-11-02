import Foundation
import Testing
@testable import yaz

@Suite("AppProfile — settings that differ per app")
struct AppProfileTests {

    private static let slack = "com.tinyspeck.slackmacgap"

    private func load(_ json: String) throws -> Config {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-apps-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        return Config.load(from: url)
    }

    @Test("profiles are read from the config file")
    func reading() throws {
        let config = try load("""
            { "language": "tr", "apps": {
                "com.tinyspeck.slackmacgap": { "style": "chat", "refine": "off" },
                "com.github.GitHubClient": { "language": "en", "code": true }
            } }
            """)
        #expect(config.apps[Self.slack] == AppProfile(refine: .off, style: .chat))
        #expect(config.apps["com.github.GitHubClient"] == AppProfile(language: "en", code: true))
    }

    @Test("an unknown value is ignored, the rest of the profile kept")
    func unknownValue() throws {
        let config = try load(#"{ "apps": { "x.y": { "style": "shouty", "numbers": false } } }"#)
        #expect(config.apps["x.y"] == AppProfile(numbers: false))
    }

    @Test("an app's settings are the main ones with its profile on top")
    func forApp() {
        var config = Config()
        config.apps[Self.slack] = AppProfile(numbers: false, style: .chat)
        let slack = config.forApp(Self.slack)
        #expect(slack.style == .chat)
        #expect(!slack.numbers)
        #expect(slack.refine == config.refine)
        #expect(slack.codeOverride == nil)
        #expect(config.forApp("com.apple.mail") == config)
        #expect(config.forApp(nil) == config)
    }

    @Test("profiles survive a save and a load")
    func roundTrip() throws {
        var config = Config()
        config.apps[Self.slack] = AppProfile(language: "en", refine: .llm, voiceCommands: false, style: .chat)
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-apps-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try config.save(to: url)
        #expect(Config.load(from: url) == config)
    }

    @Test(
        "chat style drops a lone sentence's full stop, and nothing else",
        arguments: [
            ("Tamam, bakıyorum.", "Tamam, bakıyorum"),
            ("Saat 15.30'da geliyorum.", "Saat 15.30'da geliyorum"),
            ("Geliyor musun?", "Geliyor musun?"),
            ("Harika!", "Harika!"),
            ("Tamam. Yarın bakarım.", "Tamam. Yarın bakarım."),
            ("Bekle...", "Bekle..."),
            ("Bitti.\nYarın görüşürüz.", "Bitti.\nYarın görüşürüz."),
        ])
    func chat(_ text: String, _ expected: String) {
        #expect(TextStyle.chat.apply(text) == expected)
        #expect(TextStyle.standard.apply(text) == text)
    }

    @Test("the pipeline finishes text in the app's style, never in code")
    func pipeline() async {
        var config = Config()
        config.style = .chat
        let pipeline = TranscriptPipeline(config: config)
        #expect(await pipeline.process("Tamam, bakıyorum.").text == "Tamam, bakıyorum")
        #expect(await pipeline.process("Tamam, bakıyorum.", code: true).text == "Tamam, bakıyorum.")
    }

    @Test("a profile can force code mode")
    func codeOverride() {
        var config = Config()
        config.apps["com.apple.Notes"] = AppProfile(code: true)
        #expect(config.forApp("com.apple.Notes").codeOverride == true)
    }
}
