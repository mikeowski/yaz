import ApplicationServices
import Foundation

/// Reads the text of the focused field through Accessibility, which yaz
/// already holds for pasting. Used once, a few seconds after a dictation, to
/// see what the user fixed. Secure fields never expose a value.
enum FieldReader {

    /// Fields longer than this are documents, not inputs: aligning against
    /// them is slow and rarely right.
    static let maxLength = 20_000

    @MainActor
    static func focusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, role == "AXSecureTextField" {
            return nil
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, !text.isEmpty, text.count <= maxLength
        else { return nil }
        return text
    }

    /// Delete `pasted` from the focused field if it ends exactly at the caret
    /// with nothing selected. Through Accessibility, no keystrokes: an app
    /// that does not support setting the selection is left untouched.
    @MainActor
    static func deleteBeforeCaret(_ pasted: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return false }
        let element = focused as! AXUIElement

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
