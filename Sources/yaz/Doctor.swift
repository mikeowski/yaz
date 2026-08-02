import AVFoundation
import AppKit
import Foundation

enum CheckStatus: Sendable {
    case ok(String?)
    case warn(String)
    case fail(String)
}

struct Check: Sendable {
    let name: String
    let status: CheckStatus
    /// What the user should actually do. A check that reports a problem
    /// without saying how to fix it has done half a job.
    let remedy: String?
}

/// Preflight for everything yaz needs before it can dictate.
enum DoctorReport {

    static func run(config: Config) -> [Check] {
        var checks = [
            microphone(),
            accessibility(),
            inputMonitoring(),
            model(config: config),
            injection(config: config),
            refinement(config: config),
            postProcessingLanguage(config: config),
            loginItem(),
        ]
        if config.hotkey.conflictsWithSystemFnAction {
            checks.append(fnKeyMapping())
        }
        return checks
    }

    // MARK: -

    static func microphone() -> Check {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return Check(name: "microphone", status: .ok(nil), remedy: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not requested yet — macOS will ask on the first recording"),
                remedy: "press the hotkey once and macOS will prompt")
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remedy: "System Settings → Privacy & Security → Microphone")
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remedy: nil)
        }
    }

    static func accessibility() -> Check {
        guard HotkeyMonitor.hasAccessibilityPermission else {
            return Check(
                name: "accessibility",
                status: .fail("not granted"),
                remedy: "System Settings → Privacy & Security → Accessibility → enable "
                    + "\(accessibilityOwner(parentName: parentProcessName(), parentPID: getppid()))"
                    + " in the list")
        }
        return Check(name: "accessibility", status: .ok(nil), remedy: nil)
    }

    /// Which entry the user has to tick in the Accessibility list.
    ///
    /// Launched from a shell, macOS attributes the grant to the *terminal*,
    /// not to yaz — so naming the parent is the difference between an
    /// actionable message and a puzzle. Under launchd there is no terminal:
    /// the parent is `launchd` itself, and telling someone to enable
    /// "launchd" is worse than useless. There the grant belongs to yaz, which
    /// the embedded Info.plist gives an identity of its own.
    static func accessibilityOwner(parentName: String?, parentPID: pid_t) -> String {
        guard let parentName, !parentName.isEmpty else { return "yaz" }
        if parentPID <= 1 || parentName == "launchd" { return "yaz" }
        return parentName
    }

    /// Accessibility is not enough to listen to the keyboard; this is.
    ///
    /// Reported as a hard failure because the symptom without it is not a
    /// degraded experience, it is total silence: the tap installs and never
    /// fires, and nothing in the app can tell you why.
    static func inputMonitoring() -> Check {
        switch InputMonitoring.state {
        case .granted:
            return Check(name: "input monitoring", status: .ok(nil), remedy: nil)
        case .notDetermined:
            return Check(
                name: "input monitoring",
                status: .fail("not granted — the hotkey cannot work without it"),
                remedy: "\(InputMonitoring.settingsPath) → enable yaz"
                    + " (this is a different list from Accessibility)")
        case .denied:
            return Check(
                name: "input monitoring",
                status: .fail("denied — the hotkey cannot work without it"),
                remedy: "\(InputMonitoring.settingsPath) → enable yaz")
        }
    }

    static func model(config: Config) -> Check {
        guard config.engine == .whisper else {
            let engine = ParakeetTranscriber(version: .v3)
            return engine.isDownloaded
                ? Check(name: "model", status: .ok("parakeet downloaded"), remedy: nil)
                : Check(
                    name: "model",
                    status: .warn("parakeet not downloaded (~600 MB)"),
                    remedy: "downloads on first use — try one short run before anything important")
        }

        let status = ModelStore.status(for: config.whisperModel.whisperKitID)
        if status.isComplete {
            return Check(
                name: "model",
                status: .ok("\(config.whisperModel.rawValue) · \(status.sizeDescription)"),
                // Not a failure, but the user should know 1.6 GB landed in a
                // folder iCloud may be syncing.
                remedy: status.path.contains("Documents")
                    ? "note: weights live in \(status.path) — if iCloud Documents sync is on, they go to the cloud"
                    : nil)
        }
        if status.sizeBytes == 0 {
            return Check(
                name: "model",
                status: .warn("\(config.whisperModel.rawValue) not downloaded (~\(config.whisperModel.sizeMB) MB)"),
                remedy: "pre-fetch it with: yaz models download")
        }
        return Check(
            name: "model",
            status: .fail("partially downloaded — missing: \(status.missing.joined(separator: ", "))"),
            remedy: "re-download with: yaz models download --force")
    }

    static func injection(config: Config) -> Check {
        Check(
            name: "text insertion",
            status: .ok(config.injectMode.displayName),
            remedy: config.injectMode == .type
                ? "note: typing can drop characters in Electron apps — 'paste' is more reliable"
                : nil)
    }

    /// The language-model path needs Apple Intelligence switched on and the
    /// model downloaded. Neither is something yaz can arrange, so the check
    /// exists to say which one is missing.
    static func refinement(config: Config) -> Check {
        switch Refiner.availability(for: config.refine) {
        case .available:
            return Check(
                name: "post-processing",
                status: .ok(config.refine.displayName),
                remedy: config.refine == .llm
                    ? "note: the language model adds ~0.3–1.4 s per utterance; \"fillers\" costs ~1 ms"
                    : nil)
        case .unavailable(let reason):
            return Check(
                name: "post-processing",
                status: .warn("\(config.refine.rawValue) unavailable — \(reason)"),
                remedy: "set \"refine\": \"fillers\" in the config to fall back to the deterministic filter")
        }
    }

    /// Whether the Turkish-specific layers apply to the configured language.
    ///
    /// Not a failure — dictation still works, and the transcription itself is
    /// fully multilingual. What stops is the vocabulary repair, which is the
    /// reason this project exists. Saying so beats letting someone wonder why
    /// their terms are never fixed.
    static func postProcessingLanguage(config: Config) -> Check {
        guard !config.vocabulary.isEmpty else {
            return Check(name: "vocabulary", status: .ok("no terms configured"), remedy: nil)
        }
        guard Vocabulary.isSupported(language: config.language) else {
            return Check(
                name: "vocabulary",
                status: .warn("\(config.vocabulary.count) terms configured, but term repair"
                    + " only supports \(Vocabulary.lexiconLanguage) — skipped for"
                    + " \(config.language)"),
                remedy: "the safety check that prevents wrong replacements is a Turkish"
                    + " word list; running it on another language corrupts text")
        }
        return Check(
            name: "vocabulary",
            status: .ok("\(config.vocabulary.count) terms · \(config.language)"),
            remedy: nil)
    }

    /// A stale login item is the worst kind of broken: launchd keeps trying,
    /// the user sees nothing, and nothing in the UI says why.
    static func loginItem() -> Check {
        let state = LaunchAgent.status()
        guard state.isInstalled else {
            return Check(
                name: "launch at login",
                status: .ok("not installed"),
                remedy: "optional: yaz install --launch-at-login")
        }
        if state.isStale {
            return Check(
                name: "launch at login",
                status: .fail("registered binary is missing: \(state.binaryPath ?? "?")"),
                remedy: "refresh with: yaz install --launch-at-login, or remove with --uninstall")
        }
        return Check(
            name: "launch at login",
            status: .ok(state.binaryPath ?? "installed"),
            remedy: nil)
    }

    /// Whether macOS has claimed the globe/fn key.
    ///
    /// This is not cosmetic. When the system owns the key it consumes the press
    /// before a session-level `CGEventTap` ever sees it, so the hotkey does
    /// nothing at all — no indicator, no error, nothing in the log. Measured on
    /// this machine: Accessibility granted, Input Monitoring granted, tap
    /// installed, and zero modifier events delivered.
    ///
    /// An *unset* `AppleFnUsageType` is the dangerous case, not a safe one: the
    /// default binds the key to input-source switching as soon as a second
    /// keyboard layout exists, and to Dictation when that is enabled. Treating
    /// "unreadable" as a warning let exactly that configuration through.
    static func fnKeyMapping() -> Check {
        let remedy = "System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing"
            + "  ·  or pick another key in Settings (right-option has no conflict)"

        guard let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType"),
              let value = Int(raw)
        else {
            // Unset. Work out whether the system default will claim it.
            let claimed = hasMultipleInputSources() || dictationEnabled()
            return Check(
                name: "fn key",
                status: claimed
                    ? .fail("claimed by macOS — the hotkey cannot reach yaz")
                    : .warn("not configured — the system default may intercept it"),
                remedy: remedy)
        }
        switch value {
        case 0: return Check(name: "fn key", status: .ok(nil), remedy: nil)
        case 1: return Check(name: "fn key", status: .fail("set to Change Input Source"), remedy: remedy)
        case 2: return Check(name: "fn key", status: .fail("set to Show Emoji & Symbols"), remedy: remedy)
        case 3: return Check(name: "fn key", status: .fail("set to Start Dictation"), remedy: remedy)
        default: return Check(name: "fn key", status: .warn("unknown value \(value)"), remedy: remedy)
        }
    }

    /// More than one keyboard layout makes the globe key an input-source
    /// switcher by default.
    static func hasMultipleInputSources() -> Bool {
        guard let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleEnabledInputSources")
        else { return false }
        return raw.components(separatedBy: "Keyboard Layout Name").count > 2
    }

    /// Dictation binds the globe key too.
    static func dictationEnabled() -> Bool {
        readDefault(domain: "com.apple.HIToolbox", key: "AppleDictationAutoEnable") == "1"
    }

    // MARK: -

    /// Render the report.
    ///
    /// `toStandardError` exists for the launchd path. A LaunchAgent's stdout
    /// and stderr go to *different files*, so a startup failure that announces
    /// itself on stderr and then lists the reasons on stdout leaves the user
    /// staring at "checks failed" with nothing under it — which is exactly
    /// what the first run under launchd produced.
    static func render(_ checks: [Check], toStandardError: Bool = false) {
        var lines: [String] = []
        for check in checks {
            let (mark, label): (String, String) = switch check.status {
            case .ok(let detail): ("✓", detail ?? "ok")
            case .warn(let message): ("!", message)
            case .fail(let message): ("✗", message)
            }
            lines.append("\(mark) \(check.name): \(label)")
            if let remedy = check.remedy { lines.append("    → \(remedy)") }
        }

        let text = lines.joined(separator: "\n")
        if toStandardError {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        } else {
            print(text)
        }
    }

    /// Warnings do not block startup; only hard failures do.
    static func canRun(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }

    private static func readDefault(domain: String, key: String) -> String? {
        run("/usr/bin/defaults", ["read", domain, key])
    }

    private static func parentProcessName() -> String? {
        guard let name = run("/bin/ps", ["-p", String(getppid()), "-o", "comm="]) else { return nil }
        return (name as NSString).lastPathComponent
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}
