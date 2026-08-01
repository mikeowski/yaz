import AppKit

/// yaz's menu bar mark, drawn rather than borrowed.
///
/// The glyph is the product in one shape: **sound arriving at a text cursor.**
/// Two arcs radiate from the left into a bold I-beam caret on the right.
///
/// It was chosen by rendering candidates and looking at them at true size,
/// which is the only way to judge an 18 pt mark. Two alternatives lost:
///
/// - A caret whose stem was a sine wave. Striking at 8×, an illegible blob at
///   18 pt.
/// - A plain waveform of rounded bars. Perfectly legible and completely
///   generic — every audio app on the machine already has it, and it says
///   nothing about text coming out the other end.
///
/// Drawn with `NSBezierPath` rather than shipped as an asset, for three
/// reasons that matter here:
///
/// - **Crisp at every scale.** Menu bar icons render at 16–18 pt across 1× and
///   2×; a vector redrawn per size never softens the way a bitmap does.
/// - **States share a skeleton.** The caret never moves; only what is to its
///   left changes, so the icon reads as one mark changing rather than four
///   unrelated pictures.
/// - **No bundle lookup.** yaz also runs as a bare CLI binary with no resource
///   bundle; an asset catalogue would work inside the `.app` and silently fail
///   outside it.
///
/// Every image is a template — macOS tints it for light, dark and highlighted
/// menus. Nothing here sets a colour.
enum StatusIcon {

    /// Menu bar icons live on an 18×18 pt canvas.
    static let size = NSSize(width: 18, height: 18)

    static func image(for state: IndicatorState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            let bounds = rect.insetBy(dx: 1.5, dy: 1.5)
            drawCaret(in: bounds)
            drawSignal(for: state, in: bounds)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Geometry

    /// Where the caret sits. Fixed across states so the mark does not jump
    /// around in the menu bar as the daemon changes what it is doing.
    private static func caretX(in bounds: NSRect) -> CGFloat {
        bounds.maxX - 2.6
    }

    private static func drawCaret(in bounds: NSRect) {
        let x = caretX(in: bounds)
        let stemWidth: CGFloat = 2.0
        let serifWidth: CGFloat = 5.6
        let serifHeight: CGFloat = 1.9

        NSBezierPath(
            roundedRect: NSRect(
                x: x - stemWidth / 2, y: bounds.minY,
                width: stemWidth, height: bounds.height),
            xRadius: stemWidth / 2, yRadius: stemWidth / 2
        ).fill()

        for y in [bounds.minY, bounds.maxY - serifHeight] {
            NSBezierPath(
                roundedRect: NSRect(
                    x: x - serifWidth / 2, y: y,
                    width: serifWidth, height: serifHeight),
                xRadius: serifHeight / 2, yRadius: serifHeight / 2
            ).fill()
        }
    }

    /// What is happening, drawn to the left of the caret.
    ///
    /// Idle shows one arc rather than none: an empty left side reads as a
    /// broken icon, one arc reads as listening-but-quiet.
    private static func drawSignal(for state: IndicatorState, in bounds: NSRect) {
        switch state {
        case .idle:
            arcs(count: 1, in: bounds)
        case .recording:
            arcs(count: 2, in: bounds)
        case .transcribing, .refining:
            // Work in progress: the sound has already been captured, so
            // showing it still arriving would be a lie.
            dots(in: bounds)
        }
    }

    /// Concentric arcs opening toward the caret.
    private static func arcs(count: Int, in bounds: NSRect) {
        let origin = NSPoint(x: caretX(in: bounds) - 4.2, y: bounds.midY)
        // Radii and weights fall off outward, so the outer arc reads as the
        // quieter, further-away part of the same emanation.
        let radii: [(radius: CGFloat, width: CGFloat)] = [(3.6, 2.1), (6.8, 1.8)]

        for index in 0..<min(count, radii.count) {
            let spec = radii[index]
            let path = NSBezierPath()
            path.lineWidth = spec.width
            path.lineCapStyle = .round
            path.appendArc(
                withCenter: origin, radius: spec.radius,
                startAngle: 132, endAngle: 228)
            path.stroke()
        }
    }

    /// Three dots — the icon's "working" state.
    ///
    /// Transcribing and refining draw the same thing on purpose. At 18 pt
    /// there is no room for a distinction anyone could see, and inventing one
    /// would only add flicker between two steps that run back to back; the
    /// menu says which is which.
    private static func dots(in bounds: NSRect) {
        let diameter: CGFloat = 2.0
        let spacing: CGFloat = 3.2
        let count = 3

        // Right-align against the caret with real clearance. Laid out from the
        // left the last dot ran into the stem and the mark read as a smudge.
        let span = CGFloat(count - 1) * spacing + diameter
        let clearance: CGFloat = 2.4
        let x = caretX(in: bounds) - clearance - span

        for index in 0..<count {
            let dot = NSRect(
                x: x + CGFloat(index) * spacing,
                y: bounds.midY - diameter / 2,
                width: diameter, height: diameter)
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
