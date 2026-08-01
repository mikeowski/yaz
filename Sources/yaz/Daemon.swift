import AppKit
import Foundation

/// The dictation loop: hold the hotkey, speak, release, text appears.
///
/// Runs as an `.accessory` process — no dock icon, no menu bar entry — driving
/// an AppKit run loop, which `CGEventTap` requires.
@MainActor
final class Daemon {

    private let config: Config
    private let engine: any Transcriber
    private let monitor: HotkeyMonitor
    private let capture = AudioCapture()
    private let pipeline: TranscriptPipeline
    private let history: TranscriptHistory
    private let overlay: RecordingOverlay?
    /// Created in `run()`, not in `init`.
    ///
    /// `NSStatusBar.system` reaches into AppKit's application object. Building
    /// a status item before `NSApplication.shared` has been touched and the
    /// activation policy set produces an item that either never appears or
    /// appears and ignores clicks — which is exactly what happened.
    fileprivate var menuBar: MenuBarController?
    private let settings = SettingsWindowController()
    private let verbose: Bool

    /// Set while a transcription is running so a second press cannot start a
    /// recording that would land in the middle of the previous one's paste.
    private var busy = false

    /// False until the model is loaded. The event tap is installed before the
    /// load so permission failures surface immediately, which leaves a window
    /// where a key press has nothing to transcribe into.
    private var ready = false

    /// Poll that watches for the Accessibility grant arriving.
    private var permissionPoll: Timer?

    init(config: Config, verbose: Bool) {
        self.config = config
        self.engine = config.makeEngine()
        self.monitor = HotkeyMonitor(hotkey: config.hotkey, debug: verbose)
        self.pipeline = TranscriptPipeline(config: config)
        self.history = TranscriptHistory(limit: config.historyLimit, enabled: config.history)
        self.overlay = config.overlay ? RecordingOverlay() : nil
        self.verbose = verbose
    }

    func run() async throws {
        // Order matters: everything that can fail cheaply fails before the
        // 1.6 GB model load. Loading first means a missing Accessibility grant
        // costs the user seven seconds before they are told about it.
        try engine.validateLanguage(config.language)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if config.menuBar {
            menuBar = MenuBarController(summary: Self.summary(of: config))
        }

        menuBar?.onQuit = { [weak self] in self?.shutdown() }
        menuBar?.onOpenSettings = { [settings] in settings.showSettings() }
        menuBar?.onOpenHistory = { [settings] in settings.showHistory() }
        menuBar?.onFixPermission = { [weak self] in self?.presentPermissionAlert() }
        capture.onLevel = { [overlay] level in overlay?.pushLevel(level) }

        // Launched as an app, a missing Accessibility grant must not be fatal.
        // The user double-clicked an icon; exiting silently would look like the
        // app is broken. Instead prompt as *yaz* — which is the whole point of
        // shipping a bundle — and wait for the grant to arrive.
        var awaitingPermission = false
        if !HotkeyMonitor.hasAccessibilityPermission && AppEnvironment.isBundledApp {
            awaitingPermission = true
            menuBar?.setNeedsPermission(true)
            HotkeyMonitor.requestAccessibilityPermission()
            waitForAccessibility()
        } else {
            try startMonitor()
        }

        // Load the model *inside* the run loop, not before it.
        //
        // `app.run()` is what makes the menu bar respond and timers fire, so
        // anything awaited before it happens with the UI frozen. On a first
        // launch Core ML compilation takes minutes — the whole time the icon
        // would be present and dead, which is indistinguishable from a broken
        // app. Loading as a task means the menu works immediately and says
        // what it is doing.
        menuBar?.note("model yükleniyor…")
        startModelLoad()

        if awaitingPermission {
            DispatchQueue.main.async { [weak self] in self?.presentPermissionAlert() }
        }

        installSignalHandlers()
        log("dinleniyor · \(config.hotkey.displayName) basılı tut · \(config.injectMode.displayName) · ^C ile çık")
        app.run()
    }

    // MARK: -

