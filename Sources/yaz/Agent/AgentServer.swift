import Foundation

/// `yaz mcp`: a Model Context Protocol server over stdio, so a coding agent
/// (Claude Code, Cursor, Codex) can read what you dictated and ask you to
/// answer by voice.
///
/// Tools: `last_dictation`, `recent_dictations`, `search_dictations` (from
/// the history, so only while history is on) and `wait_for_dictation`
/// (`AgentHandoff`: your next dictation goes to the agent instead of being
/// pasted). JSON-RPC 2.0, one message per line on stdin and stdout; the
/// agent starts the process, so there is no listener at all.
struct AgentServer {

    /// Where the dictations come from: newest first.
    var history: () -> [HistoryEntry]
    var historyEnabled: Bool
    var handoff: AgentHandoff
    /// How often `wait_for_dictation` looks for the reply.
    var pollInterval: TimeInterval = 0.25
    var version: String = AppEnvironment.version

    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Answer one message, or nil for a notification.
    func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id.map { error($0, code: -32600, "invalid request") }
        }
        guard let id else { return nil }   // notifications need no answer
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedProtocols.contains($0) ? $0 : nil }
                ?? Self.supportedProtocols[0]
            return result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "yaz", "version": self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id, [String: Any]())
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id, call(name, arguments))
        default:
            return error(id, code: -32601, "method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let instructions = """
        yaz is the user's push-to-talk dictation app. Use wait_for_dictation to ask the user a \
        question they can answer by voice: say what you are asking in your message first, then \
        call it; the answer is not pasted anywhere else. The other tools read what the user \
        dictated recently, with the app it went into.
        """

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    static var tools: [[String: Any]] { [
        [
            "name": "wait_for_dictation",
            "description": "Wait for the user's next dictation (they hold the yaz key and speak) and return its text. The dictation is given to you instead of being pasted. Tell the user what you are asking before calling.",
            "inputSchema": schema([
                "timeout_seconds": ["type": "integer", "minimum": 5, "maximum": 300, "description": "How long to wait (default 120)."],
                "prompt": ["type": "string", "description": "A short note shown in yaz's pill while it waits."],
            ]),
        ],
        [
            "name": "last_dictation",
            "description": "The user's most recent dictation, with the app it went into and when.",
            "inputSchema": schema([:]),
        ],
        [
            "name": "recent_dictations",
            "description": "The user's recent dictations, newest first.",
            "inputSchema": schema([
                "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "How many (default 10)."],
            ]),
        ],
        [
            "name": "search_dictations",
            "description": "Search the user's dictation history for text or an app name.",
            "inputSchema": schema([
                "query": ["type": "string"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 50],
            ], required: ["query"]),
        ],
    ] }

    private func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "wait_for_dictation":
            let timeout = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 120
            return waitForDictation(timeout: timeout, prompt: arguments["prompt"] as? String)
        case "last_dictation":
            guard historyEnabled else { return historyOff() }
            guard let entry = history().first else { return text("No dictation yet.") }
            return text(Self.describe(entry))
        case "recent_dictations":
            guard historyEnabled else { return historyOff() }
            let limit = Self.limit(arguments["limit"], default: 10)
            let entries = history().prefix(limit)
            return text(entries.isEmpty ? "No dictation yet." : entries.map(Self.describe).joined(separator: "\n\n"))
        case "search_dictations":
            guard historyEnabled else { return historyOff() }
            let query = PhoneticKey.lowercasedTurkish(arguments["query"] as? String ?? "")
            guard !query.isEmpty else { return failure("query is required") }
            let limit = Self.limit(arguments["limit"], default: 10)
            let found = history().filter {
                PhoneticKey.lowercasedTurkish($0.text).contains(query)
                    || PhoneticKey.lowercasedTurkish($0.appName ?? "").contains(query)
            }.prefix(limit)
            return text(found.isEmpty ? "Nothing matches." : found.map(Self.describe).joined(separator: "\n\n"))
        default:
            return failure("unknown tool: \(name)")
        }
    }

    private func waitForDictation(timeout: TimeInterval, prompt: String?) -> [String: Any] {
        let wait: AgentHandoff.Wait
        do {
            wait = try handoff.beginWait(timeout: timeout, prompt: prompt)
        } catch {
            return failure("could not start waiting: \(error.localizedDescription)")
        }
        defer { handoff.end(wait) }
        while Date() < wait.deadline {
            if let reply = handoff.reply(for: wait) { return text(reply.text) }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if let reply = handoff.reply(for: wait) { return text(reply.text) }
        let seconds = Int(min(max(timeout, 1), AgentHandoff.maxTimeout))
        return failure("no dictation within \(seconds) s. Is yaz running, and did the user hold the key?")
    }

    // MARK: -

    private static func limit(_ value: Any?, default fallback: Int) -> Int {
        min(max((value as? NSNumber)?.intValue ?? fallback, 1), 50)
    }

    static func describe(_ entry: HistoryEntry) -> String {
        let place = entry.appName.map { " in \($0)" } ?? ""
        return "[\(entry.date.ISO8601Format())\(place)]\n\(entry.text)"
    }

    private func historyOff() -> [String: Any] {
        failure("yaz's history is off, so there is nothing to read. wait_for_dictation still works.")
    }

    private func text(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]]]
    }

    private func failure(_ string: String) -> [String: Any] {
        ["content": [["type": "text", "text": string]], "isError": true]
    }

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(_ id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: - stdio

    /// Read messages from stdin until it closes, answering each on stdout.
    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let response: [String: Any]?
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                response = handle(object)
            } else {
                response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]]
            }
            guard let response,
                  let data = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes])
            else { continue }
            FileHandle.standardOutput.write(data + Data([0x0A]))
        }
    }
}
