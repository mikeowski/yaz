import AppKit
import Foundation

/// How yaz was started, and what that implies.
///
/// The same binary is both a CLI and a menu-bar app. The difference matters
/// most for permissions: macOS attributes an Accessibility grant to the
/// **responsible process**, which for a command run in a terminal is the
/// terminal application — not yaz. A real chain observed on this machine:
///
/// ```
/// cmux.app → login → fish → claude → zsh → yaz
/// ```
///
/// The prompt named `cmux.app`, granting it did not help the already-running
/// shells, and nothing about that is fixable from inside the CLI. Launched as
/// `yaz.app`, yaz *is* the responsible process: the prompt says "yaz", and the
/// grant survives whatever terminal happens to be open.
enum AppEnvironment {

    /// True when running from inside a `.app` bundle.
    static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Version from the bundle, or a build-time default for the CLI.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2.0"
    }

    /// Where user data lives. `Application Support` rather than `~/.config`
    /// for anything the app writes itself, so a sandboxed or bundled future
    /// does not have to move it.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support")
        return base.appending(path: "yaz")
    }

    static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
    }

    /// The app the user is dictating into, for the history record.
    ///
    /// Read at the moment of insertion: by the time a transcript exists the
    /// frontmost app is still the one the cursor is in, because the overlay is
    /// a non-activating panel and never takes focus.
    @MainActor
    static func frontmostApp() -> (name: String, bundleID: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? app.bundleIdentifier ?? "bilinmeyen"
        return (name, app.bundleIdentifier)
    }
}
