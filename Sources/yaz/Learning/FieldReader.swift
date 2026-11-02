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
}
