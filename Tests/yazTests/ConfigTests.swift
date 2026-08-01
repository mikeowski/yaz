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
