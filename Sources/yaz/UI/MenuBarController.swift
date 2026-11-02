import AppKit

/// The menu bar item: a status glyph, and the answers to "is it running?" and
/// "how do I stop it?".
///
/// yaz runs as an `.accessory` process with no dock icon and no window, so
/// without this there is nothing on screen to say the daemon is alive. That is
/// fine for a terminal session and wrong for a LaunchAgent that starts at
/// login — the user needs some way to confirm it is there and quit it.
@MainActor
final class MenuBarController {

    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onFixPermission: (() -> Void)?
    var onUseFallbackHotkey: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onUndoLast: (() -> Void)?
    /// Set only when Sparkle is running (the signed .app); otherwise the
    /// update items stay out of the menu.
    var onCheckForUpdates: (() -> Void)? {
        didSet { checkForUpdatesItem.isHidden = onCheckForUpdates == nil }
    }

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(
        title: "⚠︎  Grant Accessibility permission…", action: nil, keyEquivalent: "")
    private let hotkeyConflictItem = NSMenuItem(
        title: "⚠︎  fn is claimed by macOS — use right option", action: nil, keyEquivalent: "")
    private let checkForUpdatesItem = NSMenuItem(
        title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let updateAvailableItem = NSMenuItem(
        title: "Update available", action: nil, keyEquivalent: "")
    private let summary: String

    init(summary: String) {
        self.summary = summary
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        buildMenu()
    }

    /// Reflect what the daemon is doing.
    func update(_ state: IndicatorState) {
        guard let button = item.button else { return }
        button.image = StatusIcon.image(for: state)

        statusLine.title = switch state {
        case .idle: "ready to listen"
        case .recording: "● recording"
        case .transcribing: "transcribing…"
        case .refining: "refining…"
        }
    }

    /// Show a transient note (a rejected utterance, a warning) in the menu.
    func note(_ text: String) {
        statusLine.title = text
    }

    /// Surface or hide the "grant permission" action.
    func setNeedsPermission(_ needed: Bool) {
        permissionItem.isHidden = !needed
        if needed {
            statusLine.title = "hotkey inactive — permission required"
            item.button?.toolTip = "yaz — Accessibility permission required"
        } else {
            item.button?.toolTip = "yaz — \(summary)"
        }
    }

    /// Remove the item from the menu bar.
    ///
    /// Explicit rather than in `deinit`: a deinit is not guaranteed to run on
    /// the main actor, and tearing the item down there once hid a lifetime bug
    /// instead of surfacing it — the controller was being deallocated early and
    /// the icon quietly vanished. The daemon calls this when it shuts down; on
    /// process exit macOS reclaims it anyway.
    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: -

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = StatusIcon.image(for: .idle)
        button.imagePosition = .imageOnly
        button.toolTip = "yaz — \(summary)"
    }

    private func buildMenu() {
        let menu = NSMenu()

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // Shown only while the grant is missing. Without it the menu says
        // "waiting for permission" and offers no way to act on that, which is
        // how a user ends up pressing the hotkey and concluding the app is
        // broken.
        permissionItem.target = self
        permissionItem.action = #selector(fixPermission)
        permissionItem.isHidden = true
        menu.addItem(permissionItem)

        // macOS can own the globe key outright, in which case the tap never
        // sees it and the app looks dead. One click to a key that works beats
        // a sentence explaining System Settings.
        hotkeyConflictItem.target = self
        hotkeyConflictItem.action = #selector(useFallbackHotkey)
        hotkeyConflictItem.isHidden = true
        menu.addItem(hotkeyConflictItem)

        let detail = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        menu.addItem(.separator())

        // The last dictation again, into whatever is focused: for the field
        // that lost focus, or a second place the same text should go.
        let pasteLast = NSMenuItem(
            title: "Paste Last Dictation", action: #selector(pasteLastDictation), keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)

        // Removes it again, only if it is still right before the cursor.
        let undoLast = NSMenuItem(
            title: "Remove Last Dictation", action: #selector(undoLastDictation), keyEquivalent: "")
        undoLast.target = self
        menu.addItem(undoLast)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let history = NSMenuItem(
            title: "History…", action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        // A background check never opens a window over the app the user is
        // dictating into; it shows this item and waits.
        updateAvailableItem.target = self
        updateAvailableItem.action = #selector(checkForUpdates)
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)

        checkForUpdatesItem.target = self
        checkForUpdatesItem.action = #selector(checkForUpdates)
        checkForUpdatesItem.isHidden = true
        menu.addItem(checkForUpdatesItem)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        update(.idle)
    }

    /// Surface or hide the "macOS owns the fn key" escape hatch.
    func setHotkeyConflict(_ conflicted: Bool) {
        hotkeyConflictItem.isHidden = !conflicted
        if conflicted {
            statusLine.title = "fn is claimed by macOS — hotkey inactive"
            item.button?.toolTip = "yaz — the fn key is claimed by macOS"
        }
    }

    /// Show or clear "Update to x.y…".
    func setUpdateAvailable(_ version: String?) {
        updateAvailableItem.isHidden = version == nil
        if let version { updateAvailableItem.title = "Update to yaz \(version)…" }
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func pasteLastDictation() { onPasteLast?() }
    @objc private func undoLastDictation() { onUndoLast?() }
    @objc private func useFallbackHotkey() { onUseFallbackHotkey?() }
    @objc private func fixPermission() { onFixPermission?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func quit() { onQuit?() }

}
