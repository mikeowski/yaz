import Foundation
import WhisperKit

/// Fetches model weights, with progress.
///
/// The models are **not** bundled. `yaz.app` is 14 MB; `large-v3-turbo` is
/// 1.6 GB, which would make the download of the app itself a hundred times
/// larger and pin every user to one checkpoint. So the first run fetches them.
///
/// What matters is that the first run *says so*. Without progress the app sits
/// there for several minutes on a fresh machine doing nothing visible, which
/// is indistinguishable from being broken — and on this project it already
/// was: the menu read "loading model…" with no indication that 1.6 GB was
/// moving behind it.
enum ModelDownloader {

    /// A point in the download, ready to be shown to a human.
    struct Progress: Sendable, Equatable {
        /// 0…1, or nil when the total size is not yet known.
        let fraction: Double?
        let completedBytes: Int64
        let totalBytes: Int64

        var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }

        /// "412 MB of 1.6 GB (26%)", or a byte count while the total is unknown.
        var description: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let done = formatter.string(fromByteCount: completedBytes)
            guard totalBytes > 0 else { return done }
            let total = formatter.string(fromByteCount: totalBytes)
            guard let percent else { return "\(done) of \(total)" }
            return "\(done) of \(total) (\(percent)%)"
        }
    }

    /// Download `model` unless it is already complete on disk.
    ///
    /// Reports progress on an arbitrary thread; hop to the main actor before
    /// touching UI. Returns immediately when the weights are already present,
    /// so it is safe to call on every launch.
    @discardableResult
    static func ensure(
        _ model: WhisperModel,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Bool {
        if ModelStore.status(for: model.whisperKitID).isComplete { return false }

        do {
            _ = try await WhisperKit.download(
                variant: model.whisperKitID,
                downloadBase: nil,
                useBackgroundSession: false
            ) { progress in
                onProgress?(Progress(
                    // `fractionCompleted` is 0 until the total is known; report
                    // nil rather than a confident zero that never moves.
                    fraction: progress.totalUnitCount > 0 ? progress.fractionCompleted : nil,
                    completedBytes: progress.completedUnitCount,
                    totalBytes: progress.totalUnitCount))
            }
        } catch {
            throw YazError.modelLoadFailed(model: model.id, underlying: "\(error)")
        }
        return true
    }

    /// Human-readable one-liner for a model that is not on disk yet.
    static func downloadNotice(for model: WhisperModel) -> String {
        "downloading \(model.rawValue) (~\(model.sizeMB) MB) — first run only"
    }
}
