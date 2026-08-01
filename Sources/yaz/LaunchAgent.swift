import Foundation

/// Registers yaz to start at login, as a plain LaunchAgent.
///
/// Not `SMAppService`: that wants a real `.app` bundle, and yaz is a single
/// binary in `/usr/local/bin`. A `launchd` plist is the honest mechanism for
/// what this actually is.
///
/// The plist-building half is deliberately free of filesystem and `launchctl`
/// calls so it can be asserted on directly — a daemon that fails to start at
/// login gives the user nothing to debug with.
enum LaunchAgent {

    /// Matches `CFBundleIdentifier` in the embedded Info.plist, so the launchd
    /// job and the TCC identity refer to the same thing.
    static let label = "com.mikeowski.yaz"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static let standardOutPath = "/tmp/yaz.out.log"
    static let standardErrorPath = "/tmp/yaz.err.log"

    // MARK: - Plist

    /// The launchd job description.
    ///
    /// `KeepAlive` is conditional on a *failed* exit: quitting from the menu
    /// bar is a clean exit and must stay quit, while a crash should be
    /// restarted. An unconditional `KeepAlive` makes the menu's Quit item lie.
    ///
    /// `ProcessType: Interactive` keeps launchd from throttling a process the
    /// user is actively waiting on — dictation latency is the product.
    static func job(binary: String, arguments: [String] = ["run"]) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [binary] + arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": standardOutPath,
            "StandardErrorPath": standardErrorPath,
            // launchd hands a bare environment to login agents; without this,
            // anything yaz shells out to (the `on_transcript` hook) sees no PATH.
            "EnvironmentVariables": [
                "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ] as [String: String],
        ]
    }

    static func plistData(binary: String, arguments: [String] = ["run"]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: job(binary: binary, arguments: arguments),
            format: .xml,
            options: 0)
    }

    // MARK: - State

    struct Status: Sendable, Equatable {
        var isInstalled: Bool
        /// Path the installed job points at, if any.
        var binaryPath: String?
        /// True when the plist exists but its binary does not — what you get
        /// after moving or deleting the executable, and a silent failure
        /// otherwise.
        var isStale: Bool
    }

    static func status() -> Status {
        let url = plistURL
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String],
            let binary = arguments.first
        else {
            return Status(isInstalled: false, binaryPath: nil, isStale: false)
        }
        return Status(
            isInstalled: true,
            binaryPath: binary,
            isStale: !FileManager.default.isExecutableFile(atPath: binary))
    }

    // MARK: - Install / remove

    static func install(binary: URL) throws {
        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plistData(binary: binary.path).write(to: url, options: .atomic)

        // bootout first so a re-install replaces a running job rather than
        // failing with "service already loaded".
        _ = launchctl(["bootout", domain, url.path])
        let result = launchctl(["bootstrap", domain, url.path])
        if result.status != 0 {
            throw YazError.launchAgentFailed(
                action: "bootstrap",
                detail: result.error.isEmpty ? "çıkış kodu \(result.status)" : result.error)
        }
    }

    static func remove() throws {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = launchctl(["bootout", domain, url.path])
        try FileManager.default.removeItem(at: url)
    }

    /// Where the currently running executable lives, resolving symlinks so the
    /// job records a path that survives a `brew`-style relink.
    static func currentBinary() -> URL? {
        let path = CommandLine.arguments.first ?? ""
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    // MARK: -

    private static var domain: String { "gui/\(getuid())" }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        guard (try? process.run()) != nil else { return (-1, "launchctl çalıştırılamadı") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, message)
    }
}
