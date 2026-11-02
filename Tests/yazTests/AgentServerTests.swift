import Foundation
import Testing
@testable import yaz

@Suite("yaz mcp — dictation for coding agents")
struct AgentServerTests {

    private static func entry(_ text: String, app: String?, minutesAgo: Double) -> HistoryEntry {
        HistoryEntry(
            date: Date(timeIntervalSinceNow: -minutesAgo * 60), text: text, appName: app,
            seconds: 2, engine: "whisper", model: "large-v3-turbo")
    }

    private static let entries = [
        entry("pull request'i merge ettim", app: "Slack", minutesAgo: 1),
        entry("Toplantı saat 15'te", app: "Mail", minutesAgo: 5),
        entry("getUserById dönüyor", app: "Cursor", minutesAgo: 9),
    ]

    private func server(historyEnabled: Bool = true, directory: URL? = nil) -> AgentServer {
        let dir = directory ?? FileManager.default.temporaryDirectory.appending(path: "yaz-agent-\(UUID())")
        return AgentServer(
            history: { Self.entries }, historyEnabled: historyEnabled,
            handoff: AgentHandoff(directory: dir), pollInterval: 0.05, version: "9.9.9")
    }

    /// `wait_for_dictation` blocks its thread while it waits, as it should in
    /// `yaz mcp`. In tests that would hold a thread of the shared pool and
    /// slow every timing test running beside it, so it gets its own.
    private func callOffPool(
        _ server: AgentServer, _ name: String, _ arguments: [String: Int]
    ) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: call(server, name, arguments))
            }
        }
    }

    private func call(_ server: AgentServer, _ name: String, _ arguments: [String: Any] = [:]) -> (String, Bool) {
        let response = server.handle([
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        let result = response?["result"] as? [String: Any] ?? [:]
        let content = result["content"] as? [[String: Any]] ?? []
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    @Test("initialize answers with tools and the protocol version asked for")
    func initialize() {
        let response = server().handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [String: Any]()],
        ])
        let result = response?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-03-26")
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "yaz")
        #expect(response?["id"] as? Int == 1)
    }

    @Test("an unknown protocol version gets the newest one")
    func unknownVersion() {
        let response = server().handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "1999-01-01"],
        ])
        let result = response?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == AgentServer.supportedProtocols[0])
    }

    @Test("notifications get no answer, unknown methods an error")
    func notifications() {
        #expect(server().handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let response = server().handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
        #expect((response?["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("four tools are listed, each with a schema")
    func toolsList() {
        let response = server().handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(Set(tools.compactMap { $0["name"] as? String })
            == ["wait_for_dictation", "last_dictation", "recent_dictations", "search_dictations"])
        #expect(tools.allSatisfy { $0["inputSchema"] is [String: Any] })
        #expect(JSONSerialization.isValidJSONObject(response!))
    }

    @Test("the last, recent and matching dictations, with their app")
    func reading() {
        let s = server()
        let (last, _) = call(s, "last_dictation")
        #expect(last.contains("pull request'i merge ettim"))
        #expect(last.contains("in Slack"))
        let (recent, _) = call(s, "recent_dictations", ["limit": 2])
        #expect(recent.contains("15'te"))
        #expect(!recent.contains("getUserById"))
        let (found, _) = call(s, "search_dictations", ["query": "cursor"])
        #expect(found.contains("getUserById"))
        let (none, _) = call(s, "search_dictations", ["query": "kubernetes"])
        #expect(none == "Nothing matches.")
    }

    @Test("with history off, nothing is read")
    func historyOff() {
        let (text, isError) = call(server(historyEnabled: false), "last_dictation")
        #expect(isError)
        #expect(text.contains("history is off"))
    }

    @Test("wait_for_dictation returns the next dictation, handed over instead of pasted")
    func waitReturnsReply() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yaz-agent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let handoff = AgentHandoff(directory: dir)
        // The daemon's side, on another thread: answer the wait once it appears.
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if let wait = handoff.pendingWait() {
                    try? handoff.deliver("evet, merge et", to: wait)
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let (text, isError) = await callOffPool(server(directory: dir), "wait_for_dictation",
                                                ["timeout_seconds": 10])
        #expect(!isError)
        #expect(text == "evet, merge et")
        #expect(handoff.pendingWait() == nil)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test("wait_for_dictation gives up after its timeout")
    func waitTimesOut() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yaz-agent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (text, isError) = await callOffPool(server(directory: dir), "wait_for_dictation", ["timeout_seconds": 1])
        #expect(isError)
        #expect(text.contains("no dictation"))
        #expect(AgentHandoff(directory: dir).pendingWait() == nil)
    }

    @Test("a wait past its deadline, or of a dead process, is not answered")
    func staleWait() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yaz-agent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let handoff = AgentHandoff(directory: dir)
        let wait = try handoff.beginWait(timeout: 30, prompt: nil, now: Date(timeIntervalSinceNow: -60))
        #expect(handoff.pendingWait() == nil)
        handoff.end(wait)
        _ = try handoff.beginWait(timeout: 30, prompt: nil)
        #expect(handoff.pendingWait() != nil)
        #expect(!AgentHandoff.isAlive(-1))
    }

    @Test("the hand-off files are private to the user")
    func permissions() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "yaz-agent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try AgentHandoff(directory: dir).beginWait(timeout: 30, prompt: "x")
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "agent-wait.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("the history file is read without the actor, oldest first")
    func historyRead() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "yaz-hist-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for e in Self.entries.reversed() { data += try encoder.encode(e) + Data([0x0A]) }
        data += Data("{broken\n".utf8)
        try data.write(to: url)
        #expect(TranscriptHistory.read(from: url).map(\.text) == Self.entries.reversed().map(\.text))
    }
}
