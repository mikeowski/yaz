import AppKit
import ArgumentParser
import FluidAudio
import Foundation

@main
struct Yaz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yaz",
        abstract: "Türkçe konuşan geliştiriciler için on-device dikte. Bas-konuş, bırak, metin imlece gelir.",
        subcommands: [Run.self, Settings.self, Doctor.self, History.self, Install.self, Transcribe.self, Models.self, Vocab.self, Preview.self],
        defaultSubcommand: Run.self
    )
}

/// Run the dictation daemon.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Dikte daemon'ını çalıştır (varsayılan)."
    )

    @Option(name: .long, help: "Kısayol tuşu: fn, right-option, right-command, right-control, right-shift.")
    var hotkey: Hotkey?

    @Option(name: .long, help: "Metin yerleştirme: paste veya type.")
    var injectMode: TextInjector.Mode?

    @Option(name: .long, help: "Dil kodu.")
    var language: String?

    @Flag(name: .long, help: "Başlangıç kontrollerini atla.")
    var skipDoctor = false

    @Flag(name: .long, help: "Ayrıntılı günlük.")
    var verbose = false

    func run() async throws {
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
                log("başlangıç kontrolleri başarısız:")
                DoctorReport.render(checks, toStandardError: true)
                log("yukarıdakileri düzelt ya da --skip-doctor kullan")
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
        let daemon = await MainActor.run {
            let daemon = Daemon(config: config, verbose: verbose)
            DaemonHolder.live = daemon
            return daemon
        }
        try await daemon.run()
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
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "İzinleri, modeli ve ayarları kontrol et."
    )

    @Flag(name: .long, help: "Eksik izinler için sistem penceresini aç.")
    var request = false

    func run() async throws {
        let config = Config.load()
        print("yapılandırma: \(FileManager.default.fileExists(atPath: Config.path.path) ? Config.path.path : "varsayılanlar (config dosyası yok)")")
        print("motor: \(config.engine.rawValue) · dil: \(config.language) · kısayol: \(config.hotkey.displayName)")
        print("sözlük: \(config.vocabulary.count) terim · son işleme: \(config.refine.displayName)")
        print()

        let checks = DoctorReport.run(config: config)
        DoctorReport.render(checks)

        if request && !HotkeyMonitor.hasAccessibilityPermission {
            print("\nerişilebilirlik izni isteniyor…")
            HotkeyMonitor.requestAccessibilityPermission()
        }
        if !DoctorReport.canRun(checks) { throw ExitCode(1) }
    }
}

/// Download and inspect models.
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Modelleri listele ve indir.",
        subcommands: [List.self, Download.self]
    )

    struct List: AsyncParsableCommand {
        func run() async throws {
            for model in WhisperModel.allCases {
                let status = ModelStore.status(for: model.whisperKitID)
                let mark = status.isComplete ? "✓" : (status.sizeBytes > 0 ? "!" : " ")
                let detail = status.isComplete
                    ? status.sizeDescription
                    : (status.sizeBytes > 0 ? "yarım (\(status.sizeDescription))" : "indirilmemiş")
                print("\(mark) whisper/\(model.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) ~\(model.sizeMB) MB  \(detail)")
            }
            let parakeet = ParakeetTranscriber(version: .v3)
            print("\(parakeet.isDownloaded ? "✓" : " ") parakeet/tdt-0.6b-v3    ~600 MB  (Türkçe YOK)")
        }
    }

    struct Download: AsyncParsableCommand {
        @Option(name: .long, help: "Whisper modeli.")
        var whisperModel: WhisperModel = .largeV3Turbo

        @Flag(name: .long, help: "Yarım/bozuk indirmeyi silip yeniden indir.")
        var force = false

        func run() async throws {
            if force {
                let directory = ModelStore.directory(for: whisperModel.whisperKitID)
                if FileManager.default.fileExists(atPath: directory.path) {
                    log("siliniyor: \(directory.path)")
                    try FileManager.default.removeItem(at: directory)
                }
            }
            let engine = WhisperTranscriber(model: whisperModel)
            log("indiriliyor: \(whisperModel.rawValue) (~\(whisperModel.sizeMB) MB)…")
            let started = Date()
            try await engine.prepare()
            await engine.release()
            let status = ModelStore.status(for: whisperModel.whisperKitID)
            log(String(format: "✓ hazır — %.0f sn · %@", Date().timeIntervalSince(started), status.sizeDescription))
        }
    }
}

