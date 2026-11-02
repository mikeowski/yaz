import AppKit

/// A flat drawing of the application icon.
///
/// The real icon is `Resources/AppIcon.icon`, an Icon Composer document that
/// `scripts/bundle.sh` compiles with `actool`. macOS 26 renders that one in
/// every appearance (Default, Dark, Clear, Tinted) with Liquid Glass. This
/// drawing is the fallback for a machine without Xcode 26, where `actool`
/// cannot read `.icon`, and the sheet `yaz preview --app-icon` writes. It
/// follows the same geometry, so both read as the same mark.
///
/// The mark: a voice (a dot and two waves) reaching a text caret. Geometry is
/// in the 1024-point grid Icon Composer uses; the drawing scales it.
enum AppIcon {

    /// Draw the icon into a square of `size` points.
    static func image(size: CGFloat = 1024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        return image
    }

    /// Vermilion, top to bottom: the fill of `AppIcon.icon`.
    static let fillTop = NSColor(displayP3Red: 1.0, green: 0.490, blue: 0.322, alpha: 1)
    static let fillBottom = NSColor(displayP3Red: 0.855, green: 0.216, blue: 0.173, alpha: 1)

    static func draw(in rect: NSRect) {
        let scale = rect.width / 1024
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            // The grid is y-down like the SVG layers; AppKit is y-up.
            NSRect(x: rect.minX + x * scale, y: rect.minY + (1024 - y - h) * scale,
                   width: w * scale, height: h * scale)
        }

        // macOS icons sit inside their canvas with margin; the plate is the
        // rounded square, continuous-corner ratio.
        let plateRect = r(100, 100, 824, 824)
        let plate = NSBezierPath(roundedRect: plateRect, xRadius: 186 * scale, yRadius: 186 * scale)

        NSGraphicsContext.saveGraphicsState()
        plate.addClip()
        NSGradient(starting: fillBottom, ending: fillTop)?.draw(in: plateRect, angle: 90)
        // A sheen along the top: the light Liquid Glass catches.
        NSGradient(colorsAndLocations:
            (NSColor(white: 1, alpha: 0.0), 0.55),
            (NSColor(white: 1, alpha: 0.26), 1.0)
        )?.draw(in: plateRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.54, green: 0.10, blue: 0.06, alpha: 0.32)
        shadow.shadowBlurRadius = 18 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
        shadow.set()
        NSColor.white.setFill()
        NSColor.white.setStroke()

        // Voice: a dot, and two waves opening toward the caret.
        NSBezierPath(ovalIn: r(321 - 46, 512 - 46, 92, 92)).fill()
        let origin = NSPoint(x: rect.minX + 321 * scale, y: rect.minY + 512 * scale)
        for (radius, width) in [(CGFloat(110), CGFloat(64)), (200, 60)] {
            let wave = NSBezierPath()
            wave.appendArc(withCenter: origin, radius: radius * scale, startAngle: -52, endAngle: 52)
            wave.lineWidth = width * scale
            wave.lineCapStyle = .round
            wave.stroke()
        }

        // Caret: one solid I-beam, stem and two bars.
        NSBezierPath(rect: r(623, 330, 56, 364)).fill()
        for y: CGFloat in [282, 690] {
            NSBezierPath(roundedRect: r(595, y, 112, 52), xRadius: 26 * scale, yRadius: 26 * scale).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // A thin rim so the plate has an edge against the wallpaper.
        NSColor(white: 1, alpha: 0.22).setStroke()
        plate.lineWidth = 5 * scale
        plate.stroke()
    }
}
