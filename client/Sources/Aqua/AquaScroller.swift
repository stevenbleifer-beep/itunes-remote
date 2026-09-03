import Cocoa

/// A legacy-style scroller: always visible, a light recessed track and a
/// gray pill knob, the way iTunes 10's lists scrolled before overlay bars.
final class AquaScroller: NSScroller {

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 15 }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        let vertical = bounds.height > bounds.width
        NSGradient(starting: NSColor(white: 0.90, alpha: 1), ending: NSColor(white: 0.96, alpha: 1))!
            .draw(in: slotRect, angle: vertical ? 0 : 90)
        NSColor(white: 0.78, alpha: 1).setFill()
        if vertical {
            NSRect(x: slotRect.minX, y: slotRect.minY, width: 1, height: slotRect.height).fill()
        } else {
            NSRect(x: slotRect.minX, y: slotRect.maxY - 1, width: slotRect.width, height: 1).fill()
        }
    }

    override func drawKnob() {
        let vertical = bounds.height > bounds.width
        let r = rect(for: .knob).insetBy(dx: vertical ? 3 : 0, dy: vertical ? 0 : 3)
        guard r.width > 2, r.height > 2 else { return }
        let radius = (vertical ? r.width : r.height) / 2
        let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor(white: 0.66, alpha: 1), ending: NSColor(white: 0.50, alpha: 1))!
            .draw(in: pill, angle: vertical ? 0 : 90)
        NSColor(white: 0.36, alpha: 1).setStroke()
        pill.lineWidth = 1
        pill.stroke()
        // Top-edge highlight along the pill.
        NSGraphicsContext.saveGraphicsState()
        pill.addClip()
        NSColor(white: 1, alpha: 0.35).setFill()
        if vertical {
            NSRect(x: r.minX + 1.5, y: r.minY + 2, width: 1, height: r.height - 4).fill()
        } else {
            NSRect(x: r.minX + 2, y: r.maxY - 2.5, width: r.width - 4, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: bounds, highlight: false)
        if usableParts != .noScrollerParts { drawKnob() }
    }
}
