import AppKit
import ApplicationServices

/// The frontmost app, and its focused element, through Accessibility.
///
/// The system-wide element is the usual way in, but some apps never answer
/// through it: Ghostty returns kAXErrorCannotComplete for both the focused
/// application and the focused element, while its own application element
/// gives the focused text area and its text. Measured 2026-11-14; until then
/// learning and the names on screen saw nothing in Ghostty, where most
/// dictations to coding agents go.
enum AXFocus {

    static func application(timeout: Float) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        if let app = element(system, kAXFocusedApplicationAttribute) {
            AXUIElementSetMessagingTimeout(app, timeout)
            return app
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func focusedElement(timeout: Float) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        let found = element(system, kAXFocusedUIElementAttribute)
            ?? application(timeout: timeout).flatMap { element($0, kAXFocusedUIElementAttribute) }
        if let found { AXUIElementSetMessagingTimeout(found, timeout) }
        return found
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
