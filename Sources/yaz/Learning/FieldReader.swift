import AppKit
import ApplicationServices
import Foundation

/// Reads the text of the focused field through Accessibility, which yaz
/// already holds for pasting. Used once, a few seconds after a dictation, to
/// see what the user fixed. Secure fields never expose a value.
enum FieldReader {

    /// Longer than this, only the end is read: aligning against a whole
    /// document is slow and rarely right.
    static let maxLength = 20_000

    @MainActor private static var enabled = Set<pid_t>()

    /// Electron and Chromium apps (Slack, VS Code, Notion, Discord, Cursor)
    /// build their accessibility tree only when an assistive app asks for
    /// it, and until then a text field has no readable value. This is the
    /// documented request (`AXManualAccessibility`); other apps ignore it.
    /// Once per process.
    @MainActor
    static func enableAccessibility(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let pid = app.processIdentifier
            guard !enabled.contains(pid) else { continue }
            enabled.insert(pid)
            AXUIElementSetAttributeValue(
                AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// How long one Accessibility call may wait for the app. The default is
    /// 6 s; an app that hangs would hold the caller that long, every second
    /// of the read-back.
    static let timeout: Float = 0.25

    /// Not main-actor bound: the read-back calls it off the main thread, where
    /// a slow app cannot stall the hotkey.
    static func focusedText() -> String? {
        guard let element = AXFocus.focusedElement(timeout: timeout) else { return nil }

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, role == "AXSecureTextField" {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty
        else { return nil }
        return tail(of: text)
    }

    /// A long value keeps its end. A terminal's text area is its whole
    /// scrollback, with the prompt being typed into at the bottom; a long
    /// document without the dictation near the end reads as "gone", which
    /// learns nothing, as no reading did before.
    static func tail(of text: String) -> String {
        text.count <= maxLength ? text : String(text.suffix(maxLength))
    }

    /// Delete `pasted` from the focused field if it ends exactly at the caret
    /// with nothing selected. Through Accessibility, no keystrokes: an app
    /// that does not support setting the selection is left untouched.
    @MainActor
    static func deleteBeforeCaret(_ pasted: String) -> Bool {
        guard let element = AXFocus.focusedElement(timeout: timeout) else { return false }

        var value: CFTypeRef?
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return false }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.length == 0,
              let target = UndoDictation.range(value: text, caret: selection.location, pasted: pasted)
        else { return false }

        var cfRange = CFRange(location: target.location, length: target.length)
        guard let newRange = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, newRange) == .success,
              AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, "" as CFString) == .success
        else { return false }

        var after: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &after) == .success,
              let afterText = after as? String
        else { return false }
        return afterText.utf16.count == text.utf16.count - target.length
    }
}
