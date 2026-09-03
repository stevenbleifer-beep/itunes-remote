import Cocoa

enum BevelGlyph {
    case plus, shuffle, repeatAll, repeatOne, artwork, eject, sync, reconnect, upNext
}

/// The small square buttons along the bottom bar of iTunes 10: a light
/// gradient bevel with a dark glyph. `isOn` shows the pressed-in state used
/// for shuffle and repeat toggles.
final class AquaBevelButton: NSView {
    var glyph: BevelGlyph { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var toolTip_: String? { didSet { toolTip = toolTip_ } }
    weak var target: AnyObject?
    var action: Selector?
    private var isPressed = false

    init(glyph: BevelGlyph) {
        self.glyph = glyph
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 20) }

    // A real button to the rest of the system: click-through works on an
    // inactive window as it does for NSButton, and VoiceOver and the
    // accessibility tools can press it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { toolTip }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let a = action else { return false }
        NSApp.sendAction(a, to: target, from: self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        var inside = true
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let now = bounds.contains(convert(e.locationInWindow, from: nil))
            if now != inside { inside = now; isPressed = inside; needsDisplay = true }
            if e.type == .leftMouseUp { break }
        }
        isPressed = false
        needsDisplay = true
        if inside, let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        let down = isPressed || isOn
        if down {
            NSGradient(starting: NSColor(white: 0.62, alpha: 1), ending: NSColor(white: 0.74, alpha: 1))!.draw(in: path, angle: -90)
        } else {
            NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.84, alpha: 1))!.draw(in: path, angle: -90)
        }
        NSColor(white: 0.42, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        if !down {
            NSColor(white: 1, alpha: 0.7).setFill()
            NSRect(x: r.minX + 2, y: r.maxY - 2, width: r.width - 4, height: 1).fill()
        }
        let color = isEnabled ? (isOn ? Aqua.accent : NSColor(white: 0.20, alpha: 1)) : NSColor(white: 0.6, alpha: 1)
        color.setFill()
        color.setStroke()
        drawGlyph(cx: bounds.midX, cy: bounds.midY)
    }

    private func drawGlyph(cx: CGFloat, cy: CGFloat) {
        switch glyph {
        case .plus:
            NSRect(x: cx - 5, y: cy - 1, width: 10, height: 2).fill()
            NSRect(x: cx - 1, y: cy - 5, width: 2, height: 10).fill()
        case .shuffle:
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.move(to: NSPoint(x: cx - 7, y: cy - 3)); p.line(to: NSPoint(x: cx - 3, y: cy - 3))
            p.line(to: NSPoint(x: cx + 2, y: cy + 3)); p.line(to: NSPoint(x: cx + 6, y: cy + 3))
            p.move(to: NSPoint(x: cx - 7, y: cy + 3)); p.line(to: NSPoint(x: cx - 3, y: cy + 3))
            p.line(to: NSPoint(x: cx + 2, y: cy - 3)); p.line(to: NSPoint(x: cx + 6, y: cy - 3))
            p.stroke()
            for y in [cy + 3, cy - 3] {
                let a = NSBezierPath()
                a.move(to: NSPoint(x: cx + 5, y: y + 2.5)); a.line(to: NSPoint(x: cx + 8, y: y)); a.line(to: NSPoint(x: cx + 5, y: y - 2.5))
                a.close(); a.fill()
            }
        case .repeatAll, .repeatOne:
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 5, startAngle: 40, endAngle: 320)
            p.stroke()
            let a = NSBezierPath()
            a.move(to: NSPoint(x: cx + 2, y: cy - 6.5)); a.line(to: NSPoint(x: cx + 6.5, y: cy - 4)); a.line(to: NSPoint(x: cx + 2.5, y: cy - 1))
            a.close(); a.fill()
            if glyph == .repeatOne {
                NSRect(x: cx - 1, y: cy - 2.5, width: 2, height: 5).fill()
            }
        case .artwork:
            let frame = NSBezierPath(rect: NSRect(x: cx - 6.5, y: cy - 5.5, width: 13, height: 11))
            frame.lineWidth = 1.2
            frame.stroke()
            let hill = NSBezierPath()
            hill.move(to: NSPoint(x: cx - 5, y: cy - 4)); hill.line(to: NSPoint(x: cx - 1, y: cy + 1))
            hill.line(to: NSPoint(x: cx + 1.5, y: cy - 1.5)); hill.line(to: NSPoint(x: cx + 3, y: cy))
            hill.line(to: NSPoint(x: cx + 5, y: cy - 4)); hill.close(); hill.fill()
        case .upNext:
            // Three stacked lines with a small play triangle beside the first:
            // the queue, and what comes off the top of it.
            let t = NSBezierPath()
            t.move(to: NSPoint(x: cx - 6, y: cy + 6)); t.line(to: NSPoint(x: cx - 6, y: cy + 1.5))
            t.line(to: NSPoint(x: cx - 2.5, y: cy + 3.75)); t.close(); t.fill()
            for (i, y) in [cy + 3.75, cy - 0.5, cy - 4.5].enumerated() {
                let x = i == 0 ? cx - 0.5 : cx - 6
                NSRect(x: x, y: y - 0.9, width: cx + 6 - x, height: 1.8).fill()
            }
        case .eject:
            let t = NSBezierPath()
            t.move(to: NSPoint(x: cx - 6, y: cy - 1)); t.line(to: NSPoint(x: cx + 6, y: cy - 1)); t.line(to: NSPoint(x: cx, y: cy + 5))
            t.close(); t.fill()
            NSRect(x: cx - 6, y: cy - 5, width: 12, height: 2).fill()
        case .reconnect:
            // The restart mark: a ring broken at the top with a bar through
            // the gap. Two half-rings read as "oo" at this size.
            let ring = NSBezierPath()
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.appendArc(withCenter: NSPoint(x: cx, y: cy - 0.5), radius: 4.6,
                           startAngle: 68, endAngle: 112, clockwise: true)
            ring.stroke()
            let bar = NSBezierPath()
            bar.lineWidth = 1.8
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: cx, y: cy + 1.4))
            bar.line(to: NSPoint(x: cx, y: cy + 6.2))
            bar.stroke()
        case .sync:
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 5, startAngle: 20, endAngle: 160)
            p.stroke()
            let q = NSBezierPath()
            q.lineWidth = 1.6
            q.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 5, startAngle: 200, endAngle: 340)
            q.stroke()
            for (ang, dir) in [(160.0, 1.0), (340.0, -1.0)] as [(CGFloat, CGFloat)] {
                let rad = ang * .pi / 180
                let tip = NSPoint(x: cx + 5 * cos(rad), y: cy + 5 * sin(rad))
                let a = NSBezierPath()
                a.move(to: NSPoint(x: tip.x - 3 * dir, y: tip.y + 2 * dir))
                a.line(to: NSPoint(x: tip.x + 1 * dir, y: tip.y + 2.5 * dir))
                a.line(to: NSPoint(x: tip.x - 0.5 * dir, y: tip.y - 2 * dir))
                a.close(); a.fill()
            }
        }
    }
}

