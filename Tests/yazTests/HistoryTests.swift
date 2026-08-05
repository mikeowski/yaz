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

    @Test("an entry is written and read back")
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

    @Test("the newest entry comes back first")
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

    @Test("the limit is applied")
    func limitApplies() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        for index in 0..<10 { await store.record(entry("kayıt \(index)")) }

        #expect(await store.entries(limit: 3).count == 3)
        #expect(await store.entries(limit: 3).first?.text == "kayıt 9")
    }

    /// On a machine dictated into all day, the file cannot grow forever.
    @Test("old entries fall off at the cap")
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

    @Test("searching by app name")
    func searchesAppName() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("bir şey", app: "Slack"))
        await store.record(entry("başka şey", app: "Notion"))

        #expect(await store.entries(matching: "notion").count == 1)
    }

    /// Searching across Turkish I/İ breaks if folded with the default locale.
    @Test("search is not tripped by Turkish uppercasing")
    func searchIsTurkishAware() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("İSTANBUL'a gidiyorum"))
        #expect(await store.entries(matching: "istanbul").count == 1)
    }

    @Test("nothing is written while it is switched off")
    func disabledWritesNothing() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url, enabled: false)
        await store.record(entry("gizli"))
        #expect(await store.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clearing removes everything")
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

    /// A last line left half-written by a crash must not cost the whole file.
    @Test("a corrupt line costs only its own entry")
    func corruptLineCostsOneEntry() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("sağlam kayıt"))

        // Append a half-written line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"text":"yarım kal"#.utf8))
        try handle.close()

        let entries = await store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.text == "sağlam kayıt")
    }

    @Test("a missing file gives an empty list rather than crashing")
    func missingFileIsEmpty() async {
        let store = TranscriptHistory(url: temporaryURL())
        #expect(await store.entries().isEmpty)
        #expect(await store.count() == 0)
    }

    @Test("vocabulary corrections are recorded")
    func recordsCorrections() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("Slack'e yaz", corrections: ["Sılacık → Slack"]))
        #expect(await store.entries().first?.corrections == ["Sılacık → Slack"])
    }

    /// JSONL: one entry per line. Multi-line entries would break the format.
    @Test("each entry is a single line")
    func oneLinePerEntry() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("çok\nsatırlı\nmetin"))
        await store.record(entry("ikinci"))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
    }

    @Test("dates are stored as ISO-8601")
    func datesAreISO8601() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("kayıt", date: Date(timeIntervalSince1970: 0)))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("1970-01-01"))
    }

    /// No audio is stored. That is a deliberate boundary, and the record
    /// format has to reflect it.
    @Test("no audio field exists in an entry")
    func storesNoAudio() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = TranscriptHistory(url: url)
        await store.record(entry("kayıt"))
        let text = try String(contentsOf: url, encoding: .utf8).lowercased()
        for forbidden in ["audio", "samples", "wav", "pcm", "\"path\""] {
            #expect(!text.contains(forbidden), "the entry contains \(forbidden)")
        }
    }
}

@Suite("Config — the history switches")
struct HistoryConfigTests {

    @Test("it is on by default")
    func defaultsOn() {
        #expect(Config().history)
        #expect(Config().historyLimit == TranscriptHistory.defaultLimit)
    }

    @Test("it can be switched off and its limit changed from config")
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

    @Test("an invalid limit is ignored")
    func rejectsBadLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "yaz-hist-bad-\(UUID().uuidString).json")
        try #"{ "history_limit": 0 }"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Config.load(from: url).historyLimit == TranscriptHistory.defaultLimit)
    }
}

@Suite("ModelDownloader — progress reporting")
struct ModelDownloaderTests {

    typealias P = ModelDownloader.Progress

    @Test("percent is derived from the fraction")
    func percentFromFraction() {
        #expect(P(fraction: 0.0, completedBytes: 0, totalBytes: 100).percent == 0)
        #expect(P(fraction: 0.5, completedBytes: 50, totalBytes: 100).percent == 50)
        #expect(P(fraction: 1.0, completedBytes: 100, totalBytes: 100).percent == 100)
    }

    /// A confident 0% that never moves is worse than saying "size unknown".
    @Test("an unknown total reports no percent")
    func unknownTotalHasNoPercent() {
        let progress = P(fraction: nil, completedBytes: 1024, totalBytes: 0)
        #expect(progress.percent == nil)
        #expect(!progress.description.contains("%"))
    }

    @Test("description names both sides of the download")
    func describesBothSides() {
        let progress = P(fraction: 0.25, completedBytes: 400_000_000, totalBytes: 1_600_000_000)
        #expect(progress.description.contains("of"))
        #expect(progress.description.contains("25%"))
    }

    @Test("byte counts are human readable, not raw")
    func humanReadableBytes() {
        let progress = P(fraction: 0.5, completedBytes: 800_000_000, totalBytes: 1_600_000_000)
        #expect(!progress.description.contains("800000000"))
        #expect(progress.description.uppercased().contains("GB")
            || progress.description.uppercased().contains("MB"))
    }

    @Test("the notice names the model and its size")
    func noticeIsInformative() {
        let notice = ModelDownloader.downloadNotice(for: .largeV3Turbo)
        #expect(notice.contains("large-v3-turbo"))
        #expect(notice.contains("1620"))
        #expect(notice.lowercased().contains("first run"))
    }

    /// Calling it when the weights are present must be free — it runs on every
    /// launch.
    @Test("an already-downloaded model is a no-op")
    func alreadyDownloadedIsNoOp() async throws {
        let status = ModelStore.status(for: WhisperModel.largeV3Turbo.whisperKitID)
        try #require(status.isComplete, "model not present — test skipped")
        let didDownload = try await ModelDownloader.ensure(.largeV3Turbo)
        #expect(!didDownload)
    }
}
