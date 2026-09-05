import Cocoa

enum ViewGlyph {
    case list, albumList, grid, coverFlow
}

/// The iTunes 10 view switcher: a short capsule of icon segments, the chosen
/// one pressed in. Everything drawn; the glyphs are simple paths.
final class AquaSegmentedControl: NSView {
    let glyphs: [ViewGlyph]
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onChange: (Int) -> Void = { _ in }
    private let segmentWidth: CGFloat = 30
    private var pressedIndex: Int?

    init(glyphs: [ViewGlyph]) {
        self.glyphs = glyphs
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidth * CGFloat(glyphs.count) + 2, height: 22)
    }

    private func index(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let i = Int((point.x - 1) / segmentWidth)
        return (0..<glyphs.count).contains(i) ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = index(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            if e.type == .leftMouseUp {
                let up = index(at: convert(e.locationInWindow, from: nil))
                pressedIndex = nil
                needsDisplay = true
                if let i = up, i == index(at: convert(event.locationInWindow, from: nil)), i != selectedIndex {
                    selectedIndex = i
                    onChange(i)
                }
                return
            }
        }
        pressedIndex = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 1.5)
        if Theme.isModern {
            // A quiet track with a white pill on the chosen segment.
            let track = NSBezierPath(roundedRect: outer, xRadius: outer.height / 2, yRadius: outer.height / 2)
            Theme.controlFill.setFill()
            track.fill()
            for (i, glyph) in glyphs.enumerated() {
                let r = NSRect(x: outer.minX + CGFloat(i) * segmentWidth, y: outer.minY, width: segmentWidth, height: outer.height)
                let down = i == selectedIndex || i == pressedIndex
                if down {
                    NSGraphicsContext.saveGraphicsState()
                    let sh = NSShadow()
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.18)
                    sh.shadowBlurRadius = 2
                    sh.shadowOffset = NSSize(width: 0, height: -0.5)
                    sh.set()
                    Theme.raised.setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: (r.height - 4) / 2, yRadius: (r.height - 4) / 2).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                drawGlyph(glyph, in: r, down: down)
            }
            return
        }
        let capsule = NSBezierPath(roundedRect: outer, xRadius: 4, yRadius: 4)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Theme.ink(0.85).setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        for (i, glyph) in glyphs.enumerated() {
            let r = NSRect(x: outer.minX + CGFloat(i) * segmentWidth, y: outer.minY,
                           width: segmentWidth, height: outer.height)
            let down = i == selectedIndex || i == pressedIndex
            if down {
                NSGradient(starting: Theme.ink(0.66), ending: Theme.ink(0.76))!
                    .draw(in: r, angle: -90)
                // Inner shadow along the top, the pressed-in look.
                NSColor.black.withAlphaComponent(0.18).setFill()
                NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
            } else {
                NSGradient(starting: Theme.ink(0.99), ending: Theme.ink(0.86))!
                    .draw(in: r, angle: -90)
            }
            if i > 0 {
                Theme.ink(0.55).setFill()
                NSRect(x: r.minX - 0.5, y: r.minY, width: 1, height: r.height).fill()
            }
            drawGlyph(glyph, in: r, down: down)
        }
        NSGraphicsContext.restoreGraphicsState()

        Theme.ink(0.45).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }

    private func drawGlyph(_ glyph: ViewGlyph, in r: NSRect, down: Bool) {
        let color = Theme.isModern ? (down ? Theme.text : Theme.secondaryText) : (down ? Theme.ink(0.15) : Theme.ink(0.30))
        color.setFill()
        color.setStroke()
        let cx = r.midX, cy = r.midY
        switch glyph {
        case .list:
            for k in 0..<4 {
                NSRect(x: cx - 6, y: cy - 5.5 + CGFloat(k) * 3.5, width: 12, height: 1.5).fill()
            }
        case .albumList:
            NSRect(x: cx - 7, y: cy - 4, width: 5, height: 8).fill()
            for k in 0..<3 {
                NSRect(x: cx - 0.5, y: cy - 4 + CGFloat(k) * 3.5, width: 7.5, height: 1.5).fill()
            }
        case .grid:
            for (dx, dy) in [(-6.5, -6.5), (0.5, -6.5), (-6.5, 0.5), (0.5, 0.5)] as [(CGFloat, CGFloat)] {
                NSRect(x: cx + dx, y: cy + dy, width: 6, height: 6).fill()
            }
        case .coverFlow:
            NSRect(x: cx - 3, y: cy - 5, width: 6, height: 10).fill()
            let left = NSBezierPath()
            left.move(to: NSPoint(x: cx - 5, y: cy - 4))
            left.line(to: NSPoint(x: cx - 8, y: cy - 2.5))
            left.line(to: NSPoint(x: cx - 8, y: cy + 2.5))
            left.line(to: NSPoint(x: cx - 5, y: cy + 4))
            left.close()
            left.fill()
            let right = NSBezierPath()
            right.move(to: NSPoint(x: cx + 5, y: cy - 4))
            right.line(to: NSPoint(x: cx + 8, y: cy - 2.5))
            right.line(to: NSPoint(x: cx + 8, y: cy + 2.5))
            right.line(to: NSPoint(x: cx + 5, y: cy + 4))
            right.close()
            right.fill()
        }
    }
}
