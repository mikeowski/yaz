import AppKit
import ArgumentParser
import FluidAudio
import Foundation

@main
struct Yaz: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yaz",
        abstract: "On-device dictation for macOS. Hold the key, speak, release — the text lands at your cursor.",
        version: AppEnvironment.version,
        subcommands: [Run.self, Settings.self, Doctor.self, ResetPermissions.self, Logs.self, History.self, Install.self, Transcribe.self, Models.self, Vocab.self, Preview.self, UpdatesStatus.self, Microphones.self, Projects.self],
        defaultSubcommand: Run.self
    )
}

/// Run the dictation daemon.
///
/// Deliberately **synchronous**, unlike every other subcommand.
///
/// `NSApplication.run()` never returns. Called from inside an
/// `AsyncParsableCommand`, it blocks the main thread while that thread is the
/// MainActor's executor — so every `MainActor.run` and `DispatchQueue.main`
/// block enqueued afterwards waits forever. Measured: CFRunLoop timers fired
/// normally while the GCD main queue was never drained once, which is why the
/// model-ready callback never ran and `ready` stayed false.
///
/// A plain `ParsableCommand` hands the main thread to AppKit without a Swift
/// concurrency task owning it, and both mechanisms work again.
struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the dictation daemon (default)."
    )

    @Option(name: .long, help: "Push-to-talk key: fn, right-option, right-command, right-control, right-shift.")
    var hotkey: Hotkey?

    @Option(name: .long, help: "Text insertion: paste or type.")
    var injectMode: TextInjector.Mode?

    @Option(name: .long, help: "Language code.")
    var language: String?

    @Flag(name: .long, help: "Skip the startup checks.")
    var skipDoctor = false

    @Flag(name: .long, help: "Verbose logging.")
    var verbose = false

    func run() throws {
        var config = Config.load()
        // CLI flags win over the config file — the usual precedence, and it
        // lets a LaunchAgent-managed daemon be overridden for one run.
        if let hotkey { config.hotkey = hotkey }
        if let injectMode { config.injectMode = injectMode }
        if let language { config.language = language }

        // A bundled app handles its own permission flow: it prompts as yaz and
        // waits. Exiting here would mean double-clicking the icon does nothing.
        if !skipDoctor && !AppEnvironment.isBundledApp {
            let checks = DoctorReport.run(config: config)
            guard DoctorReport.canRun(checks) else {
                log("startup checks failed:")
                DoctorReport.render(checks, toStandardError: true)
                log("fix the above, or pass --skip-doctor")
                throw ExitCode(1)
            }
        }

        // Strong reference for the life of the process.
        //
        // `Daemon(...).run()` alone is not enough: ARC may release a temporary
        // after its last *use*, and `self` is never touched again once
        // `app.run()` starts spinning. The daemon was being deallocated the
        // moment the run loop began — `deinit` pulled the status item back out
        // of the menu bar and the `[weak self]` model-loading task found nil.
        // The app ran, showed nothing, and did nothing.
        // ArgumentParser calls a synchronous run() on the main thread.
        try MainActor.assumeIsolated {
            let daemon = Daemon(config: config, verbose: verbose)
            DaemonHolder.live = daemon
            try daemon.run()
        }
    }
}

/// Keeps the running daemon alive for the life of the process.
///
/// See the comment in `Run.run()`: without a strong reference held somewhere
/// that outlives the call, ARC deallocates the daemon as soon as `app.run()`
/// stops touching `self`.
@MainActor
enum DaemonHolder {
    static var live: Daemon?
}

/// Report on permissions, models, and settings.
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions, model and settings."
    )

    @Flag(name: .long, help: "Open the system prompt for any missing permission.")
    var request = false

    func run() throws {
        try runBlocking {
            let config = Config.load()
            print("config: \(FileManager.default.fileExists(atPath: Config.path.path) ? Config.path.path : "defaults (no config file)")")
            print("engine: \(config.engine.rawValue) · language: \(config.language) · hotkey: \(config.hotkey.displayName)")
            print("vocabulary: \(config.vocabulary.count) terms · post-processing: \(config.refine.displayName)")
            print()

            let checks = DoctorReport.run(config: config)
            DoctorReport.render(checks)

            if request && !HotkeyMonitor.hasAccessibilityPermission {
                print("\nrequesting accessibility permission…")
                HotkeyMonitor.requestAccessibilityPermission()
            }
            if !DoctorReport.canRun(checks) { throw ExitCode(1) }
        }
    }
}