/// A small caption under a toolbar item, "View" or "Search", embossed.
final class AquaCaption: NSView {
    var text: String { didSet { needsDisplay = true } }
    init(_ text: String) { self.text = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let emboss = NSShadow()
        emboss.shadowColor = NSColor.white.withAlphaComponent(0.8)
        emboss.shadowOffset = NSSize(width: 0, height: -1)
        emboss.shadowBlurRadius = 0
        (text as NSString).draw(in: bounds, withAttributes: [
            .font: Aqua.font(10), .foregroundColor: NSColor(white: 0.25, alpha: 1),
            .paragraphStyle: style, .shadow: emboss,
        ])
    }
}

/// The small square checkbox from the track list: a white box with a
/// hairline border and a dark tick. Sends its action when clicked.
final class AquaCheckbox: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    weak var target: AnyObject?
    var action: Selector?

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: round(bounds.midX - 5.5), y: round(bounds.midY - 5.5), width: 11, height: 11).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!.draw(in: path, angle: -90)
        NSColor(white: 0.45, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard isOn else { return }
        let tick = NSBezierPath()
        tick.lineWidth = 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        tick.move(to: NSPoint(x: box.minX + 2.2, y: box.midY))
        tick.line(to: NSPoint(x: box.minX + 4.6, y: box.minY + 2.4))
        tick.line(to: NSPoint(x: box.maxX - 1.8, y: box.maxY - 1.6))
        NSColor(white: 0.15, alpha: 1).setStroke()
        tick.stroke()
    }
}


/// Five stars, as the Rating column drew them: faint dots when unrated,
/// solid stars once set. Click a star to rate; click the first star twice
/// to clear. Sends `action` with `rating` in 0...100.
final class AquaRatingView: NSView {
    var rating = 0 { didSet { needsDisplay = true } }
    var isEmphasized = false { didSet { needsDisplay = true } }
    weak var target: AnyObject?
    var action: Selector?
    private let step: CGFloat = 12

    override var intrinsicContentSize: NSSize { NSSize(width: step * 5 + 4, height: 14) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let star = max(1, min(5, Int((p.x - 2) / step) + 1))
        let value = star * 20
        rating = (rating == value && star == 1) ? 0 : value
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }

    private func starPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        for k in 0..<10 {
            let r = k % 2 == 0 ? radius : radius * 0.45
            let a = CGFloat(k) * .pi / 5 + .pi / 2
            let pt = NSPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if k == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        let stars = rating / 20
        let on: NSColor = isEmphasized ? .white : NSColor(white: 0.30, alpha: 1)
        let off: NSColor = isEmphasized ? NSColor(white: 1, alpha: 0.45) : NSColor(white: 0.72, alpha: 1)
        for i in 0..<5 {
            let c = NSPoint(x: 2 + step * CGFloat(i) + step / 2, y: bounds.midY)
            if i < stars {
                on.setFill()
                starPath(center: c, radius: 5.2).fill()
            } else {
                off.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
            }
        }
    }
}