/// Open the settings or history window without going through the menu bar.
///
/// The windows are otherwise reachable only by clicking a menu item, which
/// means they cannot be exercised except by hand. This command opens them
/// directly — useful when the daemon is not running, and the only way to
/// verify the SwiftUI paths actually run rather than merely compile.
struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ayarlar penceresini aç."
    )

    @Flag(name: .long, help: "Ayarlar yerine geçmiş penceresini aç.")
    var history = false

    @Option(name: .long, help: "Bu kadar saniye sonra kendiliğinden kapan (test için).")
    var autoQuit: Double?

    func run() async throws {
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let controller = SettingsWindowController()
            if history { controller.showHistory() } else { controller.showSettings() }

            if let autoQuit {
                Timer.scheduledTimer(withTimeInterval: autoQuit, repeats: false) { _ in
                    log("otomatik kapanış")
                    NSApp.terminate(nil)
                }
            }
            app.run()
        }
    }
}

/// Read back what was dictated.
struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dikte geçmişini göster (yalnızca metin, ses saklanmaz)."
    )

    @Option(name: .long, help: "Kaç kayıt gösterilsin.")
    var limit: Int = 20

    @Option(name: .long, help: "Metinde veya uygulama adında ara.")
    var search: String?

    @Flag(name: .long, help: "Tam kayıtları JSON olarak dök.")
    var json = false

    @Flag(name: .long, help: "Tüm geçmişi sil.")
    var clear = false

    func run() async throws {
        let config = Config.load()
        let store = TranscriptHistory(limit: config.historyLimit, enabled: config.history)

        if clear {
            let total = await store.count()
            await store.clear()
            print("✓ \(total) kayıt silindi")
            return
        }

        let entries = await store.entries(limit: limit, matching: search)
        guard !entries.isEmpty else {
            let total = await store.count()
            if total == 0 {
                print("geçmiş boş")
                if !config.history { print("  (config'de \"history\": false)") }
            } else {
                print("eşleşme yok (\(total) kayıt arasında)")
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
                print("  sözlük: \(entry.corrections.joined(separator: ", "))")
            }
            print()
        }
        let total = await store.count()
        print("— \(entries.count) / \(total) kayıt")
    }
}

/// Register or remove the login item.
struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Girişte otomatik başlatmayı aç veya kapat."
    )

    @Flag(name: .long, help: "Girişte başlaması için kaydet.")
    var launchAtLogin = false

    @Flag(name: .long, help: "Kaydı kaldır.")
    var uninstall = false

    @Flag(name: .long, help: "Yalnızca durumu göster.")
    var status = false

    func run() async throws {
        if status || (!launchAtLogin && !uninstall) {
            report()
            return
        }
        guard launchAtLogin != uninstall else {
            throw ValidationError("--launch-at-login veya --uninstall, ikisinden birini seç")
        }

        if uninstall {
            try LaunchAgent.remove()
            print("✓ girişte başlatma kaldırıldı")
            return
        }

        guard let binary = LaunchAgent.currentBinary() else {
            throw ValidationError("çalışan ikili dosyanın yolu bulunamadı")
        }
        // A LaunchAgent pointing into a build directory breaks the moment the
        // tree is cleaned, and the failure is silent — say so now.
        if binary.path.contains("/.build/") {
            log("uyarı: \(binary.path) bir derleme dizini —")
            log("       önce /usr/local/bin altına kopyala, sonra oradan çalıştır")
        }

        try LaunchAgent.install(binary: binary)
        print("✓ girişte başlatma kuruldu")
        print("  ikili : \(binary.path)")
        print("  günlük: \(LaunchAgent.standardErrorPath)")
    }

    private func report() {
        let state = LaunchAgent.status()
        if !state.isInstalled {
            print("girişte başlatma: kurulu değil")
            print("  → yaz install --launch-at-login")
            return
        }
        print("girişte başlatma: kurulu")
        print("  ikili : \(state.binaryPath ?? "?")")
        print("  plist : \(LaunchAgent.plistURL.path)")
        if state.isStale {
            print("  ✗ ikili dosya bulunamıyor — yaz install --launch-at-login ile tazele")
        }
    }
}

