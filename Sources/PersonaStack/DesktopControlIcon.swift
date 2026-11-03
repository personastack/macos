import AppKit

/// Native rendering of integration-logos/desktop-control.svg, in its original color.
@MainActor
enum DesktopControlIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { bounds in
            // Exact SVG path: m4 3 7 18 3-7 7-3L4 3Z, viewBox 0 0 24 24.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 3))
            path.line(to: NSPoint(x: 11, y: 21))
            path.line(to: NSPoint(x: 14, y: 14))
            path.line(to: NSPoint(x: 21, y: 11))
            path.close()
            let scale = bounds.width / 24
            let transform = AffineTransform(scale: scale)
            path.transform(using: transform)
            path.lineWidth = 1.7 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor(srgbRed: 51 / 255, green: 116 / 255, blue: 1, alpha: 1).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
