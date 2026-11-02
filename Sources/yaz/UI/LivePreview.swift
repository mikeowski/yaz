import Foundation

/// What the pill shows of a live transcript: the newest words, never a word
/// cut in half.
enum LivePreview {

    static let maxCharacters = 56

    static func tail(of text: String, max: Int = maxCharacters) -> String {
        let trimmed = WhisperTranscriber.sanitize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > max else { return trimmed }
        let cut = trimmed.suffix(max)
        // Start at the next word boundary, so the first word is whole.
        if let space = cut.firstIndex(of: " ") {
            return "…" + cut[cut.index(after: space)...]
        }
        return "…" + cut
    }
}
