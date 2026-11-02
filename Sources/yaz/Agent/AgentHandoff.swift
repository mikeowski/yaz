import Darwin
import Foundation

/// A dictation handed to a waiting coding agent instead of being pasted.
///
/// `yaz mcp`'s `wait_for_dictation` tool writes a wait file; while it is
/// fresh (deadline ahead, the waiting process alive), the daemon writes the
/// next dictation to a reply file and pastes nothing, so the answer does not
/// also land in the agent's input box. Two small files in yaz's support
/// folder, mode 0600: no socket, no port, nothing another machine can reach.
struct AgentHandoff: Sendable {

    struct Wait: Codable, Sendable, Equatable {
        let id: String
        let pid: Int32
        let deadline: Date
        /// What the agent asked, shown in the pill while waiting.
        let prompt: String?
    }

    struct Reply: Codable, Sendable, Equatable {
        let id: String
        let text: String
        let date: Date
    }

    let directory: URL

    static let standard = AgentHandoff(directory: AppEnvironment.supportDirectory)
    static let maxTimeout: TimeInterval = 300

    private var waitURL: URL { directory.appending(path: "agent-wait.json") }
    private func replyURL(_ id: String) -> URL { directory.appending(path: "agent-reply-\(id).json") }

    // MARK: - The agent's side

    func beginWait(timeout: TimeInterval, prompt: String?, now: Date = Date()) throws -> Wait {
        let wait = Wait(
            id: UUID().uuidString, pid: getpid(),
            deadline: now.addingTimeInterval(min(max(timeout, 1), Self.maxTimeout)),
            prompt: prompt.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) })
        try write(wait, to: waitURL)
        return wait
    }

    func reply(for wait: Wait) -> Reply? {
        guard let data = try? Data(contentsOf: replyURL(wait.id)),
              let reply = try? Self.decoder.decode(Reply.self, from: data), reply.id == wait.id
        else { return nil }
        return reply
    }

    /// Remove the wait and its reply. Only this wait's: a newer one stays.
    func end(_ wait: Wait) {
        try? FileManager.default.removeItem(at: replyURL(wait.id))
        if let current = currentWait(), current.id == wait.id {
            try? FileManager.default.removeItem(at: waitURL)
        }
    }

    // MARK: - The daemon's side

    /// The wait to answer, if one is fresh.
    func pendingWait(now: Date = Date()) -> Wait? {
        guard let wait = currentWait(), wait.deadline > now, Self.isAlive(wait.pid) else { return nil }
        return wait
    }

    func deliver(_ text: String, to wait: Wait, now: Date = Date()) throws {
        try write(Reply(id: wait.id, text: text, date: now), to: replyURL(wait.id))
        try? FileManager.default.removeItem(at: waitURL)
    }

    // MARK: -

    private func currentWait() -> Wait? {
        guard let data = try? Data(contentsOf: waitURL) else { return nil }
        return try? Self.decoder.decode(Wait.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
