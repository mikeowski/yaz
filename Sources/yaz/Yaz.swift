import ArgumentParser
import FluidAudio
import Foundation

@main
struct Yaz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yaz",
        abstract: "Türkçe konuşan geliştiriciler için on-device dikte. Bas-konuş, bırak, metin imlece gelir.",
        subcommands: [Transcribe.self],
        defaultSubcommand: Transcribe.self
    )
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

        let signals = output.quality.signals
        if signals != TranscriptionQuality.Signals() {
            print(String(
                format: "  noSpeech %.2f · logProb %.2f · sıkıştırma %.2f",
                signals.noSpeechProb, signals.avgLogProb, signals.compressionRatio))
        }

        switch output.quality.verdict {
        case .good:
            break
        case .lowConfidence(let reason):
            print("  ! \(reason)")
        case .rejected(let reason):
            print("  ✗ reddedildi: \(reason)")
        }

        print("  \(output.text.isEmpty ? "<boş>" : output.text)")
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

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
