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
            model(config: config),
            injection(config: config),
            refinement(config: config),
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
            return Check(name: "mikrofon", status: .ok(nil), remedy: nil)
        case .notDetermined:
            return Check(
                name: "mikrofon",
                status: .warn("henüz istenmedi — ilk kayıtta sorulacak"),
                remedy: "bir kez kısayola bas; macOS izin soracak")
        case .denied, .restricted:
            return Check(
                name: "mikrofon",
                status: .fail("reddedilmiş"),
                remedy: "Sistem Ayarları → Gizlilik ve Güvenlik → Mikrofon")
        @unknown default:
            return Check(name: "mikrofon", status: .fail("bilinmeyen durum"), remedy: nil)
        }
    }

    static func accessibility() -> Check {
        guard HotkeyMonitor.hasAccessibilityPermission else {
            return Check(
                name: "erişilebilirlik",
                status: .fail("verilmemiş"),
                remedy: "Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik → "
                    + "\(accessibilityOwner(parentName: parentProcessName(), parentPID: getppid()))"
                    + " etkinleştir")
        }
        return Check(name: "erişilebilirlik", status: .ok(nil), remedy: nil)
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

    static func model(config: Config) -> Check {
        guard config.engine == .whisper else {
            let engine = ParakeetTranscriber(version: .v3)
            return engine.isDownloaded
                ? Check(name: "model", status: .ok("parakeet indirili"), remedy: nil)
                : Check(
                    name: "model",
                    status: .warn("parakeet indirilmemiş (~600 MB)"),
                    remedy: "ilk çeviride otomatik iner — önemli bir iş öncesi bir kez dene")
        }

        let status = ModelStore.status(for: config.whisperModel.whisperKitID)
        if status.isComplete {
            return Check(
                name: "model",
                status: .ok("\(config.whisperModel.rawValue) · \(status.sizeDescription)"),
                // Not a failure, but the user should know 1.6 GB landed in a
                // folder iCloud may be syncing.
                remedy: status.path.contains("Documents")
                    ? "not: ağırlıklar \(status.path) altında — iCloud Documents senkronu açıksa buluta gidebilir"
                    : nil)
        }
        if status.sizeBytes == 0 {
            return Check(
                name: "model",
                status: .warn("\(config.whisperModel.rawValue) indirilmemiş (~\(config.whisperModel.sizeMB) MB)"),
                remedy: "yaz models download ile önceden indir")
        }
        return Check(
            name: "model",
            status: .fail("yarım indirilmiş — eksik: \(status.missing.joined(separator: ", "))"),
            remedy: "yaz models download --force ile yeniden indir")
    }

    static func injection(config: Config) -> Check {
        Check(
            name: "metin yerleştirme",
            status: .ok(config.injectMode.displayName),
            remedy: config.injectMode == .type
                ? "not: tuş tuş yazma Electron uygulamalarında karakter düşürebilir — 'paste' daha güvenilir"
                : nil)
    }

    /// The language-model path needs Apple Intelligence switched on and the
    /// model downloaded. Neither is something yaz can arrange, so the check
    /// exists to say which one is missing.
    static func refinement(config: Config) -> Check {
        switch Refiner.availability(for: config.refine) {
        case .available:
            return Check(
                name: "son işleme",
                status: .ok(config.refine.displayName),
                remedy: config.refine == .llm
                    ? "not: dil modeli her ifadeye ~0.3–1.4 sn ekler (uzunluğa göre); \"fillers\" ~1 ms"
                    : nil)
        case .unavailable(let reason):
            return Check(
                name: "son işleme",
                status: .warn("\(config.refine.rawValue) kullanılamıyor — \(reason)"),
                remedy: "config'de \"refine\": \"fillers\" ile deterministik temizliğe düş")
        }
    }

    /// A stale login item is the worst kind of broken: launchd keeps trying,
    /// the user sees nothing, and nothing in the UI says why.
    static func loginItem() -> Check {
        let state = LaunchAgent.status()
        guard state.isInstalled else {
            return Check(
                name: "girişte başlatma",
                status: .ok("kurulu değil"),
                remedy: "istersen: yaz install --launch-at-login")
        }
        if state.isStale {
            return Check(
                name: "girişte başlatma",
                status: .fail("kayıtlı ikili dosya yok: \(state.binaryPath ?? "?")"),
                remedy: "yaz install --launch-at-login ile tazele veya --uninstall ile kaldır")
        }
        return Check(
            name: "girişte başlatma",
            status: .ok(state.binaryPath ?? "kurulu"),
            remedy: nil)
    }

    /// macOS routes the Fn key to emoji, dictation, or input switching unless
    /// told otherwise. The tap still sees the press, but the system action
    /// fires too, so the user gets an emoji picker every time they dictate.
    static func fnKeyMapping() -> Check {
        let remedy = "Sistem Ayarları → Klavye → 🌐 tuşuna basınca → Hiçbir şey yapma"
        guard let raw = readDefault(domain: "com.apple.HIToolbox", key: "AppleFnUsageType"),
              let value = Int(raw)
        else {
            return Check(
                name: "fn tuşu",
                status: .warn("ayar okunamadı — sistem varsayılanı araya girebilir"),
                remedy: remedy)
        }
        switch value {
        case 0: return Check(name: "fn tuşu", status: .ok(nil), remedy: nil)
        case 1: return Check(name: "fn tuşu", status: .fail("giriş kaynağı değiştirmeye ayarlı"), remedy: remedy)
        case 2: return Check(name: "fn tuşu", status: .fail("emoji panelini açmaya ayarlı"), remedy: remedy)
        case 3: return Check(name: "fn tuşu", status: .fail("dikteyi başlatmaya ayarlı"), remedy: remedy)
        default: return Check(name: "fn tuşu", status: .warn("bilinmeyen değer \(value)"), remedy: remedy)
        }
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
            case .ok(let detail): ("✓", detail ?? "tamam")
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
