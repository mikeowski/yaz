import Foundation

/// Where yaz says what it is doing.
///
/// A `.app` launched from Finder has no terminal: its stderr goes nowhere at
/// all. That is fine until something does not work, at which point there is
/// no way to find out why — which is exactly the position this project was in
/// when the hotkey did nothing and the only available evidence was "nothing
/// happens".
///
/// So every line goes to stderr *and* to a file. The CLI keeps its terminal
/// output; the app gets a log a person can actually read.
enum Log {

    /// `~/Library/Logs/yaz.log` — where macOS expects an app's log, and where
    /// Console.app will find it without being told.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/yaz.log")
    }

    /// Rotate past this size. A daemon that runs for months should not leave
    /// an unbounded file behind, and nobody reads the first megabyte anyway.
    private static let maxBytes: UInt64 = 512 * 1024

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handle: FileHandle?
    private nonisolated(unsafe) static var openAttempted = false

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func write(_ message: String) {
        let line = message + "\n"
        FileHandle.standardError.write(Data(line.utf8))

        lock.lock()
        defer { lock.unlock() }

        if !openAttempted {
            openAttempted = true
            handle = openFile()
        }
        guard let handle else { return }

        let stamped = "\(timestamp.string(from: Date()))  \(message)\n"
        try? handle.write(contentsOf: Data(stamped.utf8))
        rotateIfNeeded()
    }

    /// Read the tail of the log, for `yaz logs`.
    static func tail(lines: Int) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return Array(all.suffix(lines + 1).dropLast(all.last?.isEmpty == true ? 1 : 0))
    }

    // MARK: -

    private static func openFile() -> FileHandle? {
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        try? handle.seekToEnd()
        return handle
    }

    private static func rotateIfNeeded() {
        guard
            let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]
                as? UInt64,
            size > maxBytes
        else { return }

        try? handle?.close()
        handle = nil
        // One generation back is enough: the interesting part of a log is
        // always the end.
        let previous = fileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: fileURL, to: previous)
        handle = openFile()
    }
}

/// Shorthand used everywhere in the project.
func log(_ message: String) {
    Log.write(message)
}
