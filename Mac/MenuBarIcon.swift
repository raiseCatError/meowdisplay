import AppKit

/// The menu-bar status icon: the MeowDisplay mark reduced to a monochrome
/// template glyph — the smiling tablet tucked into its pocket. Template, so
/// macOS tints it for light, dark and tinted menu bars. While a display is
/// active the pocket is filled.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            draw(active: active)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MeowDisplay"
        return image
    }

    /// Drawn in an 18 × 18 pt box, y down.
    private static func draw(active: Bool) {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // The tablet, tilted like the logo, rising out of the pocket.
        NSGraphicsContext.saveGraphicsState()
        let tilt = NSAffineTransform()
        tilt.translateX(by: 9, yBy: 7.4)
        tilt.rotate(byDegrees: -7)
        tilt.concat()
        let tablet = NSBezierPath(roundedRect: NSRect(x: -6.4, y: -5.4, width: 12.8, height: 9.6),
                                  xRadius: 1.8, yRadius: 1.8)
        tablet.lineWidth = 1.4
        tablet.stroke()
        // The face: two closed, happy eyes and a small smile.
        for x in [-2.6, 2.6] as [CGFloat] {
            let eye = NSBezierPath()
            eye.appendArc(withCenter: NSPoint(x: x, y: -1.4), radius: 1.1, startAngle: 200, endAngle: 340)
            eye.lineWidth = 1.1
            eye.lineCapStyle = .round
            eye.stroke()
        }
        let smile = NSBezierPath()
        smile.appendArc(withCenter: NSPoint(x: 0, y: -0.2), radius: 0.9, startAngle: 20, endAngle: 160)
        smile.lineWidth = 1.0
        smile.lineCapStyle = .round
        smile.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // The pocket: flat top, straight sides, a pointed bottom.
        let pocket = NSBezierPath()
        pocket.move(to: NSPoint(x: 2.2, y: 9.6))
        pocket.line(to: NSPoint(x: 15.8, y: 9.6))
        pocket.line(to: NSPoint(x: 15.3, y: 14.0))
        pocket.line(to: NSPoint(x: 9, y: 17.0))
        pocket.line(to: NSPoint(x: 2.7, y: 14.0))
        pocket.close()
        pocket.lineJoinStyle = .round
        pocket.lineWidth = 1.4
        if active {
            pocket.fill()
        } else {
            // Clear the tablet behind the pocket, then outline it.
            NSGraphicsContext.current?.compositingOperation = .clear
            pocket.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            pocket.stroke()
        }
    }
}
