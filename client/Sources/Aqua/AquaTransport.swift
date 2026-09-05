import Cocoa

enum TransportGlyph {
    case previous, play, pause, next
}

/// The round silver transport button of iTunes 10. Play is drawn larger
/// than previous and next; pass the diameter.
final class AquaRoundButton: NSView {
    var glyph: TransportGlyph { didSet { needsDisplay = true } }
    var diameter: CGFloat
    var isEnabled = true { didSet { needsDisplay = true } }
    weak var target: AnyObject?
    var action: Selector?
    var pressedOverride: Bool?
    private var isPressed = false

    init(glyph: TransportGlyph, diameter: CGFloat) {
        self.glyph = glyph
        self.diameter = diameter
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter + 4, height: diameter + 4) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        var inside = true
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let p = convert(e.locationInWindow, from: nil)
            let nowInside = bounds.contains(p)
            if nowInside != inside { inside = nowInside; isPressed = inside; needsDisplay = true }
            if e.type == .leftMouseUp { break }
        }
        isPressed = false
        needsDisplay = true
        if inside, let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = pressedOverride ?? isPressed
        let circleRect = NSRect(x: 2, y: 2, width: diameter, height: diameter).insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: circleRect)
        if Theme.isModern {
            // Flat glyphs on the glass capsule behind; a press shows as a tint.
            if pressed {
                Theme.controlFillPressed.setFill()
                circle.fill()
            }
            drawGlyph(in: circleRect, pressed: pressed)
            return
        }

        // Shadow beneath
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        Theme.ink(0.75).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Body: light at top, darker at the bottom; darker overall when pressed.
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let top = NSColor(white: pressed ? 0.78 : 0.99, alpha: 1)
        let mid = NSColor(white: pressed ? 0.68 : 0.90, alpha: 1)
        let bottom = NSColor(white: pressed ? 0.62 : 0.78, alpha: 1)
        NSGradient(colorsAndLocations: (top, 0), (mid, 0.5), (bottom, 1))!.draw(in: circleRect, angle: -90)
        // Bottom bounce light so the sphere reads as convex
        let c = NSPoint(x: circleRect.midX, y: circleRect.minY)
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(pressed ? 0.15 : 0.45), 0),
            (NSColor.white.withAlphaComponent(0), 1))!
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: diameter * 0.6, options: [])
        // Inner top highlight line
        let inner = NSBezierPath(ovalIn: circleRect.insetBy(dx: 1, dy: 1))
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(pressed ? 0.2 : 0.8).setStroke()
        NSBezierPath(rect: NSRect(x: circleRect.minX, y: circleRect.midY, width: circleRect.width, height: circleRect.height / 2)).addClip()
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        Theme.ink(0.42).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        drawGlyph(in: circleRect, pressed: pressed)
    }

    private func drawGlyph(in r: NSRect, pressed: Bool) {
        let color = isEnabled ? (Theme.isModern ? Theme.text : Aqua.glyph) : Theme.ink(0.6)
        color.setFill()
        let cx = r.midX, cy = r.midY
        let s = diameter * 0.36   // glyph height
        let path = NSBezierPath()
        func triangle(_ x0: CGFloat, _ x1: CGFloat) {
            // pointing from x0 to x1
            path.move(to: NSPoint(x: x0, y: cy + s / 2))
            path.line(to: NSPoint(x: x1, y: cy))
            path.line(to: NSPoint(x: x0, y: cy - s / 2))
            path.close()
        }
        switch glyph {
        case .play:
            triangle(cx - s * 0.42, cx + s * 0.55)
        case .pause:
            let w = s * 0.32, gap = s * 0.16
            path.appendRect(NSRect(x: cx - gap - w, y: cy - s / 2, width: w, height: s))
            path.appendRect(NSRect(x: cx + gap, y: cy - s / 2, width: w, height: s))
        case .next:
            let w = s * 0.62
            triangle(cx - w - s * 0.05, cx - s * 0.05)
            triangle(cx - s * 0.05, cx + w - s * 0.05)
            path.appendRect(NSRect(x: cx + w - s * 0.05, y: cy - s / 2, width: s * 0.16, height: s))
        case .previous:
            let w = s * 0.62
            triangle(cx + w + s * 0.05, cx + s * 0.05)
            triangle(cx + s * 0.05, cx - w + s * 0.05)
            path.appendRect(NSRect(x: cx - w + s * 0.05 - s * 0.16, y: cy - s / 2, width: s * 0.16, height: s))
        }
        if !Theme.isModern {
            // Slight white emboss under the glyph
            NSGraphicsContext.saveGraphicsState()
            let t = AffineTransform(translationByX: 0, byY: -1)
            let embossed = path.copy() as! NSBezierPath
            embossed.transform(using: t)
            NSColor.white.withAlphaComponent(0.6).setFill()
            embossed.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.setFill()
        path.fill()
    }
}

