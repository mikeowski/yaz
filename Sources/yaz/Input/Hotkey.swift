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
        case .rightOption: "right option"
        case .rightCommand: "right command"
        case .rightControl: "right control"
        case .rightShift: "right shift"
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
                return "no Accessibility permission — System Settings → Privacy & Security → Accessibility"
            case .tapCreationFailed:
                return "couldn't install the keyboard listener (CGEvent tap)"
            }
        }
    }

    private let hotkey: Hotkey
    private let debug: Bool
    private var handler: (@Sendable (Event) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    /// Raw modifier events logged at startup, then it goes quiet.
    ///
    /// "The hotkey does nothing" has two very different causes — the tap never
    /// sees the key, or it sees it and the mask does not match — and no way to
    /// tell them apart without looking at what actually arrives. Logging the
    /// first handful answers that on any machine without asking the user to
    /// run anything special.
    fileprivate var eventsLogged = 0
    private static let eventsToLog = 8

    /// Fired when the tap has been installed for a while and has never seen a
    /// single event — the signature of a stale permission record.
    var onSilentTap: (() -> Void)?
    private var watchdog: Timer?

    /// Long enough that ordinary use will have produced a shift or command
    /// press, short enough that the user has not yet given up.
    private static let silenceTimeout: TimeInterval = 75

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
        log("hotkey listener installed for \(hotkey.rawValue) (mask \(String(hotkey.flag.rawValue, radix: 16)))")

        startSilenceWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
        isDown = false
    }

    /// Watch for a tap that is alive but deaf.
    ///
    /// The worst failure this project hit: `AXIsProcessTrusted()` true,
    /// `IOHIDCheckAccess` granted, `CGEvent.tapCreate` successful, tap enabled
    /// — and not one event ever delivered, because the TCC records were stale
    /// after the app bundle was replaced. Nothing in the system reports that;
    /// the only observable is silence, so silence has to be the signal.
    private func startSilenceWatchdog() {
        watchdog?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.silenceTimeout, repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.eventsLogged == 0 else { return }
                let enabled = self.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
                log("warning: the keyboard listener has seen no events in"
                    + " \(Int(Self.silenceTimeout))s (tap enabled=\(enabled))")
                log("  macOS reports the permissions as granted but is not delivering events.")
                log("  This usually means the permission records went stale after the app")
                log("  was replaced. Fix: yaz reset-permissions, then grant them again.")
                self.onSilentTap?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// macOS disables a tap that misbehaves or times out. Turning it back on is
    /// the difference between a daemon that survives the day and one that
    /// stops responding without saying anything.
    fileprivate func reenable() {
        guard let tap else { return }
        log("warning: the system disabled the keyboard listener — re-enabling")
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

        if debug || eventsLogged < Self.eventsToLog {
            eventsLogged += 1
            log("  modifier event: flags=\(String(flags.rawValue, radix: 16))"
                + " keycode=\(keyCode) wanted=\(String(hotkey.flag.rawValue, radix: 16))"
                + " match=\(held)")
            if eventsLogged == Self.eventsToLog {
                log("  (further modifier events will not be logged)")
            }
        }

        // First real event: the tap is genuinely delivering, so the watchdog
        // has nothing to warn about.
        watchdog?.invalidate()
        watchdog = nil

        guard held != isDown else { return }
        isDown = held
        // Logged unconditionally, not behind --verbose: when the hotkey does
        // nothing, whether the tap saw the key at all is the first question
        // and there was previously no way to answer it.
        log("hotkey \(held ? "down" : "up")")
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
