import ApplicationServices
import Foundation

/// The visible text of the frontmost window, through Accessibility (which
/// yaz already holds for pasting). Bounded: at most `maxElements` elements,
/// `maxCharacters` characters and `budget` seconds, with a short messaging
/// timeout so a busy app cannot hold a dictation up. Secure fields are never
/// read.
enum ScreenReader {

    static let maxElements = 1_500
    static let maxCharacters = 40_000
    static let budget: TimeInterval = 0.25

    static func frontWindowText() -> String {
        let started = Date()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let app = element(system, kAXFocusedApplicationAttribute),
              let window = element(app, kAXFocusedWindowAttribute)
        else { return "" }
        AXUIElementSetMessagingTimeout(window, 0.1)

        var queue = [window]
        var head = 0
        var pieces: [String] = []
        var characters = 0
        while head < queue.count, head < maxElements, characters < maxCharacters,
              Date().timeIntervalSince(started) < budget {
            let node = queue[head]
            head += 1
            if string(node, kAXRoleAttribute) == "AXSecureTextField" { continue }
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(node, attribute), !text.isEmpty {
                    pieces.append(text)
                    characters += text.count
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return String(pieces.joined(separator: "\n").prefix(maxCharacters))
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
