import AppKit
import CoreGraphics
import Foundation

/// Puts transcribed text where the cursor is.
///
/// parrot types the transcript with `CGEventKeyboardSetUnicodeString` in
/// 20-character chunks, because that API has a per-event limit. Two problems
/// follow, and both hit exactly the apps a dictation tool is used in:
///
/// - A sentence becomes a dozen synthetic key events. Electron apps (Slack,
///   Notion, VS Code, Cursor) are known to drop characters from bursts like
///   this, so the transcript arrives mangled.
/// - It is slow, and the delay scales with how much you said.
///
/// yaz pastes instead: put the text on the pasteboard, synthesise ⌘V, restore
/// what was there before. One event, no length limit, and the target app sees
/// an ordinary paste. Typing remains available as a fallback for the rare
/// field that blocks paste.
enum TextInjector {

    enum Mode: String, CaseIterable, Sendable {
        /// Pasteboard + ⌘V. Reliable and fast; the default.
        case paste
        /// Synthesised unicode key events. Slower and lossy in Electron, but
        /// works where paste is blocked.
        case type

        var displayName: String {
            switch self {
            case .paste: "pano (⌘V)"
            case .type: "tuş tuş yazma"
            }
        }
    }

    /// Insert `text` at the current cursor position.
    @MainActor
    static func inject(_ text: String, mode: Mode = .paste) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch mode {
        case .paste: paste(trimmed)
        case .type: type(trimmed)
        }
    }

    // MARK: - Paste

    @MainActor
    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot everything, not just the string: the user's clipboard may
        // hold an image or a file promise, and coming back to find it replaced
        // by dictation would be worse than the dictation failing.
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Restore after the target app has had a chance to read the pasteboard.
        // There is no completion callback for a synthetic paste, so this is a
        // delay — chosen long enough for slow Electron apps, short enough that
        // a ⌘V of your own right after dictating still gets the old contents
        // back rather than a race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            restore(saved, to: pasteboard)
        }
    }

    /// Everything currently on the pasteboard, per type.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    /// Synthesise ⌘V.
    ///
    /// The events are posted with a source that carries no other modifiers, so
    /// a modifier the user is still holding — the push-to-talk key itself, for
    /// instance — cannot turn the paste into some other shortcut.
    @MainActor
    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 0x09

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Type

    /// Fallback path: post the text as unicode key events.
    ///
    /// `CGEventKeyboardSetUnicodeString` takes at most ~20 UTF-16 units per
    /// event, so long text is chunked. Chunks are split on grapheme-cluster
    /// boundaries — cutting mid-cluster would corrupt combining characters,
    /// and Turkish text is full of them.
    @MainActor
    static func type(_ text: String) {
        for chunk in chunks(of: text, maxUnits: 20) {
            var units = Array(chunk.utf16)
            guard !units.isEmpty else { continue }
            post(&units)
        }
    }

    /// Split into pieces of at most `maxUnits` UTF-16 units without ever
    /// breaking a grapheme cluster.
    static func chunks(of text: String, maxUnits: Int) -> [String] {
        guard maxUnits > 0 else { return [text] }
        var result: [String] = []
        var current = ""
        var currentUnits = 0

        for character in text {
            let size = String(character).utf16.count
            if currentUnits + size > maxUnits, !current.isEmpty {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    @MainActor
    private static func post(_ units: inout [UniChar]) {
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
