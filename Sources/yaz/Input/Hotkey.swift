import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A push-to-talk key.
///
/// parrot documents `--hotkey right-option` in its README but never implements
/// it: the flag does not exist and the monitor is hard-wired to Fn. That gap is
/// the reason this type exists — on macOS the Fn key is contested (the system
/// maps it to emoji, dictation, or input switching), so "just use Fn" is not a
/// complete answer for everyone.
enum Hotkey: String, CaseIterable, Sendable {
    case fn
    case rightOption = "right-option"
    case rightCommand = "right-command"
    case rightControl = "right-control"
    case rightShift = "right-shift"

    var displayName: String {
        switch self {
        case .fn: "fn (🌐)"
        case .rightOption: "sağ option"
        case .rightCommand: "sağ command"
        case .rightControl: "sağ control"
        case .rightShift: "sağ shift"
        }
    }

    /// The modifier mask that must be present for the key to count as held.
    var flag: CGEventFlags {
        switch self {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .rightShift: .maskShift
        }
    }

    /// Virtual key code for the specific physical key, where the modifier mask
    /// alone cannot tell left from right. Fn has no separate keycode.
    var keyCode: CGKeyCode? {
        switch self {
        case .fn: nil
        case .rightOption: 0x3D
        case .rightCommand: 0x36
        case .rightControl: 0x3E
        case .rightShift: 0x3C
        }
    }

    /// Whether this key needs the macOS "Press 🌐 key to → Do Nothing" setting.
    var conflictsWithSystemFnAction: Bool { self == .fn }
}

/// Watches one modifier key and reports press/release edges.
///
/// Uses a listen-only `CGEventTap`, which requires Accessibility permission.
/// The tap is re-enabled automatically when macOS disables it: the system kills
/// taps that run long or block, and parrot's response is a comment saying "let
/// the user restart" — for a daemon meant to run all day that is a silent
/// death.
final class HotkeyMonitor: @unchecked Sendable {

    enum Event: Sendable { case pressed, released }

    enum MonitorError: Error, CustomStringConvertible {
        case accessibilityDenied
        case tapCreationFailed

        var description: String {
            switch self {
            case .accessibilityDenied:
                return "Erişilebilirlik izni yok — Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik"
            case .tapCreationFailed:
                return "klavye dinleyicisi kurulamadı (CGEvent tap)"
            }
        }
    }

    private let hotkey: Hotkey
    private let debug: Bool
    private var handler: (@Sendable (Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    init(hotkey: Hotkey = .fn, debug: Bool = false) {
        self.hotkey = hotkey
        self.debug = debug
    }

    /// Whether the process may post and observe events. Checked without
    /// prompting so `yaz doctor` can report state without side effects.
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the Accessibility prompt.
    static func requestAccessibilityPermission() {
        // The SDK exposes kAXTrustedCheckOptionPrompt as a global `var`, which
        // Swift 6 will not let us touch across isolation. Its value is the
        // documented, stable string constant.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func start(onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard Self.hasAccessibilityPermission else { throw MonitorError.accessibilityDenied }
        handler = onEvent

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw MonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
        isDown = false
    }

    /// macOS disables a tap that misbehaves or times out. Turning it back on is
    /// the difference between a daemon that survives the day and one that
    /// stops responding without saying anything.
    fileprivate func reenable() {
        guard let tap else { return }
        log("uyarı: klavye dinleyicisi sistem tarafından kapatıldı — yeniden açılıyor")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Takes plain values rather than the `CGEvent`: the event is not
    /// `Sendable` and must not cross to the main queue, but the two numbers we
    /// need are read cheaply inside the callback.
    fileprivate func handle(flags: CGEventFlags, keyCode: CGKeyCode) {
        let flagHeld = flags.contains(hotkey.flag)

        // For left/right pairs the mask cannot distinguish sides, so confirm
        // the physical key from the event's keycode. Any flagsChanged event
        // from the *other* side of the same modifier is ignored.
        let held: Bool
        if let expected = hotkey.keyCode {
            if keyCode != expected {
                // A different modifier changed; only trust it to release us.
                held = isDown && flagHeld
            } else {
                held = flagHeld
            }
        } else {
            held = flagHeld
        }

        if debug {
            log("  [debug] flags=\(String(flags.rawValue, radix: 16)) keycode=\(keyCode) held=\(held)")
        }

        guard held != isDown else { return }
        isDown = held
        handler?(held ? .pressed : .released)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { monitor.reenable() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

    // Read what we need here, synchronously, while the event is alive and
    // owned by this callback.
    let flags = event.flags
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    DispatchQueue.main.async { monitor.handle(flags: flags, keyCode: keyCode) }
    return Unmanaged.passUnretained(event)
}
