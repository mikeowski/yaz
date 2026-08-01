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

    // MARK: Input signal

    case audioTooShort(seconds: Double, minimum: Double)
    case audioSilent(peak: Float, threshold: Float)

    var description: String {
        switch self {
        case .audioUnreadable(let path, let underlying):
            return "\(path) okunamadı: \(underlying)"
        case .audioEmpty(let path):
            return "\(path) boş — hiç ses karesi yok"
        case .audioTooLong(let path, let seconds, let limit):
            return String(
                format: "%@ çok uzun (%.1f sn, sınır %.0f sn) — --max-seconds ile artır",
                path, seconds, limit)
        case .audioFormatUnsupported(let path, let format):
            return "\(path) formatı desteklenmiyor: \(format)"
        case .audioConversionFailed(let path, let detail):
            return "\(path) 16 kHz mono'ya çevrilemedi: \(detail)"

        case .engineNotPrepared(let engine):
            return "\(engine) motoru prepare() çağrılmadan kullanıldı"
        case .modelLoadFailed(let model, let underlying):
            return "\(model) yüklenemedi: \(underlying)"
        case .transcriptionFailed(let engine, let underlying):
            return "\(engine) çeviri yapamadı: \(underlying)"
        case .transcriptionTimedOut(let engine, let seconds):
            return String(format: "%@ %.0f sn içinde yanıt vermedi — iptal edildi", engine, seconds)
        case .languageUnsupported(let engine, let language, let supported):
            return "\(engine) motoru '\(language)' dilini desteklemiyor"
                + " (desteklenen: \(supported.prefix(8).joined(separator: ", "))…)"

        case .refinementTimedOut(let seconds):
            return String(format: "son işleme %.0f sn içinde bitmedi — ham metin kullanıldı", seconds)
        case .refinerUnavailable(let detail):
            return "son işleme kullanılamıyor: \(detail)"

        case .audioTooShort(let seconds, let minimum):
            return String(
                format: "kayıt çok kısa (%.2f sn, en az %.2f sn gerekli)", seconds, minimum)
        case .audioSilent(let peak, let threshold):
            return String(format: "kayıtta ses yok (tepe %.4f, eşik %.4f)", peak, threshold)
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