    /// Prepare the engine off the main actor, then come back to report.
    ///
    /// `Task { }` inside a `@MainActor` type inherits the main actor, and the
    /// main actor is about to be occupied by `NSApplication.run()` for the life
    /// of the process. Such a task is enqueued and never gets a turn — the
    /// model silently never loaded and the daemon sat there "listening" with no
    /// engine behind it. `Task.detached` runs on the cooperative pool instead,
    /// and hops back here only to touch UI.
    private func startModelLoad() {
        let engine = self.engine
        Task.detached(priority: .userInitiated) {
            log("model yükleniyor…")
            let started = Date()
            do {
                try await engine.prepare()
            } catch {
                log("model yüklenemedi: \(error)")
                await MainActor.run { DaemonHolder.live?.menuBar?.note("model yüklenemedi") }
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            log(String(format: "✓ %@ hazır — %.1f sn", engine.model, elapsed))
            await MainActor.run { DaemonHolder.live?.engineBecameReady() }
        }
    }

    /// Called on the main actor once the engine is loaded.
    fileprivate func engineBecameReady() {
        ready = true
        if HotkeyMonitor.hasAccessibilityPermission {
            setIndicator(.idle)
            menuBar?.note("dinlemeye hazır")
        } else {
            menuBar?.setNeedsPermission(true)
        }
    }

    private func startMonitor() throws {
        try monitor.start { [weak self] event in
            // The tap callback already hops to main; assume that rather than
            // scheduling another hop, so press/release ordering is preserved.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    /// Poll until the grant lands, then start listening.
    ///
    /// `AXIsProcessTrusted` flips for the running process as soon as the user
    /// ticks the box, so polling means the app starts working without being
    /// quit and reopened — which is what every other dictation tool asks for
    /// and nobody enjoys.
    private func waitForAccessibility() {
        // The timer is held on the actor rather than captured in its own
        // closure: Swift 6 will not let a task-isolated `Timer` cross into a
        // main-actor closure, and holding it here also keeps it alive.
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard HotkeyMonitor.hasAccessibilityPermission else { return }
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
                do {
                    try self.startMonitor()
                    log("✓ erişilebilirlik verildi — dinleniyor")
                    self.menuBar?.setNeedsPermission(false)
                    self.menuBar?.note("dinlemeye hazır")
                    self.setIndicator(.idle)
                } catch {
                    log("kısayol kurulamadı: \(error)")
                    self.menuBar?.note("kısayol kurulamadı")
                }
            }
        }
        if let permissionPoll { RunLoop.main.add(permissionPoll, forMode: .common) }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "yaz erişilebilirlik izni istiyor"
        alert.informativeText = """
            Kısayol tuşunu dinlemek ve metni imlece yapıştırmak için gerekli.

            Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik listesinde             yaz'ı işaretle. İzni verdiğin anda çalışmaya başlar — uygulamayı             yeniden başlatman gerekmez.
            """
        alert.addButton(withTitle: "Sistem Ayarları'nı aç")
        alert.addButton(withTitle: "Sonra")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed:
            guard ready else {
                log("  (model hâlâ yükleniyor)")
                return
            }
            guard !busy else {
                if verbose { log("  (önceki çeviri sürüyor — kayıt başlatılmadı)") }
                return
            }
            do {
                try capture.start()
                log("● kayıt")
                setIndicator(.recording)
            } catch {
                log("kayıt başlatılamadı: \(error)")
                menuBar?.note("mikrofon açılamadı")
            }

        case .released:
            guard capture.isRecording else { return }
            let samples = capture.stop()
            let sawSignal = capture.didSeeSignal
            let hitLimit = capture.didHitLimit
            if hitLimit { log("uyarı: kayıt üst sınıra ulaştı, kırpıldı") }
            setIndicator(.transcribing)
            busy = true
            Task { await self.finish(samples, sawSignal: sawSignal) }
        }
    }

    private func finish(_ samples: [Float], sawSignal: Bool) async {
        defer {
            busy = false
            setIndicator(.idle)
        }

        let started = Date()
        do {
            let output = try await engine.transcribe(samples)
            let elapsed = Date().timeIntervalSince(started)

            switch output.quality.verdict {
            case .rejected(let reason):
                log("○ atlandı: \(reason)")
                menuBar?.note("atlandı — \(reason)")
                return
            case .lowConfidence(let reason):
                log("! \(reason)")
            case .good:
                break
            }

            // Vocabulary correction and refinement both run on the finished
            // transcript, because the ASR-level alternatives do not work on
            // this stack: Whisper returns empty output when given promptTokens,
            // and the on-device LLM cannot do fuzzy Turkish-phonetic matching.
            if config.refine == .llm { setIndicator(.refining) }
            let processed = await pipeline.process(output.text)
            for correction in processed.corrections {
                log("  sözlük: \(correction.from) → \(correction.to)")
            }
            if let rejection = processed.refinementRejected, verbose {
                log("  son işleme atlandı: \(rejection)")
            }

            let total = Date().timeIntervalSince(started)
            log(String(format: "→ %.2f sn (çeviri %.2f) · %@", total, elapsed, processed.text))

            // Read the frontmost app *before* pasting: the overlay never takes
            // focus, so at this instant it is still the window the cursor is
            // in — which is the only moment that answer is correct.
            let target = AppEnvironment.frontmostApp()

            TextInjector.inject(processed.text, mode: config.injectMode)
            runHook(with: processed.text)

            let entry = HistoryEntry(
                date: Date(),
                text: processed.text,
                appName: target?.name,
                appBundleID: target?.bundleID,
                seconds: output.duration,
                engine: engine.name,
                model: engine.model,
                corrections: processed.corrections.map { "\($0.from) → \($0.to)" })
            Task { [history] in await history.record(entry) }

        } catch let error as YazError where error.isBenignInput {
            // Tapping the key by accident, or a moment of silence, is not a
            // failure worth shouting about.
            if verbose { log("○ \(error.description)") }
            if !sawSignal && !samples.isEmpty {
                // Distinguish "you were quiet" from "the mic is dead".
                log("uyarı: mikrofondan hiç sinyal gelmedi — giriş cihazını kontrol et")
            }
        } catch {
            log("✗ \(error)")
        }
    }

    /// Push a state to every indicator that is switched on.
    private func setIndicator(_ state: IndicatorState) {
        menuBar?.update(state)
        if state.isVisible { overlay?.show(state) } else { overlay?.hide() }
    }

    private static func summary(of config: Config) -> String {
        "\(config.whisperModel.rawValue) · \(config.language) · \(config.hotkey.displayName)"
    }

    private func shutdown() {
        log("kapatılıyor")
        monitor.stop()
        capture.stop()
        overlay?.hide()
        menuBar?.remove()
        NSApp.terminate(nil)
    }

    /// Fire the configured shell command with the transcript as its argument.
    /// Detached: a slow hook must not delay the next utterance.
    private func runHook(with text: String) {
        guard let command = config.onTranscript else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \"$0\"", text]
        do {
            try process.run()
        } catch {
            log("on_transcript çalıştırılamadı: \(error)")
        }
    }

    private func installSignalHandlers() {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { self.shutdown() }
        }
        source.resume()
        signal(SIGINT, SIG_IGN)
        // Keep the source alive for the process lifetime.
        Self.signalSources.append(source)
    }

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}
