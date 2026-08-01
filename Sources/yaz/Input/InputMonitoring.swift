import Foundation
import IOKit.hid

/// The second permission a dictation app needs, and the one nobody expects.
///
/// Accessibility is not enough to *listen* to the keyboard. A `CGEventTap` on
/// key events also requires **Input Monitoring**
/// (`kTCCServiceListenEvent`), which is a separate switch in a separate list
/// in System Settings.
///
/// The failure mode is silent and total, which is what makes it worth its own
/// type: `AXIsProcessTrusted()` returns true, `CGEvent.tapCreate` returns a
/// valid tap, the run loop source installs without complaint — and not one
/// event ever arrives. Measured here: Accessibility granted, tap created,
/// zero modifier events in the log. parrot checks only Accessibility and would
/// hit exactly the same wall.
enum InputMonitoring {

    enum State: Sendable, Equatable {
        case granted
        case denied
        /// Never asked. Requesting will show the system prompt.
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    static var state: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }

    /// Ask macOS for the permission, showing its prompt.
    ///
    /// Returns whether it was granted immediately. A `false` is normal: the
    /// prompt sends the user to System Settings and the answer arrives later,
    /// so callers should poll `state` rather than trust the return value.
    @discardableResult
    static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Where the user has to go, spelled out. The list is not the one they
    /// were just in for Accessibility, which is the whole problem.
    static let settingsPath =
        "System Settings → Privacy & Security → Input Monitoring"

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// One-line explanation of why this is needed, for alerts and the menu.
    static let rationale = """
        yaz watches for the push-to-talk key, which macOS treats as monitoring \
        keyboard input. This is separate from Accessibility and has its own \
        list in System Settings.
        """
}