/// Show the recording indicator without a microphone or a hotkey.
///
/// The overlay and the menu bar are the only parts of yaz that cannot be
/// reached from a test: they need a run loop, a screen, and — via the daemon —
/// an Accessibility grant. This command drives them directly, so the AppKit
/// and SwiftUI paths get exercised rather than merely compiled.
struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kayıt göstergesini ekranda göster (mikrofon gerekmez)."
    )

    @Option(name: .long, help: "Her durumun ekranda kalma süresi (saniye).")
    var dwell: Double = 1.6

    @Option(name: .long, help: "Menü barı ikonunu bu PNG'ye bas ve çık (tasarım denetimi).")
    var renderIcon: String?

    func run() async throws {
        if let renderIcon {
            try await MainActor.run { try Self.writeIconSheet(to: renderIcon) }
            return
        }
        try await runPreview()
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
            // Gerçek boyut, 1× ve 2×: mark 18 pt'te okunmuyorsa büyükte güzel
            // olması hiçbir şey ifade etmiyor.
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
        else { throw ValidationError("ikon çizilemedi") }

        try png.write(to: URL(fileURLWithPath: path))
        log("yazıldı: \(path) — sırayla idle, recording, transcribing, refining")
    }

    private func runPreview() async throws {
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)

            let config = Config.load()
            let overlay = RecordingOverlay()
            let menuBar = config.menuBar
                ? MenuBarController(summary: "önizleme")
                : nil

            log("gösterge önizlemesi — ekranın altına bak, menü barını kontrol et")

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
                log("önizleme bitti")
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
struct Vocab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sözlük düzeltmesini dene ve puanları göster.",
        subcommands: [Test.self, Explain.self, Refine.self]
    )

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bir metni düzelt ve neyin değiştiğini göster."
        )

        @Argument(help: "Düzeltilecek metin.")
        var text: String

        @Option(name: .long, help: "Eşik (varsayılan 0.72).")
        var threshold: Double?

        @Option(name: .long, help: "İskelet eşiği (varsayılan 0.78).")
        var skeletonThreshold: Double?

        func run() async throws {
            let config = Config.load()
            let vocabulary = Vocabulary(
                terms: config.vocabulary,
                threshold: threshold ?? Vocabulary.defaultThreshold,
                skeletonThreshold: skeletonThreshold ?? Vocabulary.defaultSkeletonThreshold)

            guard !config.vocabulary.isEmpty else {
                log("sözlük boş — ~/.config/yaz/config.json içine \"vocabulary\" ekle")
                throw ExitCode(1)
            }

            let result = vocabulary.correct(text)
            print("önce : \(text)")
            print("sonra: \(result.text)")
            if result.corrections.isEmpty {
                print("\n(değişiklik yok)")
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

    /// Exercise the post-processing layer on text, with no audio involved.
    struct Refine: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Son işlemeyi bir metin üzerinde dene."
        )

        @Argument(help: "Temizlenecek metin.")
        var text: String

        @Option(name: .long, help: "Mod: off, fillers, llm.")
        var mode: RefineMode = .llm

        func run() async throws {
            switch Refiner.availability(for: mode) {
            case .available: break
            case .unavailable(let reason):
                log("\(mode.rawValue) kullanılamıyor: \(reason)")
                throw ExitCode(1)
            }

            let started = Date()
            let result = await Refiner(mode: mode).refine(text)
            let elapsed = Date().timeIntervalSince(started)

            print("önce : \(text)")
            print("sonra: \(result.text)")
            print(String(format: "\nmod %@ · %.0f ms · %@",
                         mode.rawValue, elapsed * 1000,
                         result.changed ? "değişti" : "değişmedi"))
            if let rejection = result.rejection {
                print("model çıktısı reddedildi: \(rejection)")
            }
        }
    }

    struct Explain: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "İki ifadenin fonetik anahtarlarını ve benzerliğini göster."
        )

        @Argument(help: "Sözlükteki terim.")
        var term: String

        @Argument(help: "ASR'ın ürettiği bozuk hali.")
        var heard: String

        func run() async throws {
            let pairs = [("terim", term), ("duyulan", heard)]
            for (label, value) in pairs {
                print("\(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \"\(value)\"")
                print("  normalize  \(PhoneticKey.normalize(value))")
                print("  iskelet    \(PhoneticKey.skeleton(value))")
            }
            let full = EditDistance.similarity(
                PhoneticKey.normalize(term), PhoneticKey.normalize(heard))
            let skeletal = EditDistance.similarity(
                PhoneticKey.skeleton(term), PhoneticKey.skeleton(heard))
            print(String(format: "\nbenzerlik  tam %.3f  ·  iskelet %.3f", full, skeletal))
            print(String(format: "eşikler    tam %.2f  ·  iskelet %.2f",
                         Vocabulary.defaultThreshold, Vocabulary.defaultSkeletonThreshold))
        }
    }
}

