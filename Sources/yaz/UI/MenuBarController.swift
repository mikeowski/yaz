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

    private let item: NSStatusItem
    private let statusLine = NSMenuItem(title: "hazırlanıyor…", action: nil, keyEquivalent: "")
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
        button.image = Self.glyph(for: state)

        statusLine.title = switch state {
        case .idle: "dinlemeye hazır"
        case .recording: "● kayıt"
        case .transcribing: "çeviriyor…"
        case .refining: "düzeltiyor…"
        }
    }

    /// Show a transient note (a rejected utterance, a warning) in the menu.
    func note(_ text: String) {
        statusLine.title = text
    }

    deinit {
        // The status bar keeps its own reference; without this the icon
        // survives the controller and lingers after quit.
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: -

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = Self.glyph(for: .idle)
        button.image?.isTemplate = true
        button.toolTip = "yaz — \(summary)"
    }

    private func buildMenu() {
        let menu = NSMenu()

        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let detail = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let history = NSMenuItem(
            title: "Geçmiş…", action: #selector(openHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Çık", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        update(.idle)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openHistory() { onOpenHistory?() }
    @objc private func quit() { onQuit?() }

    /// SF Symbols, with a drawn fallback.
    ///
    /// A `.accessory` binary with no bundle still gets SF Symbols, but the
    /// fallback matters: an image that fails to load leaves a zero-width status
    /// item, which looks exactly like the daemon failing to start.
    private static func glyph(for state: IndicatorState) -> NSImage {
        let name = switch state {
        case .idle: "pencil.and.scribble"
        case .recording: "waveform"
        case .transcribing, .refining: "ellipsis"
        }

        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "yaz") {
            image.isTemplate = true
            return image
        }
        return fallback(filled: state != .idle)
    }

    private static func fallback(filled: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor.black.set()
            if filled { path.fill() } else { path.lineWidth = 1.5; path.stroke() }
            return true
        }
        image.isTemplate = true
        return image
    }
}
