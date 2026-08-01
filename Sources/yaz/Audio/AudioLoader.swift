import AVFoundation
import Foundation

/// Decodes any AVFoundation-readable file into the one format every speech
/// model in this project wants: 16 kHz, mono, Float32.
///
/// Reads and converts in bounded windows rather than allocating the whole file
/// twice. A one-hour recording at 48 kHz stereo is ~690 MB as a single Float32
/// buffer; the streaming path holds one 1-second window at a time and only the
/// (much smaller) 16 kHz mono result grows.
enum AudioLoader {

    /// Target format for every engine in yaz.
    static let sampleRate: Double = 16_000

    /// Frames of *source* audio converted per iteration.
    private static let windowFrames: AVAudioFrameCount = 1 << 15  // 32768

    /// Decode `path` to 16 kHz mono Float32 samples.
    ///
    /// - Parameter maxSeconds: refuse files longer than this. Guards against
    ///   pointing the CLI at a podcast and waiting minutes for an answer.
    static func load(_ path: String, maxSeconds: Double = 3600) throws -> [Float] {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        // Check existence first. AVAudioFile reports a missing file as an
        // opaque CoreAudio status ("Code=2003334207"), which buries the one
        // thing the user needs to know.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            throw YazError.audioUnreadable(path: path, underlying: "file not found")
        }
        guard !isDirectory.boolValue else {
            throw YazError.audioUnreadable(path: path, underlying: "that is a directory")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw YazError.audioUnreadable(
                path: path, underlying: "couldn't open it as audio (\(url.pathExtension) may be unsupported)")
        }

        let sourceFormat = file.processingFormat
        guard file.length > 0 else { throw YazError.audioEmpty(path: path) }
        guard sourceFormat.sampleRate > 0 else {
            throw YazError.audioFormatUnsupported(path: path, format: "\(sourceFormat)")
        }

        let seconds = Double(file.length) / sourceFormat.sampleRate
        guard seconds <= maxSeconds else {
            throw YazError.audioTooLong(path: path, seconds: seconds, limit: maxSeconds)
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw YazError.audioConversionFailed(path: path, detail: "couldn't build the target format")
        }

        // Same-format files still go through the converter: it is a no-op cost
        // next to inference, and one code path is worth more than the saving.
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw YazError.audioFormatUnsupported(path: path, format: "\(sourceFormat)")
        }

        let ratio = sampleRate / sourceFormat.sampleRate
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        // Drive the loop from framePosition, not from a zero-length read.
        // AVAudioFile.read(into:) does not return 0 frames at EOF — it throws,
        // and Foundation bridges that to a bare _GenericObjCError.nilError.
        // Reading one window past the end is the difference between a clean
        // decode and an unexplained failure.
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            guard let input = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: min(windowFrames, remaining)
            ) else {
                throw YazError.audioConversionFailed(path: path, detail: "couldn't allocate the input buffer")
            }

            do {
                try file.read(into: input)
            } catch {
                throw YazError.audioUnreadable(path: path, underlying: "\(error)")
            }
            // A short read that makes no progress would spin forever.
            guard input.frameLength > 0 else { break }

            samples.append(contentsOf: try convert(
                input, using: converter, to: target, ratio: ratio, path: path))
        }

        // Sample-rate converters hold a few frames internally; drain them so
        // the tail of the last word is not clipped.
        samples.append(contentsOf: try drain(converter, to: target, path: path))

        return samples
    }

    /// Convert 16 kHz mono Float32 samples that are already in memory — the
    /// path the daemon uses, where audio comes from the microphone tap rather
    /// than a file. Present so callers have one place to reason about limits.
    static func validate(
        _ samples: [Float],
        minSeconds: Double = SpeechGate.defaultMinSeconds
    ) throws {
        let seconds = Double(samples.count) / sampleRate
        guard seconds >= minSeconds else {
            throw YazError.audioTooShort(seconds: seconds, minimum: minSeconds)
        }
    }

    // MARK: -

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to target: AVAudioFormat,
        ratio: Double,
        path: String
    ) throws -> [Float] {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw YazError.audioConversionFailed(path: path, detail: "couldn't allocate the output buffer")
        }

        // AVAudioConverterInputBlock is @Sendable but runs synchronously inside
        // convert(). The box hands the window over exactly once, then reports
        // starvation so the converter returns instead of blocking.
        let feed = BufferFeed(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        if let error {
            throw YazError.audioConversionFailed(path: path, detail: "\(error.localizedDescription)")
        }
        guard status != .error else {
            throw YazError.audioConversionFailed(path: path, detail: "the converter reported an error")
        }
        return output.floats
    }

    /// Pull whatever the converter still holds after the last input window.
    private static func drain(
        _ converter: AVAudioConverter,
        to target: AVAudioFormat,
        path: String
    ) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            return []
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        // A converter with nothing buffered reports endOfStream; that is the
        // expected outcome here, not a failure.
        if status == .error, let error {
            throw YazError.audioConversionFailed(path: path, detail: "\(error.localizedDescription)")
        }
        return output.floats
    }
}

/// Single-shot handoff of one buffer into an `@Sendable` converter block.
private final class BufferFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

extension AVAudioPCMBuffer {
    /// The first channel's frames as a Swift array. Empty when the buffer is
    /// not float-backed.
    var floats: [Float] {
        guard let channel = floatChannelData, frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(frameLength)))
    }
}