/// Download and inspect models.
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List and download models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            try runBlocking {
                for model in WhisperModel.allCases {
                    let status = ModelStore.status(for: model.whisperKitID)
                    let mark = status.isComplete ? "✓" : (status.sizeBytes > 0 ? "!" : " ")
                    let detail = status.isComplete
                        ? status.sizeDescription
                        : (status.sizeBytes > 0 ? "partial (\(status.sizeDescription))" : "not downloaded")
                    print("\(mark) whisper/\(model.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) ~\(model.sizeMB) MB  \(detail)")
                }
                let parakeet = ParakeetTranscriber(version: .v3)
                print("\(parakeet.isDownloaded ? "✓" : " ") parakeet/tdt-0.6b-v3    ~600 MB  (NO Turkish)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Option(name: .long, help: "Whisper model.")
        var whisperModel: WhisperModel = .largeV3Turbo

        @Flag(name: .long, help: "Delete a partial download and fetch it again.")
        var force = false

        func run() throws {
            try runBlocking {
                if force {
                    let directory = ModelStore.directory(for: whisperModel.whisperKitID)
                    if FileManager.default.fileExists(atPath: directory.path) {
                        log("removing: \(directory.path)")
                        try FileManager.default.removeItem(at: directory)
                    }
                }
                let started = Date()
                log(ModelDownloader.downloadNotice(for: whisperModel))

                let downloaded = try await ModelDownloader.ensure(whisperModel) { progress in
                    // Overwrite one line rather than scrolling: a 1.6 GB download
                    // emits thousands of callbacks.
                    FileHandle.standardError.write(
                        Data("\r  \(progress.description)          ".utf8))
                }
                if downloaded { FileHandle.standardError.write(Data("\n".utf8)) }
                else { log("already downloaded") }

                // Load once so Core ML compiles now rather than on the first
                // utterance, which is where the minutes actually go.
                log("compiling for the Neural Engine…")
                let engine = WhisperTranscriber(model: whisperModel)
                try await engine.prepare()
                await engine.release()

                let status = ModelStore.status(for: whisperModel.whisperKitID)
                log(String(format: "✓ ready — %.0f s · %@", Date().timeIntervalSince(started), status.sizeDescription))
            }
        }
    }
}

/// Open the settings or history window without going through the menu bar.
///
/// The windows are otherwise reachable only by clicking a menu item, which
/// means they cannot be exercised except by hand. This command opens them
/// directly — useful when the daemon is not running, and the only way to
/// verify the SwiftUI paths actually run rather than merely compile.
struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the settings window."
    )

    @Flag(name: .long, help: "Open the history window instead of settings.")
    var history = false

    @Option(name: .long, help: "Quit automatically after this many seconds (for testing).")
    var autoQuit: Double?

    func run() throws {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let controller = SettingsWindowController()
            if history { controller.showHistory() } else { controller.showSettings() }

            if let autoQuit {
                Timer.scheduledTimer(withTimeInterval: autoQuit, repeats: false) { _ in
                    log("auto-quit")
                    NSApp.terminate(nil)
                }
            }
            app.run()
        }
    }
}

/// Clear yaz's permission records so macOS asks again.
///
/// Needed more often than it should be. Replacing an app bundle can leave TCC
/// holding a record that no longer matches the binary: the system reports the
/// permission as granted, the app believes it, and events are silently never
/// delivered. Measured here — `accessibility=true inputMonitoring=granted`
/// with a live tap and zero events, until the records were reset.
struct ResetPermissions: ParsableCommand {
    static let configuration = CommandName.reset

    enum CommandName {
        static let reset = CommandConfiguration(
            commandName: "reset-permissions",
            abstract: "Clear yaz's permission records so macOS prompts again.")
    }

    @Flag(name: .long, help: "Show what would be reset without doing it.")
    var dryRun = false

