import Foundation

/// One dictation, as recorded.
struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    /// When the transcript was produced.
    var date: Date
    /// The text that was inserted, after vocabulary and refinement.
    var text: String
    /// The app the cursor was in.
    var appName: String?
    var appBundleID: String?
    /// Seconds of speech.
    var seconds: Double
    /// Which engine and model produced it, so a change in accuracy can be
    /// traced to a change in configuration.
    var engine: String
    var model: String
    /// Terms the vocabulary layer repaired, as `from → to`.
    var corrections: [String]

    init(
        id: String = UUID().uuidString,
        date: Date,
        text: String,
        appName: String? = nil,
        appBundleID: String? = nil,
        seconds: Double,
        engine: String,
        model: String,
        corrections: [String] = []
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.appName = appName
        self.appBundleID = appBundleID
        self.seconds = seconds
        self.engine = engine
        self.model = model
        self.corrections = corrections
    }
}

/// An append-only log of what was dictated, where.
///
/// Text only — no audio. Keeping the recordings would make yaz a surveillance
/// tool by accident: a folder of everything its owner has said, sitting on
/// disk indefinitely. The transcript is what has any later use (finding a
/// paragraph you dictated last week), and it is a far smaller thing to leak.
///
/// JSONL rather than a database: one line per dictation, appended, readable
/// with `tail`, and a corrupt line costs one entry instead of the file.
actor TranscriptHistory {

    /// Entries kept. Old ones are dropped from the front when the file is
    /// rewritten, so the log cannot grow without limit on a machine that is
    /// dictated into all day.
    static let defaultLimit = 2000

    private let url: URL
    private let limit: Int
    private let enabled: Bool

    init(url: URL? = nil, limit: Int = TranscriptHistory.defaultLimit, enabled: Bool = true) {
        self.url = url ?? AppEnvironment.supportDirectory.appending(path: "history.jsonl")
        self.limit = max(1, limit)
        self.enabled = enabled
    }

    var fileURL: URL { url }

    /// Append one entry. Failure is logged, never thrown: losing a history
    /// line must not cost the user the dictation that produced it.
    func record(_ entry: HistoryEntry) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let line = try Self.encoder.encode(entry)
            var data = line
            data.append(0x0A)  // newline

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }

            try trimIfNeeded()
        } catch {
            log("couldn't write history: \(error)")
        }
    }

    /// Read entries, newest first.
    func entries(limit: Int? = nil, matching query: String? = nil) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var found: [HistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A truncated final line — the usual result of a crash mid-append —
            // costs one entry, not the file.
            guard let entry = try? Self.decoder.decode(
                HistoryEntry.self, from: Data(line.utf8)
            ) else { continue }
            found.append(entry)
        }

        if let query, !query.isEmpty {
            let needle = PhoneticKey.lowercasedTurkish(query)
            found = found.filter {
                PhoneticKey.lowercasedTurkish($0.text).contains(needle)
                    || PhoneticKey.lowercasedTurkish($0.appName ?? "").contains(needle)
            }
        }

        found.reverse()
        if let limit { found = Array(found.prefix(limit)) }
        return found
    }

    func count() -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    /// Delete everything. The user's own record is theirs to destroy.
    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: -

    /// Rewrite the file keeping only the newest `limit` lines.
    private func trimIfNeeded() throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > limit else { return }

        let kept = lines.suffix(limit).joined(separator: "\n") + "\n"
        try Data(kept.utf8).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // One line per entry: pretty-printing would break the format.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
