import AVFoundation
import Accelerate
import Foundation

/// Captures microphone audio while the hotkey is held and returns 16 kHz mono
/// Float32 samples on release.
///
/// Deliberately does **not** enable Apple's voice processing. quill's rca-001
/// documents what that costs: `setVoiceProcessingEnabled(true)` is not an input
/// effect but a duplex I/O unit, and configuring it wrong yields a
/// correctly-timed, digitally silent recording with no error anywhere. Its only
/// benefit — echo cancellation — is irrelevant for push-to-talk dictation,
/// where nothing is playing back into the mic that matters.
///
/// The liveness check survives from that investigation, because the underlying
/// failure is not specific to voice processing: a device can deliver callbacks
/// full of zeros. Buffers arriving is not evidence that audio is arriving.
final class AudioCapture: @unchecked Sendable {

    enum CaptureError: Error, CustomStringConvertible {
        case engineStartFailed(String)
        case converterUnavailable(String)

        var description: String {
            switch self {
            case .engineStartFailed(let detail):
                return "couldn't start the microphone: \(detail)"
            case .converterUnavailable(let format):
                return "couldn't convert the microphone format to 16 kHz mono: \(format)"
            }
        }
    }

    /// Called on an arbitrary thread with each buffer's peak level (0…1), for
    /// the recording indicator.
    var onLevel: (@Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false
    private var sawSignal = false

    /// Hard ceiling on a single held-key recording. Without it, a stuck
    /// modifier key grows the buffer until the machine swaps — 16 kHz mono
    /// Float32 is 3.7 MB per minute, so ten minutes is a deliberate stop, not
    /// a limit anyone will hit by speaking.
    private let maxSamples = Int(10 * 60 * AudioLoader.sampleRate)
    private var hitLimit = false

    var isRecording: Bool { lock.withLock { running } }

    /// Begin capturing. Idempotent.
    func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        samples.removeAll(keepingCapacity: true)
        sawSignal = false
        hitLimit = false
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioLoader.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.converterUnavailable("\(inputFormat)")
        }

        // Tap in the device's native format and convert inside the callback:
        // asking the tap for a format the hardware does not produce is how you
        // end up with an empty file.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, target: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed("\(error.localizedDescription)")
        }

        lock.withLock { running = true }
    }

    /// Stop capturing and return everything collected. Idempotent; a second
    /// call returns an empty buffer rather than the previous recording.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        guard running else { lock.unlock(); return [] }
        running = false
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        return lock.withLock {
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return captured
        }
    }

    /// True once any buffer carried a non-zero sample. A whole recording of
    /// digital zeros means the route is broken, not that the user was quiet —
    /// worth telling them apart in the log.
    var didSeeSignal: Bool { lock.withLock { sawSignal } }

    /// True when the recording was cut short by `maxSamples`.
    var didHitLimit: Bool { lock.withLock { hitLimit } }

    // MARK: -

    private func append(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return
        }

        let feed = BufferHandoff(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }
        guard status != .error, error == nil else { return }

        let chunk = output.floats
        guard !chunk.isEmpty else { return }

        var peak: Float = 0
        chunk.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(pointer.count))
        }

        lock.lock()
        if peak > 0 { sawSignal = true }
        if samples.count < maxSamples {
            samples.append(contentsOf: chunk)
        } else {
            hitLimit = true
        }
        lock.unlock()

        onLevel?(peak)
    }
}

/// Hands one buffer to an `@Sendable` converter block exactly once.
private final class BufferHandoff: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