    func run() throws {
        try runBlocking {
            let services = ["Accessibility", "ListenEvent", "Microphone"]
            let bundleID = LaunchAgent.label

            print("resetting permissions for \(bundleID)")
            if dryRun {
                for service in services { print("  would reset: \(service)") }
                return
            }

            for service in services {
                let result = Self.tccutil(["reset", service, bundleID])
                print(result.status == 0
                    ? "  ✓ \(service)"
                    : "  ✗ \(service) — \(result.output)")
            }

            print("")
            print("now quit and reopen yaz; macOS will ask for both permissions again.")
            print("  Accessibility     — lets yaz paste at your cursor")
            print("  Input Monitoring  — lets yaz see the push-to-talk key")
        }
    }

    private static func tccutil(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "couldn't run tccutil") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// Show what the app has been doing.
///
/// Exists because a `.app` launched from Finder has no terminal: its stderr
/// goes nowhere, so when the hotkey did nothing there was no evidence at all
/// to work from.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the app log (~/Library/Logs/yaz.log)."
    )

    @Option(name: .long, help: "How many lines to show.")
    var lines: Int = 40

    @Flag(name: .long, help: "Follow the log as it grows.")
    var follow = false

    func run() throws {
        try runBlocking {
            let recent = Log.tail(lines: lines)
            if recent.isEmpty {
                print("log is empty — \(Log.fileURL.path)")
                print("  (the app writes here as soon as it runs)")
                return
            }
            for line in recent { print(line) }

            guard follow else { return }
            var seen = recent.count
            while true {
                try await Task.sleep(for: .milliseconds(400))
                let all = Log.tail(lines: 10_000)
                if all.count > seen {
                    for line in all[seen...] { print(line) }
                    seen = all.count
                }
            }
        }
    }
}

/// Read back what was dictated.
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the dictation history (text only — no audio is stored)."
    )

    @Option(name: .long, help: "How many entries to show.")
    var limit: Int = 20

    @Option(name: .long, help: "Search the text or the app name.")
    var search: String?

    @Flag(name: .long, help: "Dump full records as JSON.")
    var json = false

    @Flag(name: .long, help: "Delete the entire history.")
    var clear = false

    func run() throws {
        try runBlocking {
            let config = Config.load()
            let store = TranscriptHistory(limit: config.historyLimit, enabled: config.history)

            if clear {
                let total = await store.count()
                await store.clear()
                print("✓ deleted \(total) entries")
                return
            }

            let entries = await store.entries(limit: limit, matching: search)
            guard !entries.isEmpty else {
                let total = await store.count()
                if total == 0 {
                    print("history is empty")
                    if !config.history { print("  (\"history\": false in the config)") }
                } else {
                    print("no matches (across \(total) entries)")
                }
                return
            }

            if json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(entries)
                print(String(decoding: data, as: UTF8.self))
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM HH:mm"
            for entry in entries {
                let stamp = formatter.string(from: entry.date)
                let target = entry.appName.map { " · \($0)" } ?? ""
                print("\(stamp)\(target)  (\(String(format: "%.1f", entry.seconds)) sn)")
                print("  \(entry.text)")
                if !entry.corrections.isEmpty {
                    print("  vocabulary: \(entry.corrections.joined(separator: ", "))")
                }
                print()
            }
            let total = await store.count()
            print("— \(entries.count) of \(total) entries")
        }
    }
}

/// Register or remove the login item.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Enable or disable launching at login."
    )

    @Flag(name: .long, help: "Register to start at login.")
    var launchAtLogin = false

    @Flag(name: .long, help: "Remove the registration.")
    var uninstall = false

    @Flag(name: .long, help: "Only report the status.")
    var status = false

    func run() throws {
        try runBlocking {
            if status || (!launchAtLogin && !uninstall) {
                report()
                return
            }
            guard launchAtLogin != uninstall else {
                throw ValidationError("pass exactly one of --launch-at-login or --uninstall")
            }

            if uninstall {
                try LaunchAgent.remove()
                print("✓ launch at login removed")
                return
            }

            guard let binary = LaunchAgent.currentBinary() else {
                throw ValidationError("couldn't resolve the path of the running binary")
            }
            // A LaunchAgent pointing into a build directory breaks the moment the
            // tree is cleaned, and the failure is silent — say so now.
            if binary.path.contains("/.build/") {
                log("warning: \(binary.path) is a build directory —")
                log("         copy it to /usr/local/bin first and run it from there")
            }

            try LaunchAgent.install(binary: binary)
            print("✓ launch at login installed")
            print("  binary: \(binary.path)")
            print("  log   : \(LaunchAgent.standardErrorPath)")
        }
    }

    private func report() {
        let state = LaunchAgent.status()
        if !state.isInstalled {
            print("launch at login: not installed")
            print("  → yaz install --launch-at-login")
            return
        }
        print("launch at login: installed")
        print("  binary: \(state.binaryPath ?? "?")")
        print("  plist : \(LaunchAgent.plistURL.path)")
        if state.isStale {
            print("  ✗ the registered binary is missing — refresh with: yaz install --launch-at-login")
        }
    }
}

