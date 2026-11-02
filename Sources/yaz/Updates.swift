import AppKit
import ArgumentParser
import Foundation
@_weakLinked @preconcurrency import Sparkle

/// Automatic updates through Sparkle, for the `.app` only.
///
/// The updater checks the signed appcast at yaz.mike4.dev in the background
/// and offers new versions. It stays off in three cases, so they never touch
/// Sparkle at all:
///
/// - **The CLI.** `scripts/install.sh` installs the bare binary, with no
///   Sparkle.framework next to it. The framework is weak-linked, so the binary
///   still starts, but every Sparkle symbol is missing.
/// - **A bundle without the framework** — a hand-made build, for example.
/// - **A bundle without a feed or a key.** Sparkle refuses an update it cannot
///   verify, and it reports a missing key as an error to the user.
///
/// yaz lives in the menu bar and the user is usually typing into another app,
/// so a background check never opens a window over their work. It puts an
/// item in the menu instead ("gentle reminders", as Kare does).
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {

    static let shared = Updates()

    /// A version is waiting (its version string), or nothing is (`nil`).
    var onAvailable: ((String?) -> Void)?

    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        guard Self.canUpdate else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Whether this process may use Sparkle. Checked before any Sparkle
    /// symbol is touched.
    nonisolated static var canUpdate: Bool {
        guard AppEnvironment.isBundledApp else { return false }
        // The class is nil when the weak-linked framework did not load.
        guard NSClassFromString("SPUStandardUpdaterController") != nil else { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var isAvailable: Bool { controller != nil }

    /// Menu bar → Check for Updates…
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - Gentle reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show a background find only if yaz is already in front,
    /// which for a menu bar app is almost never.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            log("update available: yaz \(version)")
            self.onAvailable?(version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.onAvailable?(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.onAvailable?(nil) }
    }
}

/// `yaz updates`: whether this copy can update itself, and from where.
///
/// `scripts/release.sh` runs it on the finished bundle and refuses to publish
/// a build that cannot update — a release without a working updater strands
/// everyone who installs it on that version.
struct UpdatesStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updates",
        abstract: "Show whether this copy of yaz can update itself.")

    @Flag(name: .long, help: "Exit with an error unless automatic updates work.")
    var require = false

    func run() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        let loaded = NSClassFromString("SPUStandardUpdaterController") != nil
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? AppEnvironment.version
        let build = info["CFBundleVersion"] as? String ?? "?"

        print("version: \(version) (\(build))")
        print("bundled: \(AppEnvironment.isBundledApp ? "yes — \(Bundle.main.bundlePath)" : "no (CLI)")")
        print("sparkle: \(loaded ? "loaded" : "not loaded")")
        print("feed:    \(feed.isEmpty ? "none" : feed)")
        print("key:     \(key.isEmpty ? "none" : key)")
        print("updates: \(Updates.canUpdate ? "on" : "off")")

        if require && !Updates.canUpdate { throw ExitCode(1) }
    }
}
