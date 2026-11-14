import Foundation
import Testing

@testable import yaz

@Suite("DataFile — an unreadable file is kept, never written over")
struct DataFileTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yaz-datafile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func broken(in dir: URL, name: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(name).broken-") }
    }

    @Test("saving over a config that does not parse keeps the old file")
    func configTypo() throws {
        let dir = try scratch()
        let url = dir.appending(path: "config.json")
        let typo = #"{ "vocabulary": ["Slack", "Notion",], "language": "tr" "#
        try typo.write(to: url, atomically: true, encoding: .utf8)

        let loaded = Config.load(from: url)
        try loaded.save(to: url)

        let kept = try broken(in: dir, name: "config.json")
        #expect(kept.count == 1)
        #expect(try String(contentsOf: kept[0], encoding: .utf8) == typo)
        #expect(Config.load(from: url).language == Config().language)
    }

    @Test("saving over a config that parses keeps no copy")
    func configFine() throws {
        let dir = try scratch()
        let url = dir.appending(path: "config.json")
        try Config().save(to: url)
        try Config().save(to: url)
        #expect(try broken(in: dir, name: "config.json").isEmpty)
    }

    @Test("an unreadable learned.json is moved aside, and loads as empty")
    func learnedCorrupt() throws {
        let dir = try scratch()
        let url = dir.appending(path: "learned.json")
        try #"{"rules": [{"heard": "#.write(to: url, atomically: true, encoding: .utf8)

        let rules = LearnedRules.load(from: url)
        #expect(rules == LearnedRules())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try broken(in: dir, name: "learned.json").count == 1)
    }

    @Test("an unreadable personal.json is moved aside, and loads as empty")
    func personalCorrupt() throws {
        let dir = try scratch()
        let url = dir.appending(path: "personal.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        #expect(PersonalCorpus.load(from: url).isEmpty)
        #expect(try broken(in: dir, name: "personal.json").count == 1)
    }

    @Test("a missing file is not an unreadable one")
    func missing() throws {
        let dir = try scratch()
        #expect(LearnedRules.load(from: dir.appending(path: "learned.json")) == LearnedRules())
        #expect(try broken(in: dir, name: "learned.json").isEmpty)
    }

    @Test("a learned rule forgotten on disk is what the next load sees")
    func forgetOnDisk() throws {
        let dir = try scratch()
        let url = dir.appending(path: "learned.json")
        var rules = LearnedRules()
        rules.learn(heard: "Sılacık", meant: "Slack", at: Date())
        try rules.save(to: url)

        var onDisk = LearnedRules.load(from: url)
        onDisk.forget(term: "Slack")
        try onDisk.save(to: url)

        #expect(LearnedRules.load(from: url).rules.isEmpty)
    }
}

@Suite("FieldReader — a slow app cannot hold the read-back")
struct FieldReaderTimeoutTests {
    @Test("the Accessibility timeout is well under a second")
    func timeout() {
        #expect(FieldReader.timeout <= 0.5)
    }
}
