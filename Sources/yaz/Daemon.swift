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
    private let verbose: Bool

    /// Set while a transcription is running so a second press cannot start a
    /// recording that would land in the middle of the previous one's paste.
    private var busy = false

    /// False until the model is loaded. The event tap is installed before the
    /// load so permission failures surface immediately, which leaves a window
    /// where a key press has nothing to transcribe into.
    private var ready = false

    init(config: Config, verbose: Bool) {
        self.config = config
        self.engine = config.makeEngine()
        self.monitor = HotkeyMonitor(hotkey: config.hotkey, debug: verbose)
        self.verbose = verbose
    }

    func run() async throws {
        // Order matters: everything that can fail cheaply fails before the
        // 1.6 GB model load. Loading first means a missing Accessibility grant
        // costs the user seven seconds before they are told about it.
        try engine.validateLanguage(config.language)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        try monitor.start { [weak self] event in
            // The tap callback already hops to main; assume that rather than
            // scheduling another hop, so press/release ordering is preserved.
            MainActor.assumeIsolated { self?.handle(event) }
        }

        log("model yükleniyor…")
        let started = Date()
        do {
            try await engine.prepare()
        } catch {
            monitor.stop()
            throw error
        }
        log(String(format: "✓ %@ hazır — %.1f sn", engine.model, Date().timeIntervalSince(started)))

        // Only now will a key press start a recording. The tap exists earlier,
        // but no events are delivered until the run loop below starts, and
        // `ready` guards the case where one slips through.
        ready = true

        installSignalHandlers()
        log("dinleniyor · \(config.hotkey.displayName) basılı tut · \(config.injectMode.displayName) · ^C ile çık")
        app.run()
    }

    // MARK: -

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
            } catch {
                log("kayıt başlatılamadı: \(error)")
            }

        case .released:
            guard capture.isRecording else { return }
            let samples = capture.stop()
            let sawSignal = capture.didSeeSignal
            let hitLimit = capture.didHitLimit
            if hitLimit { log("uyarı: kayıt üst sınıra ulaştı, kırpıldı") }
            busy = true
            Task { await self.finish(samples, sawSignal: sawSignal) }
        }
    }

    private func finish(_ samples: [Float], sawSignal: Bool) async {
        defer { busy = false }

        let started = Date()
        do {
            let output = try await engine.transcribe(samples)
            let elapsed = Date().timeIntervalSince(started)

            switch output.quality.verdict {
            case .rejected(let reason):
                log("○ atlandı: \(reason)")
                return
            case .lowConfidence(let reason):
                log("! \(reason)")
            case .good:
                break
            }

            log(String(format: "→ %.2f sn · %@", elapsed, output.text))
            TextInjector.inject(output.text, mode: config.injectMode)
            runHook(with: output.text)

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
            MainActor.assumeIsolated {
                log("\nkapatılıyor")
                self.monitor.stop()
                self.capture.stop()
                NSApp.terminate(nil)
            }
        }
        source.resume()
        signal(SIGINT, SIG_IGN)
        // Keep the source alive for the process lifetime.
        Self.signalSources.append(source)
    }

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}
