import Foundation

/// Every failure yaz can surface, with a message the user can act on.
///
/// This type exists because the alternative is what the first prototype did:
/// an `AVAudioFile` call failed, Foundation bridged it to a bare
/// `_GenericObjCError.nilError`, and the CLI printed `Error: nilError`. That
/// tells nobody anything. Anything thrown out of yaz should name the file, the
/// limit, or the setting involved.
enum YazError: Error, CustomStringConvertible, Equatable {

    // MARK: Audio input

    case audioUnreadable(path: String, underlying: String)
    case audioEmpty(path: String)
    case audioTooLong(path: String, seconds: Double, limit: Double)
    case audioFormatUnsupported(path: String, format: String)
    case audioConversionFailed(path: String, detail: String)

    // MARK: Engine

    case engineNotPrepared(engine: String)
    case modelLoadFailed(model: String, underlying: String)
    case transcriptionFailed(engine: String, underlying: String)
    case transcriptionTimedOut(engine: String, seconds: Double)
    case languageUnsupported(engine: String, language: String, supported: [String])

    // MARK: Post-processing

    case refinementTimedOut(seconds: Double)
    case refinerUnavailable(detail: String)

    // MARK: Install

    case launchAgentFailed(action: String, detail: String)

    // MARK: Input signal

    case audioTooShort(seconds: Double, minimum: Double)
    case audioSilent(peak: Float, threshold: Float)

    var description: String {
        switch self {
        case .audioUnreadable(let path, let underlying):
            return "can't read \(path): \(underlying)"
        case .audioEmpty(let path):
            return "\(path) is empty — no audio frames"
        case .audioTooLong(let path, let seconds, let limit):
            return String(
                format: "%@ is too long (%.1f s, limit %.0f s) — raise it with --max-seconds",
                path, seconds, limit)
        case .audioFormatUnsupported(let path, let format):
            return "unsupported audio format in \(path): \(format)"
        case .audioConversionFailed(let path, let detail):
            return "couldn't convert \(path) to 16 kHz mono: \(detail)"

        case .engineNotPrepared(let engine):
            return "\(engine) was used before prepare()"
        case .modelLoadFailed(let model, let underlying):
            return "couldn't load \(model): \(underlying)"
        case .transcriptionFailed(let engine, let underlying):
            return "\(engine) failed to transcribe: \(underlying)"
        case .transcriptionTimedOut(let engine, let seconds):
            return String(format: "%@ did not respond within %.0f s — cancelled", engine, seconds)
        case .languageUnsupported(let engine, let language, let supported):
            return "the \(engine) engine does not support '\(language)'"
                + " (supported: \(supported.prefix(8).joined(separator: ", "))…)"

        case .refinementTimedOut(let seconds):
            return String(format: "post-processing did not finish within %.0f s — kept the raw text", seconds)
        case .refinerUnavailable(let detail):
            return "post-processing unavailable: \(detail)"

        case .launchAgentFailed(let action, let detail):
            return "launchctl \(action) failed: \(detail)"

        case .audioTooShort(let seconds, let minimum):
            return String(
                format: "recording too short (%.2f s, needs at least %.2f s)", seconds, minimum)
        case .audioSilent(let peak, let threshold):
            return String(format: "no sound in the recording (peak %.4f, threshold %.4f)", peak, threshold)
        }
    }

    /// True when the condition is the user's recording rather than a fault:
    /// too short, or silence. The daemon should drop these quietly instead of
    /// showing an error — pressing the hotkey by accident is not a crash.
    var isBenignInput: Bool {
        switch self {
        case .audioTooShort, .audioSilent, .audioEmpty: true
        default: false
        }
    }
}
