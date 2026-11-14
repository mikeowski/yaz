import Foundation

/// A file of the user's that yaz could not read. Loading falls back to
/// defaults, and the next save would then write those defaults over
/// everything the user had: vocabulary, app profiles, what was learned. The
/// file is moved aside first, so a typo or a newer format costs nothing.
enum DataFile {

    /// Move `url` to `<name>.broken-<date>` next to it. Returns the new
    /// location, or nil if there was nothing to move or the move failed.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).broken-\(formatter.string(from: now))")
        do {
            try? manager.removeItem(at: target)
            try manager.moveItem(at: url, to: target)
            log("! \(url.lastPathComponent) could not be read — kept as \(target.lastPathComponent)")
            return target
        } catch {
            log("! \(url.lastPathComponent) could not be read, nor moved aside: \(error.localizedDescription)")
            return nil
        }
    }
}