/// The small volume slider: gray groove, round silver knob, speaker glyphs.
final class AquaVolumeSlider: NSView {
    var value: Double = 0.75 { didSet { value = min(1, max(0, value)); needsDisplay = true } }
    /// True while the user drags, so a poll cannot snap the knob back.
    private(set) var isDragging = false
    /// Called continuously during the drag with the 0...1 value.
    var onChange: (Double) -> Void = { _ in }
    weak var target: AnyObject?
    var action: Selector?

    private let knob: CGFloat = 13
    private let iconWidth: CGFloat = 14

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 18) }

    private var trackRect: NSRect {
        NSRect(x: iconWidth + 6, y: bounds.midY - 2, width: bounds.width - 2 * (iconWidth + 6), height: 4)
    }

    private func knobCenter() -> NSPoint {
        let t = trackRect
        return NSPoint(x: t.minX + knob / 2 + CGFloat(value) * (t.width - knob), y: bounds.midY)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        update(with: event)
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            update(with: e)
            if e.type == .leftMouseUp { break }
        }
        isDragging = false
        onChange(value)
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    private func update(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = trackRect
        value = Double((p.x - t.minX - knob / 2) / (t.width - knob))
        onChange(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect
        if Theme.isModern {
            let track = NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2)
            Theme.controlFillPressed.setFill()
            track.fill()
            let c = knobCenter()
            Theme.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: max(4, c.x - t.minX), height: t.height), xRadius: 2, yRadius: 2).fill()
            let kr = NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            let k = NSBezierPath(ovalIn: kr)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
            sh.shadowBlurRadius = 2
            sh.shadowOffset = NSSize(width: 0, height: -0.5)
            sh.set()
            Theme.raised.setFill()
            k.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.hairline.setStroke()
            k.stroke()
            drawSpeaker(at: NSPoint(x: 2, y: bounds.midY), loud: false)
            drawSpeaker(at: NSPoint(x: bounds.width - iconWidth - 1, y: bounds.midY), loud: true)
            return
        }
        // Groove
        let groove = NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2)
        NSGradient(starting: Theme.ink(0.62), ending: Theme.ink(0.80))!.draw(in: groove, angle: -90)
        Theme.ink(0.48).setStroke()
        groove.lineWidth = 1
        NSBezierPath(roundedRect: t.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        NSColor(white: 1, alpha: 0.5).setFill()
        NSRect(x: t.minX + 1, y: t.minY - 1, width: t.width - 2, height: 1).fill()

        // Knob
        let c = knobCenter()
        let kr = NSRect(x: c.x - knob / 2, y: c.y - knob / 2, width: knob, height: knob)
        let k = NSBezierPath(ovalIn: kr.insetBy(dx: 0.5, dy: 0.5))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
        sh.shadowBlurRadius = 1.5
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()
        Theme.ink(0.8).setFill()
        k.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: Theme.ink(0.98), ending: Theme.ink(0.78))!.draw(in: k, angle: -90)
        Theme.ink(0.42).setStroke()
        k.lineWidth = 1
        k.stroke()

        drawSpeaker(at: NSPoint(x: 2, y: bounds.midY), loud: false)
        drawSpeaker(at: NSPoint(x: bounds.width - iconWidth - 1, y: bounds.midY), loud: true)
    }

    private func drawSpeaker(at origin: NSPoint, loud: Bool) {
        let color = Theme.isModern ? Theme.secondaryText : Theme.ink(0.35)
        let body = NSBezierPath()
        let x = origin.x, y = origin.y
        body.move(to: NSPoint(x: x, y: y - 2))
        body.line(to: NSPoint(x: x + 3, y: y - 2))
        body.line(to: NSPoint(x: x + 7, y: y - 5.5))
        body.line(to: NSPoint(x: x + 7, y: y + 5.5))
        body.line(to: NSPoint(x: x + 3, y: y + 2))
        body.line(to: NSPoint(x: x, y: y + 2))
        body.close()
        color.setFill()
        body.fill()
        if loud {
            color.setStroke()
            for (i, r) in [3.0, 5.5].enumerated() {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: x + 7, y: y), radius: CGFloat(r), startAngle: -40, endAngle: 40)
                arc.lineWidth = i == 0 ? 1 : 1.2
                arc.stroke()
            }
        }
    }
}
