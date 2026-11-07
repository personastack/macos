import AppKit
import PersonaStackCore

/// Native button semantics with explicit icon colors, including disabled icons.
@MainActor
final class WindowChromeButton: NSButton {
    private var pointerInside = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = WindowChromeButtonCell()
        bezelStyle = .regularSquare
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (pointerInside || isHighlighted) {
            WindowPresentation.headerHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            WindowPresentation.headerAccent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

@MainActor
private final class WindowChromeButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(1, 16 / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let image else { return }
        drawImage(image, withFrame: imageRect(forBounds: cellFrame), in: controlView)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        let color = isEnabled ? WindowPresentation.headerForeground : WindowPresentation.headerSecondary
        // Render into a separate image so AppKit cannot apply its disabled tint
        // on top of our explicit muted foreground, including template SVGs.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}