/// Transcribe an audio file and print the result.
///
/// This exists before the daemon does on purpose: it is the harness that lets
/// every later change (engine version, custom vocabulary, post-processing) be
/// measured on the same fixed audio instead of on whatever happened to be said
/// into the microphone that time.
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bir ses dosyasını yazıya çevir (motor test koşum takımı)."
    )

    @Argument(help: "Ses dosyaları (wav/caf/m4a).")
    var files: [String] = []

    @Option(name: .long, help: "Motor: whisper (Türkçe) veya parakeet (hızlı, Türkçe YOK).")
    var engineName: EngineChoice = .whisper

    @Option(name: .long, help: "Whisper modeli: large-v3-turbo veya large-v3.")
    var whisperModel: WhisperModel = .largeV3Turbo

    @Option(name: .long, help: "Dil kodu.")
    var language: String = "tr"

    @Option(name: .long, help: "Ölçüm için tekrar sayısı.")
    var repeatCount: Int = 3

    @Option(name: .long, help: "Bu süreden uzun dosyaları reddet (saniye).")
    var maxSeconds: Double = 3600

    @Flag(name: .long, help: "Kalite kapılarını uygula (varsayılan: ham çıktıyı göster).")
    var strict: Bool = false

    @Flag(name: .long, help: "Config'deki sözlükle terim düzeltmesi uygula.")
    var vocabulary: Bool = false

    @Option(name: .long, help: "Son işleme: off, fillers, llm.")
    var refine: RefineMode?

    func validate() throws {
        guard repeatCount >= 1 else {
            throw ValidationError("--repeat-count en az 1 olmalı")
        }
        guard maxSeconds > 0 else {
            throw ValidationError("--max-seconds pozitif olmalı")
        }
    }

    func run() async throws {
        guard !files.isEmpty else {
            throw ValidationError("en az bir ses dosyası ver — örn: yaz transcribe ornek.wav")
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
            log("model indiriliyor — ilk çalıştırma birkaç dakika sürebilir")
        }

        let loadStart = Date()
        try await engine.prepare()
        log(String(format: "✓ %@ hazır — %.1f sn", engine.model, Date().timeIntervalSince(loadStart)))

        // `yaz transcribe` is a measurement harness: by default it shows what
        // the model produced, with the gates reported but not enforced.
        var options = strict ? TranscribeOptions() : .raw
        options.timeout = .seconds(Int(max(maxSeconds, 120)))

        var failures = 0
        for path in files {
            do {
                try await transcribeOne(path, engine: engine, options: options)
            } catch let error as YazError {
                failures += 1
                print("\n═══ \(URL(fileURLWithPath: path).lastPathComponent) ═══")
                print("  ✗ \(error.description)")
            }
        }

        await engine.release()
        if failures > 0 { throw ExitCode(1) }
    }

    private func transcribeOne(
        _ path: String, engine: any Transcriber, options: TranscribeOptions
    ) async throws {
        let samples = try AudioLoader.load(path, maxSeconds: maxSeconds)

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
            format: "  gecikme %.0f ms · RTF %.3f · tepe %.3f · rms %.3f",
            best * 1000, best / max(seconds, 0.001), output.level.peak, output.level.rms))

        if let signals = output.quality.signals {
            print(String(
                format: "  noSpeech %.2f · logProb %.2f · sıkıştırma %.2f",
                signals.noSpeechProb, signals.avgLogProb, signals.compressionRatio))
        } else {
            // Say so rather than printing zeros, which would look like a
            // flawless decode instead of a silent engine.
            print("  (motor güven sinyali vermiyor — karar yalnızca metne dayanıyor)")
        }

        switch output.quality.verdict {
        case .good:
            break
        case .lowConfidence(let reason):
            print("  ! \(reason)")
        case .rejected(let reason):
            print("  ✗ reddedildi: \(reason)")
        }

        var text = output.text
        if vocabulary || refine != nil {
            var config = Config.load()
            if !vocabulary { config.vocabulary = [] }
            if let refine { config.refine = refine }

            let started = Date()
            let processed = await TranscriptPipeline(config: config).process(text)
            let elapsed = Date().timeIntervalSince(started)

            for correction in processed.corrections {
                print(String(format: "  sözlük: %@ → %@ (%.3f, %@)",
                             correction.from, correction.to,
                             correction.score, correction.matchedBy.rawValue))
            }
            if let rejection = processed.refinementRejected {
                print("  son işleme atlandı: \(rejection)")
            }
            if processed.refined || !processed.corrections.isEmpty {
                print(String(format: "  son işleme %.0f ms", elapsed * 1000))
            }
            text = processed.text
        }
        print("  \(text.isEmpty ? "<boş>" : text)")
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

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
