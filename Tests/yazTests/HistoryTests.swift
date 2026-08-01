import Foundation
import Testing

@testable import yaz

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "yaz-history-\(UUID().uuidString)")
        .appending(path: "history.jsonl")
}

private func entry(
    _ text: String,
    app: String? = "Slack",
    date: Date = Date(),
    seconds: Double = 3.2,
    corrections: [String] = []
) -> HistoryEntry {
    HistoryEntry(
        date: date, text: text, appName: app, appBundleID: app.map { "com.\($0).app" },
        seconds: seconds, engine: "whisper", model: "large-v3-turbo",
        corrections: corrections)
}

@Suite("TranscriptHistory — ne, nerede, ne zaman")
struct TranscriptHistoryTests {

    @Test("kayıt yazılır ve geri okunur")
    func recordsAndReads() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("yarın toplantı var"))

        let entries = await store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.text == "yarın toplantı var")
        #expect(entries.first?.appName == "Slack")
    }

    @Test("en yeni kayıt başta döner")
    func newestFirst() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("birinci"))
        await store.record(entry("ikinci"))
        await store.record(entry("üçüncü"))

        let entries = await store.entries()
        #expect(entries.map(\.text) == ["üçüncü", "ikinci", "birinci"])
    }

    @Test("limit uygulanır")
    func limitApplies() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        for index in 0..<10 { await store.record(entry("kayıt \(index)")) }

        #expect(await store.entries(limit: 3).count == 3)
        #expect(await store.entries(limit: 3).first?.text == "kayıt 9")
    }

    /// Gün boyu dikte edilen bir makinede dosya sınırsız büyüyemez.
    @Test("eski kayıtlar üst sınırda düşer")
    func trimsToLimit() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url, limit: 5)
        for index in 0..<12 { await store.record(entry("kayıt \(index)")) }

        #expect(await store.count() == 5)
        let entries = await store.entries()
        #expect(entries.first?.text == "kayıt 11")
        #expect(entries.last?.text == "kayıt 7")
    }

    @Test("metinde arama")
    func searchesText() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("pull request açtım"))
        await store.record(entry("yemeğe çıkıyorum"))

        let hits = await store.entries(matching: "request")
        #expect(hits.count == 1)
        #expect(hits.first?.text.contains("pull request") == true)
    }

    @Test("uygulama adında arama")
    func searchesAppName() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("bir şey", app: "Slack"))
        await store.record(entry("başka şey", app: "Notion"))

        #expect(await store.entries(matching: "notion").count == 1)
    }

    /// Türkçe I/İ ile arama, varsayılan locale ile katlanırsa bozulur.
    @Test("arama Türkçe büyük harfe takılmaz")
    func searchIsTurkishAware() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("İSTANBUL'a gidiyorum"))
        #expect(await store.entries(matching: "istanbul").count == 1)
    }

    @Test("kapalıyken hiçbir şey yazılmaz")
    func disabledWritesNothing() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url, enabled: false)
        await store.record(entry("gizli"))
        #expect(await store.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("temizleme her şeyi siler")
    func clearRemovesEverything() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("bir"))
        await store.record(entry("iki"))
        await store.clear()
        #expect(await store.count() == 0)
        #expect(await store.entries().isEmpty)
    }

    /// Çökme sırasında yarım kalan son satır, dosyanın tamamına mal olmamalı.
    @Test("bozuk satır yalnızca kendi kaydına mal olur")
    func corruptLineCostsOneEntry() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("sağlam kayıt"))

        // Yarım yazılmış bir satır ekle.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"text":"yarım kal"#.utf8))
        try handle.close()

        let entries = await store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.text == "sağlam kayıt")
    }

    @Test("olmayan dosya boş liste verir, çökmez")
    func missingFileIsEmpty() async {
        let store = TranscriptHistory(url: temporaryURL())
        #expect(await store.entries().isEmpty)
        #expect(await store.count() == 0)
    }

    @Test("sözlük düzeltmeleri kayda geçer")
    func recordsCorrections() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("Slack'e yaz", corrections: ["Sılacık → Slack"]))
        #expect(await store.entries().first?.corrections == ["Sılacık → Slack"])
    }

    /// JSONL: her kayıt tek satır. Çok satırlı olsaydı format bozulurdu.
    @Test("her kayıt tek satır")
    func oneLinePerEntry() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("çok\nsatırlı\nmetin"))
        await store.record(entry("ikinci"))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
    }

    @Test("tarihler ISO-8601 olarak saklanır")
    func datesAreISO8601() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("kayıt", date: Date(timeIntervalSince1970: 0)))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("1970-01-01"))
    }

    /// Ses saklanmıyor: bu kasıtlı bir sınır, kayıt formatı bunu yansıtmalı.
    @Test("kayıtta ses alanı yok")
    func storesNoAudio() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("kayıt"))
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        for forbidden in ["audio", "samples", "wav", "pcm", "\"path\""] {
            #expect(!text.contains(forbidden), "kayıtta \(forbidden) geçiyor")
        }
    }
}

@Suite("Config — geçmiş anahtarları")
struct HistoryConfigTests {

    @Test("varsayılan olarak açık")
    func defaultsOn() {
        #expect(Config().history)
        #expect(Config().historyLimit == TranscriptHistory.defaultLimit)
    }

    @Test("config'den kapatılabilir ve sınırı değiştirilebilir")
    func configurable() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-hist-cfg-\(UUID().uuidString).json")
        try #"{ "history": false, "history_limit": 50 }"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        #expect(!config.history)
        #expect(config.historyLimit == 50)
    }

    @Test("geçersiz sınır yok sayılır")
    func rejectsBadLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-hist-bad-\(UUID().uuidString).json")
        try #"{ "history_limit": 0 }"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Config.load(from: url).historyLimit == TranscriptHistory.defaultLimit)
    }
}