/// Show the recording indicator without a microphone or a hotkey.
///
/// The overlay and the menu bar are the only parts of yaz that cannot be
/// reached from a test: they need a run loop, a screen, and — via the daemon —
/// an Accessibility grant. This command drives them directly, so the AppKit
/// and SwiftUI paths get exercised rather than merely compiled.
struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the recording indicator on screen (no microphone needed)."
    )

    @Option(name: .long, help: "Seconds each state stays on screen.")
    var dwell: Double = 1.6

    @Option(name: .long, help: "Render the menu bar icon to this PNG and exit (design review).")
    var renderIcon: String?

    @Option(name: .long, help: "Render the app icon to this PNG and exit (design review).")
    var renderAppIcon: String?

    @Option(name: .long, help: "Write a complete .iconset directory (used by the bundle script).")
    var writeIconset: String?

    func run() throws {
        // Already on the main thread: a sync ParsableCommand runs there, and
        // these paths need AppKit plus a run loop. Bridging through
        // `runBlocking` would deadlock — the main thread would sit on the
        // semaphore while the work waited for the MainActor it was blocking.
        try MainActor.assumeIsolated {
            if let renderIcon { return try Self.writeIconSheet(to: renderIcon) }
            if let renderAppIcon { return try Self.writeAppIcon(to: renderAppIcon) }
            if let writeIconset { return try Self.writeIconset(to: writeIconset) }
            try runPreview()
        }
    }

    /// Render every icon state onto one sheet, scaled up, so the drawing can be
    /// looked at rather than assumed. A menu bar mark is 18 pt; judging it from
    /// source is guessing.
    @MainActor
    static func writeIconSheet(to path: String) throws {
        let states: [IndicatorState] = [.idle, .recording, .transcribing, .refining]
        let scale: CGFloat = 8
        let cell = StatusIcon.size.width * scale
        let sheet = NSImage(
            size: NSSize(width: cell * CGFloat(states.count), height: cell + 52))

        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, state) in states.enumerated() {
            let icon = StatusIcon.image(for: state)
            let x = cell * CGFloat(index)
            icon.draw(
                in: NSRect(x: x, y: 44, width: cell, height: cell),
                from: .zero, operation: .sourceOver, fraction: 1)
            // Actual size, 1× and 2×: if the mark is illegible at 18 pt, it
            // looking good when enlarged means nothing.
            icon.draw(in: NSRect(x: x + 24, y: 16, width: 18, height: 18),
                      from: .zero, operation: .sourceOver, fraction: 1)
            icon.draw(in: NSRect(x: x + 56, y: 10, width: 36, height: 36),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
        sheet.unlockFocus()

        guard
            let tiff = sheet.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { throw ValidationError("couldn't render the icon") }

        try png.write(to: URL(fileURLWithPath: path))
        log("wrote \(path) — idle, recording, transcribing, refining")
    }

    /// Render the app icon at several sizes onto one sheet. A 1024 pt icon
    /// that falls apart at 32 pt in the Finder is not finished.
    @MainActor
    static func writeAppIcon(to path: String) throws {
        let sizes: [CGFloat] = [512, 128, 64, 32, 16]
        let gap: CGFloat = 24
        let width = sizes.reduce(0, +) + gap * CGFloat(sizes.count + 1)
        let height = sizes[0] + gap * 2

        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()

        var x = gap
        for size in sizes {
            let icon = AppIcon.image(size: size)
            icon.draw(
                in: NSRect(x: x, y: gap, width: size, height: size),
                from: .zero, operation: .sourceOver, fraction: 1)
            x += size + gap
        }
        sheet.unlockFocus()

        guard
            let tiff = sheet.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { throw ValidationError("couldn't render the icon") }

        try png.write(to: URL(fileURLWithPath: path))
        log("wrote \(path) — 512, 128, 64, 32, 16 pt")
    }

    /// Write every PNG `iconutil` expects, so the bundle script can turn the
    /// drawn icon into an `.icns` without an asset catalogue in the repo.
    @MainActor
    static func writeIconset(to path: String) throws {
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The exact set `iconutil` requires; a missing size makes it refuse
        // the whole directory.
        let variants: [(name: String, points: CGFloat, scale: CGFloat)] = [
            ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
            ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
            ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
            ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
            ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
        ]

        for variant in variants {
            let pixels = Int(variant.points * variant.scale)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { throw ValidationError("couldn't allocate \(pixels)px bitmap") }

            // Draw at the real pixel size rather than scaling one big render:
            // the geometry is proportional, so a 16px icon gets strokes sized
            // for 16px instead of a shrunken 1024px one.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            AppIcon.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
            NSGraphicsContext.restoreGraphicsState()

            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw ValidationError("couldn't encode \(variant.name)")
            }
            try png.write(to: directory.appending(path: "\(variant.name).png"))
        }
        log("wrote \(variants.count) PNGs to \(path)")
    }

    @MainActor private func runPreview() throws {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let config = Config.load()
            let overlay = RecordingOverlay()
            let menuBar = config.menuBar
                ? MenuBarController(summary: "preview")
                : nil

            log("indicator preview — look at the bottom of the screen and at the menu bar")

            let states: [IndicatorState] = [.recording, .transcribing, .refining]
            var elapsed: Double = 0

            for state in states {
                Timer.scheduledTimer(withTimeInterval: elapsed, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        log("  \(state.label)")
                        overlay.show(state)
                        menuBar?.update(state)
                    }
                }
                // Feed the waveform only while the recording state is up, so
                // the meter is exercised with real-looking values.
                if state == .recording {
                    let start = elapsed
                    for tick in stride(from: 0.0, to: dwell, by: 0.05) {
                        Timer.scheduledTimer(withTimeInterval: start + tick, repeats: false) { _ in
                            let phase = Float(tick) * 6
                            overlay.pushLevel(0.05 + 0.3 * abs(sin(phase)))
                        }
                    }
                }
                elapsed += dwell
            }

            Timer.scheduledTimer(withTimeInterval: elapsed, repeats: false) { _ in
                MainActor.assumeIsolated {
                    overlay.hide()
                    menuBar?.update(.idle)
                }
            }
            Timer.scheduledTimer(withTimeInterval: elapsed + 0.8, repeats: false) { _ in
                log("preview finished")
                NSApp.terminate(nil)
            }

            app.run()
        }
    }
}

