import ArgumentParser
import FluidAudio
import AVFoundation
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

    @Option(name: .long, help: "Motor: whisper (Türkçe) veya parakeet (hızlı, İngilizce).")
    var engineName: EngineChoice = .whisper

    @Option(name: .long, help: "Whisper modeli: large-v3-turbo veya large-v3.")
    var whisperModel: WhisperModel = .largeV3Turbo

    @Option(name: .long, help: "Dil kodu (whisper motoru için).")
    var language: String = "tr"

    @Option(name: .long, help: "Ölçüm için tekrar sayısı.")
    var repeatCount: Int = 3

    func run() async throws {
        guard !files.isEmpty else {
            throw ValidationError("en az bir ses dosyası ver — örn: yaz transcribe ornek.wav")
        }

        let engine: any Transcriber = switch engineName {
        case .whisper: WhisperTranscriber(model: whisperModel, language: language)
        case .parakeet: ParakeetTranscriber(version: .v3)
        }

        let loadStart = Date()
        try await engine.prepare()
        log(String(format: "✓ %@ hazır — %.1f sn", engine.model, Date().timeIntervalSince(loadStart)))

        for path in files {
            let samples = try Self.loadSamples(path)
            let seconds = Double(samples.count) / 16_000

            var best = Double.infinity
            var output: TranscriptionOutput?
            for i in 0..<max(1, repeatCount) {
                let t0 = Date()
                let result = try await engine.transcribe(samples)
                let elapsed = Date().timeIntervalSince(t0)
                // First pass warms lazily-built Core ML state; ignore it when
                // more than one pass was requested.
                if i > 0 || repeatCount == 1 { best = min(best, elapsed) }
                output = result
            }

            print("\n═══ \(URL(fileURLWithPath: path).lastPathComponent) (\(String(format: "%.2f", seconds)) sn) ═══")
            print(String(format: "  gecikme %.0f ms · RTF %.3f", best * 1000, best / max(seconds, 0.001)))
            print("  \(output?.text.isEmpty == false ? output!.text : "<boş>")")
        }

        await engine.release()
    }

    /// Decode any AVFoundation-readable file to 16 kHz mono Float32 — the one
    /// format every speech model in this project wants.
    static func loadSamples(_ path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let file = try AVAudioFile(forReading: url)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ValidationError("16 kHz mono hedef format kurulamadı") }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw ValidationError("\(path): \(file.processingFormat) formatı dönüştürülemedi")
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw ValidationError("çıkış tamponu ayrılamadı")
        }

        // Read the whole file first, then feed the converter once. Pulling in
        // chunks from inside the input block makes AVAudioFile.read fail with
        // a bare _GenericObjCError.nilError on the second call; a single
        // buffer sidesteps that and fixtures are seconds long anyway.
        guard let source = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw ValidationError("giriş tamponu ayrılamadı") }
        try file.read(into: source)

        // The block is called synchronously inside convert(), but it is typed
        // @Sendable, so the "already delivered" flag needs a reference box.
        final class Feed: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            init(_ b: AVAudioPCMBuffer) { buffer = b }
        }
        let feed = Feed(source)

        let input: AVAudioConverterInputBlock = { _, status in
            guard let next = feed.buffer else {
                status.pointee = .noDataNow
                return nil
            }
            feed.buffer = nil
            status.pointee = .haveData
            return next
        }

        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: input)
        if let error { throw error }
        guard status != .error else { throw ValidationError("\(path): ses dönüştürülemedi") }

        guard let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
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
