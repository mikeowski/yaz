import AppKit

/// The application icon, drawn in code.
///
/// Same reasoning as `StatusIcon`: a vector redrawn per size stays crisp from
/// 16 pt in the Finder sidebar to 1024 pt in Get Info, and there is no asset
/// catalogue to go missing when the binary runs outside its bundle.
///
/// The mark is the menu bar glyph promoted to full size — sound arcs arriving
/// at a text caret — so the app and its menu bar item are recognisably the same
/// thing. What the app icon adds is depth: a macOS icon sits on a rounded
/// plate with a light source, and a flat glyph on a flat square is the look of
/// something unfinished.
enum AppIcon {

    /// Draw the icon into a square of `size` points.
    static func image(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        return image
    }

    static func draw(in rect: NSRect) {
        let size = rect.width

        // macOS icons do not fill their canvas: the rounded plate sits inside
        // with margin, which is what makes icons line up optically in the Dock.
        let inset = size * 0.098
        let plate = rect.insetBy(dx: inset, dy: inset)
        let radius = plate.width * 0.2237  // Apple's continuous-corner ratio

        let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        drawPlate(shape, in: plate)
        drawTopHighlight(shape, in: plate)
        drawMark(in: plate)
        drawRim(shape)
    }

    // MARK: - Plate

    /// Deep indigo to violet, top-left to bottom-right.
    ///
    /// Not the system blue every second utility uses, and dark enough that a
    /// white mark carries at 16 pt where a pastel would turn to mush.
    private static func drawPlate(_ shape: NSBezierPath, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        let gradient = NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.42, green: 0.29, blue: 0.92, alpha: 1), 0.0),
            (NSColor(srgbRed: 0.29, green: 0.20, blue: 0.72, alpha: 1), 0.52),
            (NSColor(srgbRed: 0.14, green: 0.10, blue: 0.42, alpha: 1), 1.0)
        )
        gradient?.draw(in: rect, angle: -68)

        // A soft radial bloom near the top-left reads as a light source and
        // stops the gradient looking like a flat ramp.
        let bloom = NSGradient(colorsAndLocations:
            (NSColor(white: 1, alpha: 0.30), 0.0),
            (NSColor(white: 1, alpha: 0.0), 1.0)
        )
        bloom?.draw(
            fromCenter: NSPoint(x: rect.minX + rect.width * 0.26, y: rect.maxY - rect.height * 0.18),
            radius: 0,
            toCenter: NSPoint(x: rect.minX + rect.width * 0.26, y: rect.maxY - rect.height * 0.18),
            radius: rect.width * 0.78,
            options: [])

        NSGraphicsContext.restoreGraphicsState()
    }

    /// A bright hairline along the top edge — the highlight a physical object
    /// catches from a light above it.
    private static func drawTopHighlight(_ shape: NSBezierPath, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        let band = NSRect(
            x: rect.minX, y: rect.maxY - rect.height * 0.5,
            width: rect.width, height: rect.height * 0.5)
        let gradient = NSGradient(colorsAndLocations:
            (NSColor(white: 1, alpha: 0.22), 1.0),
            (NSColor(white: 1, alpha: 0.0), 0.0)
        )
        gradient?.draw(in: band, angle: 90)

        NSGraphicsContext.restoreGraphicsState()
    }

    /// A thin inner rim so the plate has an edge instead of bleeding into the
    /// wallpaper behind it.
    private static func drawRim(_ shape: NSBezierPath) {
        NSColor(white: 1, alpha: 0.16).setStroke()
        shape.lineWidth = shape.bounds.width * 0.006
        shape.stroke()
    }

    // MARK: - Mark

    /// Sound arcs meeting a text caret, in white, with a soft shadow so it
    /// sits above the plate rather than being painted onto it.
    private static func drawMark(in plate: NSRect) {
        let size = plate.width
        let centerY = plate.midY

        // Centre the *group*, not the caret. The mark runs from the outer
        // arc's leftmost point to the caret's right serif; placing the caret
        // at the middle pushes everything visibly right, which is what the
        // first render did.
        let arcOffset = size * 0.115      // caret → arc origin
        let outerRadius = size * 0.200
        let serifWidth = size * 0.150
        let leftExtent = arcOffset + outerRadius   // left of the caret
        let rightExtent = serifWidth / 2           // right of the caret
        let caretX = plate.midX + (leftExtent - rightExtent) / 2

        let markHeight = size * 0.48

        NSGraphicsContext.saveGraphicsState()
        // Tight and low-contrast. The first attempt used a wide soft shadow
        // and left a grey halo that read as a smudge rather than depth.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.06, green: 0.03, blue: 0.20, alpha: 0.28)
        shadow.shadowBlurRadius = size * 0.016
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.010)
        shadow.set()

        NSColor.white.setFill()
        NSColor.white.setStroke()

        // Caret: stem plus serifs.
        let stemWidth = size * 0.050
        let serifHeight = size * 0.048

        NSBezierPath(
            roundedRect: NSRect(
                x: caretX - stemWidth / 2, y: centerY - markHeight / 2,
                width: stemWidth, height: markHeight),
            xRadius: stemWidth / 2, yRadius: stemWidth / 2
        ).fill()

        for y in [centerY - markHeight / 2, centerY + markHeight / 2 - serifHeight] {
            NSBezierPath(
                roundedRect: NSRect(
                    x: caretX - serifWidth / 2, y: y,
                    width: serifWidth, height: serifHeight),
                xRadius: serifHeight / 2, yRadius: serifHeight / 2
            ).fill()
        }

        // Two arcs opening toward the caret, reading as one emanation.
        //
        // Falloff is carried by thickness, not opacity. A translucent white
        // over this purple turns grey, and the outer arc read as dirty rather
        // than distant — which is how the second render looked.
        let origin = NSPoint(x: caretX - arcOffset, y: centerY)
        let arcs: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = [
            (size * 0.104, size * 0.052, 1.00),
            (outerRadius, size * 0.042, 0.97),
        ]
        for arc in arcs {
            let path = NSBezierPath()
            path.lineWidth = arc.width
            path.lineCapStyle = .round
            path.appendArc(withCenter: origin, radius: arc.radius, startAngle: 133, endAngle: 227)
            NSColor(white: 1, alpha: arc.alpha).setStroke()
            path.stroke()
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}