/// Inspect and exercise the vocabulary layer.
///
/// Correction is a rules engine with thresholds, and thresholds need to be
/// tuned against real garbled output rather than guessed. This command is how
/// that is done — by the author while building it, and by the user when a term
/// of theirs is not being caught.
struct Vocab: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Try the vocabulary correction and show the scores.",
        subcommands: [Test.self, Explain.self, Refine.self]
    )

    struct Test: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Correct a piece of text and show what changed."
        )

        @Argument(help: "Text to correct.")
        var text: String

        @Option(name: .long, help: "Threshold (default 0.78).")
        var threshold: Double?

        @Option(name: .long, help: "Skeleton threshold (default 0.74).")
        var skeletonThreshold: Double?

        func run() throws {
            try runBlocking {
                let config = Config.load()
                let vocabulary = Vocabulary(
                    terms: config.vocabulary,
                    threshold: threshold ?? Vocabulary.defaultThreshold,
                    skeletonThreshold: skeletonThreshold ?? Vocabulary.defaultSkeletonThreshold)

                guard !config.vocabulary.isEmpty else {
                    log("vocabulary is empty — add \"vocabulary\" to ~/.config/yaz/config.json")
                    throw ExitCode(1)
                }

                let result = vocabulary.correct(text)
                print("before: \(text)")
                print("after : \(result.text)")
                if result.corrections.isEmpty {
                    print("\n(no change)")
                } else {
                    print()
                    for correction in result.corrections {
                        print(String(format: "  %@ → %@   (%.3f, %@)",
                                     correction.from, correction.to,
                                     correction.score, correction.matchedBy.rawValue))
                    }
                }
            }
        }
    }

    /// Exercise the post-processing layer on text, with no audio involved.
    struct Refine: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Try post-processing on a piece of text."
        )

        @Argument(help: "Text to clean up.")
        var text: String

        @Option(name: .long, help: "Mode: off, fillers, llm.")
        var mode: RefineMode = .llm

        @Option(name: .long, help: "Dictation language. Cleanup is Turkish-only.")
        var language: String = FillerFilter.lexiconLanguage

        func run() throws {
            try runBlocking {
                // Said out loud rather than left as a silent no-op: text coming
                // back identical looks like a broken cleanup, not a deliberate
                // one.
                guard FillerFilter.isSupported(language: language) else {
                    log("""
                        post-processing is skipped for '\(language)' — both tiers are \
                        Turkish-specific (hesitation list and model instructions), and \
                        applying them to another language corrupts rather than cleans.
                        """)
                    print("before: \(text)")
                    print("after : \(text)")
                    print("\nmode \(mode.rawValue) · skipped (language \(language))")
                    return
                }

                switch Refiner.availability(for: mode) {
                case .available: break
                case .unavailable(let reason):
                    log("\(mode.rawValue) unavailable: \(reason)")
                    throw ExitCode(1)
                }

                let started = Date()
                let result = await Refiner(mode: mode, language: language).refine(text)
                let elapsed = Date().timeIntervalSince(started)

                print("before: \(text)")
                print("after : \(result.text)")
                print(String(format: "\nmode %@ · %.0f ms · %@",
                             mode.rawValue, elapsed * 1000,
                             result.changed ? "changed" : "unchanged"))
                if let rejection = result.rejection {
                    print("model output rejected: \(rejection)")
                }
            }
        }
    }

    struct Explain: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the phonetic keys of two spellings and how similar they are."
        )

        @Argument(help: "The term from your vocabulary.")
        var term: String

        @Argument(help: "The mangled form the recogniser produced.")
        var heard: String

        func run() throws {
            try runBlocking {
                let pairs = [("term", term), ("heard", heard)]
                for (label, value) in pairs {
                    print("\(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \"\(value)\"")
                    print("  normalised \(PhoneticKey.normalize(value))")
                    print("  skeleton   \(PhoneticKey.skeleton(value))")
                }
                let full = EditDistance.similarity(
                    PhoneticKey.normalize(term), PhoneticKey.normalize(heard))
                let skeletal = EditDistance.similarity(
                    PhoneticKey.skeleton(term), PhoneticKey.skeleton(heard))
                print(String(format: "\nsimilarity full %.3f  ·  skeleton %.3f", full, skeletal))
                print(String(format: "thresholds full %.2f  ·  skeleton %.2f",
                             Vocabulary.defaultThreshold, Vocabulary.defaultSkeletonThreshold))
            }
        }
    }
}

