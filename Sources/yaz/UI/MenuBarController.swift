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

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(
        title: "⚠︎  Grant Accessibility permission…", action: nil, keyEquivalent: "")
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

        let detail = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

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

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        update(.idle)
    }

    @objc private func fixPermission() { onFixPermission?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func quit() { onQuit?() }

}
