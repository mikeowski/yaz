import Foundation
import Testing

@testable import yaz

@Suite("Config — the file parrot never shipped")
struct ConfigTests {

    static func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("defaults are used when the file is absent")
    func defaultsWithoutFile() {
        let config = Config.load(from: URL(fileURLWithPath: "/yok/config.json"))
        #expect(config == Config())
        #expect(config.language == "tr")
        #expect(config.hotkey == .fn)
        #expect(config.injectMode == .paste)
    }

    @Test("every field is read")
    func readsEveryField() throws {
        let url = try Self.write("""
            {
              "engine": "parakeet",
              "whisper_model": "large-v3",
              "language": "en",
              "hotkey": "right-option",
              "inject_mode": "type",
              "keep_model_loaded": false,
              "on_transcript": "pbcopy"
            }
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config.engine == .parakeet)
        #expect(config.whisperModel == .largeV3)
        #expect(config.language == "en")
        #expect(config.hotkey == .rightOption)
        #expect(config.injectMode == .type)
        #expect(config.keepModelLoaded == false)
        #expect(config.onTranscript == "pbcopy")
    }

    @Test("a partial config changes only the fields it names")
    func partialConfigKeepsDefaults() throws {
        let url = try Self.write(#"{ "hotkey": "right-command" }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config.hotkey == .rightCommand)
        #expect(config.language == "tr")           // untouched
        #expect(config.injectMode == .paste)       // untouched
    }

    /// Falling back silently leaves the user asking "why did my hotkey not
    /// change?" with nothing to go on.
    @Test("malformed JSON falls back to defaults, but not silently")
    func malformedJSONFallsBack() throws {
        let url = try Self.write("{ this is not json ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.load(from: url) == Config())
    }

    @Test("an unrecognised value leaves that field at its default")
    func unknownValueKeepsDefault() throws {
        let url = try Self.write(#"{ "hotkey": "caps-lock", "language": "en" }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config.hotkey == .fn)      // unrecognised → default
        #expect(config.language == "en")   // the valid one was applied
    }

    @Test("an empty language value is ignored")
    func emptyLanguageIgnored() throws {
        let url = try Self.write(#"{ "language": "" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.load(from: url).language == "tr")
    }

    @Test("the sample config is valid JSON and reads itself back")
    func exampleIsValid() throws {
        let data = Data(Config.example.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parsed = try #require(json)

        var config = Config()
        config.apply(parsed, source: "example")
        #expect(config == Config())   // the sample must mirror the defaults
    }

    @Test("config builds the engine it names")
    func buildsSelectedEngine() {
        var config = Config()
        config.engine = .whisper
        #expect(config.makeEngine().name == "whisper")
        config.engine = .parakeet
        #expect(config.makeEngine().name == "parakeet")
    }

    @Test("a Parakeet + Turkish config is rejected too")
    func rejectsParakeetTurkishFromConfig() {
        var config = Config()
        config.engine = .parakeet
        config.language = "tr"
        #expect(throws: YazError.self) {
            try config.makeEngine().validateLanguage(config.language)
        }
    }
}

@Suite("Config — writing to disk and reading back")
struct ConfigRoundTripTests {

    static func url() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "yaz-rt-\(UUID().uuidString)")
            .appending(path: "config.json")
    }

    /// The file the settings window writes must stay hand-editable: same key
    /// names, same reader.
    @Test("defaults survive a write and a read")
    func defaultsRoundTrip() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Config().save(to: url)
        #expect(Config.load(from: url) == Config())
    }

    @Test("every modified field is preserved")
    func everyFieldRoundTrips() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = Config()
        config.engine = .parakeet
        config.whisperModel = .largeV3
        config.language = "en"
        config.hotkey = .rightCommand
        config.injectMode = .type
        config.keepModelLoaded = false
        config.refine = .llm
        config.overlay = false
        config.menuBar = false
        config.history = false
        config.historyLimit = 42
        config.onTranscript = "pbcopy"

        try config.save(to: url)
        #expect(Config.load(from: url) == config)
    }

    @Test("vocabulary terms are preserved")
    func vocabularyRoundTrips() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = Config()
        config.vocabulary = [
            VocabularyTerm(canonical: "Slack"),
            VocabularyTerm(canonical: "PostgreSQL", aliases: ["postgres"], minSimilarity: 0.85),
        ]
        try config.save(to: url)

        let loaded = Config.load(from: url)
        #expect(loaded.vocabulary.count == 2)
        #expect(loaded.vocabulary[0].canonical == "Slack")
        #expect(loaded.vocabulary[0].aliases.isEmpty)
        #expect(loaded.vocabulary[1].aliases == ["postgres"])
        #expect(loaded.vocabulary[1].minSimilarity == 0.85)
    }

    /// A plain term stays plain; turning everything into an object makes the
    /// file harder to edit by hand.
    @Test("a term with no aliases is written as a plain string")
    func plainTermsStayPlain() throws {
        var config = Config()
        config.vocabulary = [VocabularyTerm(canonical: "Slack")]
        let list = config.asJSON()["vocabulary"] as? [Any]
        #expect(list?.first is String)
    }

    @Test("the file written is valid JSON")
    func writesValidJSON() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Config().save(to: url)
        let data = try Data(contentsOf: url)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test("a missing directory is created")
    func createsDirectory() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        try Config().save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