/// Transcribe an audio file and print the result.
///
/// This exists before the daemon does on purpose: it is the harness that lets
/// every later change (engine version, custom vocabulary, post-processing) be
/// measured on the same fixed audio instead of on whatever happened to be said
/// into the microphone that time.
struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe an audio file (the engine measurement harness)."
    )

    @Argument(help: "Audio files (wav/caf/m4a).")
    var files: [String] = []

    @Option(name: .long, help: "Engine: whisper (speaks Turkish) or parakeet (faster, NO Turkish).")
    var engineName: EngineChoice = .whisper

    @Option(name: .long, help: "Whisper model: large-v3-turbo or large-v3.")
    var whisperModel: WhisperModel = .largeV3Turbo

    @Option(name: .long, help: "Language code.")
    var language: String = "tr"

    @Option(name: .long, help: "Repetitions, for measurement.")
    var repeatCount: Int = 3

    @Option(name: .long, help: "Reject files longer than this (seconds).")
    var maxSeconds: Double = 3600

    @Flag(name: .long, help: "Enforce the quality gates (default: show the raw output).")
    var strict: Bool = false

    @Flag(name: .long, help: "Apply vocabulary correction from the config.")
    var vocabulary: Bool = false

    @Option(name: .long, help: "Post-processing: off, fillers, llm.")
    var refine: RefineMode?

    func validate() throws {
        guard repeatCount >= 1 else {
            throw ValidationError("--repeat-count must be at least 1")
        }
        guard maxSeconds > 0 else {
            throw ValidationError("--max-seconds must be positive")
        }
    }

    func run() throws {
        try runBlocking {
            guard !files.isEmpty else {
                throw ValidationError("give at least one audio file — e.g. yaz transcribe sample.wav")
            }

            let engine: any Transcriber = switch engineName {
            case .whisper: WhisperTranscriber(model: whisperModel, language: language)
            case .parakeet: ParakeetTranscriber(version: .v3)
            }

            // Refuse an engine/language pair that cannot work before spending a
            // model download on it. Parakeet returns confident nonsense for
            // Turkish rather than failing, so this check is the only thing standing
            // between the user and a wrong answer.
            try engine.validateLanguage(language)

            if !engine.isDownloaded {
                log("downloading the model — the first run can take a few minutes")
            }

            let loadStart = Date()
            try await engine.prepare()
            log(String(format: "✓ %@ ready — %.1f s", engine.model, Date().timeIntervalSince(loadStart)))

            // `yaz transcribe` is a measurement harness: by default it shows what
            // the model produced, with the gates reported but not enforced.
            var options = strict ? TranscribeOptions() : .raw
            options.timeout = .seconds(Int(max(maxSeconds, 120)))

            // The voice detector always prints its scores, so the threshold
            // can be checked against real recordings before `vad` is turned
            // on. --strict enforces it only when the config turns it on,
            // matching what the daemon would do.
            let config = Config.load()
            let voiceGate = VoiceActivityGate(threshold: config.vadThreshold)
            await SileroVoiceActivity.shared.prepare()
            if strict {
                options.voice = config.voiceCheck
            }

            var failures = 0
            for path in files {
                do {
                    try await transcribeOne(path, engine: engine, options: options, voiceGate: voiceGate)
                } catch let error as YazError {
                    failures += 1
                    print("\n═══ \(URL(fileURLWithPath: path).lastPathComponent) ═══")
                    print("  ✗ \(error.description)")
                }
            }

            await engine.release()
            if failures > 0 { throw ExitCode(1) }
        }
    }

    private func transcribeOne(
        _ path: String, engine: any Transcriber, options: TranscribeOptions,
        voiceGate: VoiceActivityGate
    ) async throws {
        let samples = try AudioLoader.load(path, maxSeconds: maxSeconds)
        let voice = await SileroVoiceActivity.shared.speechProbabilities(samples)
            .map { voiceGate.verdict(for: $0) }

        var best = Double.infinity
        var output: TranscriptionOutput?
        for index in 0..<repeatCount {
            let started = Date()
            let result = try await engine.transcribe(samples, options: options)
            let elapsed = Date().timeIntervalSince(started)
            // The first pass warms lazily-built Core ML state; discard it when
            // more than one pass was requested.
            if index > 0 || repeatCount == 1 { best = min(best, elapsed) }
            output = result
        }

        guard let output else { return }
        let seconds = output.duration

        print("\n═══ \(URL(fileURLWithPath: path).lastPathComponent) (\(String(format: "%.2f", seconds)) sn) ═══")
        print(String(
            format: "  latency %.0f ms · RTF %.3f · peak %.3f · rms %.3f",
            best * 1000, best / max(seconds, 0.001), output.level.peak, output.level.rms))

        if let voice {
            print(String(
                format: "  voice %.2f · %ld of %ld windows over %.2f%@",
                voice.peakProbability, voice.speechWindows, voice.windows,
                voiceGate.threshold, voice.hasSpeech ? "" : " · no speech"))
        } else {
            print("  (voice activity detector unavailable — level gate only)")
        }

        if let signals = output.quality.signals {
            print(String(
                format: "  noSpeech %.2f · logProb %.2f · compression %.2f",
                signals.noSpeechProb, signals.avgLogProb, signals.compressionRatio))
        } else {
            // Say so rather than printing zeros, which would look like a
            // flawless decode instead of a silent engine.
            print("  (engine reports no confidence — the verdict rests on the text alone)")
        }

        switch output.quality.verdict {
        case .good:
            break
        case .lowConfidence(let reason):
            print("  ! \(reason)")
        case .rejected(let reason):
            print("  ✗ rejected: \(reason)")
        }

        var text = output.text
        if vocabulary || refine != nil {
            var config = Config.load()
            if !vocabulary { config.vocabulary = [] }
            if let refine { config.refine = refine }
            config.language = language

            if vocabulary, !Vocabulary.isSupported(language: language) {
                print("  vocabulary skipped — the correction layer only supports"
                    + " \(Vocabulary.lexiconLanguage), not \(language)")
            }

            let started = Date()
            let processed = await TranscriptPipeline(config: config).process(text)
            let elapsed = Date().timeIntervalSince(started)

            for correction in processed.corrections {
                print(String(format: "  vocabulary: %@ → %@ (%.3f, %@)",
                             correction.from, correction.to,
                             correction.score, correction.matchedBy.rawValue))
            }
            if let rejection = processed.refinementRejected {
                print("  post-processing skipped: \(rejection)")
            }
            if processed.refined || !processed.corrections.isEmpty {
                print(String(format: "  post-processing %.0f ms", elapsed * 1000))
            }
            text = processed.text
        }
        print("  \(text.isEmpty ? "<empty>" : text)")
    }
}

