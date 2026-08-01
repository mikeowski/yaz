import Foundation
import Testing

@testable import yaz

@Suite("Config — parrot'un hiç göndermediği dosya")
struct ConfigTests {

    static func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("dosya yoksa varsayılanlar kullanılır")
    func defaultsWithoutFile() {
        let config = Config.load(from: URL(fileURLWithPath: "/yok/config.json"))
        #expect(config == Config())
        #expect(config.language == "tr")
        #expect(config.hotkey == .fn)
        #expect(config.injectMode == .paste)
    }

    @Test("tüm alanlar okunur")
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

    @Test("kısmi config yalnızca verilen alanları değiştirir")
    func partialConfigKeepsDefaults() throws {
        let url = try Self.write(#"{ "hotkey": "right-command" }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config.hotkey == .rightCommand)
        #expect(config.language == "tr")           // dokunulmadı
        #expect(config.injectMode == .paste)       // dokunulmadı
    }

    /// Sessizce varsayılana düşmek, kullanıcıyı "kısayolum neden değişmedi"
    /// sorusuyla baş başa bırakır.
    @Test("bozuk JSON varsayılanlara düşer ama sessizce değil")
    func malformedJSONFallsBack() throws {
        let url = try Self.write("{ bu json değil ")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.load(from: url) == Config())
    }

    @Test("tanınmayan değer o alanı varsayılanda bırakır")
    func unknownValueKeepsDefault() throws {
        let url = try Self.write(#"{ "hotkey": "caps-lock", "language": "en" }"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(config.hotkey == .fn)      // tanınmadı → varsayılan
        #expect(config.language == "en")   // geçerli olan uygulandı
    }

    @Test("boş dil değeri yok sayılır")
    func emptyLanguageIgnored() throws {
        let url = try Self.write(#"{ "language": "" }"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Config.load(from: url).language == "tr")
    }

    @Test("örnek config geçerli JSON ve kendi kendini tekrar okuyabiliyor")
    func exampleIsValid() throws {
        let data = Data(Config.example.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parsed = try #require(json)

        var config = Config()
        config.apply(parsed, source: "example")
        #expect(config == Config())   // örnek, varsayılanları yansıtmalı
    }

    @Test("config seçilen motoru kurar")
    func buildsSelectedEngine() {
        var config = Config()
        config.engine = .whisper
        #expect(config.makeEngine().name == "whisper")
        config.engine = .parakeet
        #expect(config.makeEngine().name == "parakeet")
    }

    @Test("Parakeet + Türkçe config'i de reddedilir")
    func rejectsParakeetTurkishFromConfig() {
        var config = Config()
        config.engine = .parakeet
        config.language = "tr"
        #expect(throws: YazError.self) {
            try config.makeEngine().validateLanguage(config.language)
        }
    }
}

@Suite("Config — diske yazma ve geri okuma")
struct ConfigRoundTripTests {

    static func url() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "yaz-rt-\(UUID().uuidString)")
            .appending(path: "config.json")
    }

    /// Ayarlar penceresinin yazdığı dosya, elle düzenlenebilir kalmalı: aynı
    /// anahtar adları, aynı okuyucu.
    @Test("varsayılanlar yazılıp aynen geri okunur")
    func defaultsRoundTrip() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Config().save(to: url)
        #expect(Config.load(from: url) == Config())
    }

    @Test("değiştirilmiş her alan korunur")
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

    @Test("sözlük terimleri korunur")
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

    /// Sade terim sade kalmalı; her şeyi nesneye çevirmek dosyayı elle
    /// düzenlemeyi zorlaştırır.
    @Test("takma adı olmayan terim düz metin olarak yazılır")
    func plainTermsStayPlain() throws {
        var config = Config()
        config.vocabulary = [VocabularyTerm(canonical: "Slack")]
        let list = config.asJSON()["vocabulary"] as? [Any]
        #expect(list?.first is String)
    }

    @Test("yazılan dosya geçerli JSON")
    func writesValidJSON() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Config().save(to: url)
        let data = try Data(contentsOf: url)
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test("olmayan dizin oluşturulur")
    func createsDirectory() throws {
        let url = Self.url()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        try Config().save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
