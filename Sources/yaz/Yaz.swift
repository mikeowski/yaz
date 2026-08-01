import ArgumentParser
import FluidAudio
import Foundation

@main
struct Yaz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yaz",
        abstract: "Türkçe konuşan geliştiriciler için on-device dikte. Bas-konuş, bırak, metin imlece gelir.",
        subcommands: [Run.self, Doctor.self, Transcribe.self, Models.self, Vocab.self],
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

        if !skipDoctor {
            let checks = DoctorReport.run(config: config)
            guard DoctorReport.canRun(checks) else {
                log("başlangıç kontrolleri başarısız:\n")
                DoctorReport.render(checks)
                log("\nyukarıdakileri düzelt ya da --skip-doctor kullan")
                throw ExitCode(1)
            }
        }

        try await Daemon(config: config, verbose: verbose).run()
    }
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

/// Inspect and exercise the vocabulary layer.
///
/// Correction is a rules engine with thresholds, and thresholds need to be
/// tuned against real garbled output rather than guessed. This command is how
/// that is done — by the author while building it, and by the user when a term
/// of theirs is not being caught.
struct Vocab: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sözlük düzeltmesini dene ve puanları göster.",
        subcommands: [Test.self, Explain.self]
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
        if vocabulary {
            let corrected = Vocabulary(terms: Config.load().vocabulary).correct(text)
            for correction in corrected.corrections {
                print(String(format: "  sözlük: %@ → %@ (%.3f, %@)",
                             correction.from, correction.to,
                             correction.score, correction.matchedBy.rawValue))
            }
            text = corrected.text
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

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