/// Which engine backs a run. Whisper is the default because it is the only
/// one of the two that speaks Turkish.
enum EngineChoice: String, CaseIterable, ExpressibleByArgument {
    case whisper
    case parakeet
}

// The engine layer stays free of ArgumentParser; the CLI adopts its types here.
extension WhisperModel: ExpressibleByArgument {}
extension Hotkey: ExpressibleByArgument {}
extension TextInjector.Mode: ExpressibleByArgument {}
extension RefineMode: ExpressibleByArgument {}



/// `yaz microphones`: the input devices, with the UID `microphone` takes.
struct Microphones: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the microphones, with the UID the config file takes.")

    func run() throws {
        let inputs = AudioDevices.inputs()
        guard !inputs.isEmpty else {
            print("no input devices found")
            return
        }
        let chosen = Config.load().microphone
        for mic in inputs {
            var marks: [String] = []
            if mic.isDefault { marks.append("system default") }
            if mic.uid == chosen { marks.append("yaz uses this") }
            let suffix = marks.isEmpty ? "" : "  (" + marks.joined(separator: ", ") + ")"
            print("\(mic.name)\(suffix)")
            print("  \(mic.uid)")
        }
        if let chosen, !inputs.contains(where: { $0.uid == chosen }) {
            print("note: the configured microphone \(chosen) is not connected — yaz uses the system default")
        }
    }
}

