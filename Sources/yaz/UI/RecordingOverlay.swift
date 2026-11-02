import AppKit
import SwiftUI

/// A small pill near the bottom of the active screen while dictation is live.
///
/// Push-to-talk has one honest failure mode: you hold the key, speak, and
/// nothing was listening. Without feedback the user finds out when the text
/// does not arrive. The pill is the whole answer to that — the only UI yaz has
/// beyond the menu bar.
///
/// It is a borderless, click-through `NSPanel` rather than a window: clicks
/// pass to whatever is underneath, it joins every Space, and it never steals
/// focus from the field being dictated into. Stealing focus would defeat the
/// point, since the transcript is pasted wherever the cursor was.
@MainActor
final class RecordingOverlay {

    private var panel: NSPanel?
    private let model = OverlayModel()

    /// Show the pill in `state`, creating the panel on first use.
    func show(_ state: IndicatorState) {
        guard state.isVisible else { return hide() }
        ensurePanel()
        guard let panel else { return }

        if state == .recording { model.meter.reset() }
        if state != .recording { setDetail(nil) }

        let appearing = !panel.isVisible
        if appearing {
            position(panel)
            // orderFrontRegardless, not makeKeyAndOrderFront: the panel must
            // never take key status away from the app being dictated into.
            panel.orderFrontRegardless()
            // Let SwiftUI lay out in the hidden style once, then animate in on
            // the next runloop tick.
            DispatchQueue.main.async { [model] in model.state = state }
        } else {
            model.state = state
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        model.state = .idle
        // Let the scale/fade play out before pulling the window, or it pops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// A second line beside the label: "hands-free" while locked, or the live
    /// transcript so far. Only ever shown; the pasted text is the final one.
    func setDetail(_ text: String?) {
        let text = text.flatMap { $0.isEmpty ? nil : $0 }
        guard model.detail != text else { return }
        model.detail = text
        guard let panel else { return }
        let width: CGFloat = text == nil ? Self.compactWidth : Self.wideWidth
        guard panel.frame.width != width else { return }
        var frame = panel.frame
        frame.origin.x = frame.midX - width / 2
        frame.size.width = width
        panel.setFrame(frame, display: true)
    }

    private static let compactWidth: CGFloat = 148
    private static let wideWidth: CGFloat = 440

    /// Feed a microphone peak. Safe from any thread — the audio tap calls this.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor [model] in model.push(level) }
    }

    // MARK: -

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.compactWidth, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))

        self.panel = panel
    }

    /// Bottom-centre of whichever screen has the mouse, so the pill follows the
    /// user across a multi-monitor desk instead of sitting on the laptop.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 64
        ))
    }
}

/// Observable state behind the pill.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: IndicatorState = .idle
    @Published var meter = LevelMeter()
    @Published var detail: String?

    func push(_ level: Float) {
        guard state == .recording else { return }
        meter.push(level)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 8) {
            if model.state.showsWaveform {
                Waveform(bars: model.meter.bars)
                    .frame(width: 76, height: 18)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 18, height: 18)
            }

            Text(model.state.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            if let detail = model.detail {
                // The newest words matter most: cut from the front.
                Text(detail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(.black.opacity(0.78))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .scaleEffect(model.state.isVisible ? 1 : 0.86)
        .opacity(model.state.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.state)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Waveform: View {
    let bars: [Float]

    var body: some View {
        GeometryReader { geometry in
            let count = max(bars.count, 1)
            let spacing: CGFloat = 2
            let width = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(
                            width: width,
                            height: max(2, geometry.size.height * CGFloat(bar))
                        )
                }
            }
            .frame(height: geometry.size.height)
            .animation(.linear(duration: 0.06), value: bars)
        }
    }
}