/// `yaz projects`: what the project index knows, and a dry run of code mode.
struct Projects: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the names indexed from the project folders, or test code mode on a sentence.")

    @Option(name: .long, help: "A sentence to run through code mode, as if dictated into an editor.")
    var test: String?

    @Option(name: .long, help: "How many names to list.")
    var top: Int = 20

    func run() throws {
        try runBlocking {
            let config = Config.load()
            guard !config.projects.isEmpty else {
                print("no projects — add folders to \"projects\" in \(Config.path.path)")
                return
            }
            let started = Date()
            let index = ProjectIndex.scan(config.projects)
            print(String(format: "%d compound names, %d files, %.2f s",
                         index.identifiers.count, index.files.count,
                         Date().timeIntervalSince(started)))

            if let test {
                let pipeline = TranscriptPipeline(config: config, project: index)
                let output = await pipeline.process(test, code: true)
                for correction in output.corrections {
                    print("  vocabulary: \(correction.from) → \(correction.to)")
                }
                for change in output.codeChanges {
                    print("  code: \(change.from) → \(change.to)")
                }
                print(output.text)
                return
            }

            for term in index.vocabularyTerms(limit: top) {
                print("  \(term.canonical)  ← \"\(term.aliases.first ?? "")\"")
            }
        }
    }
}
