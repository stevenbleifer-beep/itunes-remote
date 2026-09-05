import Cocoa

/// A small status light with a word beside it, the way iChat showed
/// presence: green for the local network, amber for the tunnel, grey while
/// it is still working out which. Lives at the right end of the status bar.
final class AquaConnectionBadge: NSView {
    enum State { case connecting, home, away }

    var state: State = .connecting {
        didSet { needsDisplay = true; invalidateIntrinsicContentSize() }
    }
    /// "Thunderbolt" or "Wi-Fi", shown after Home when known.
    var link = "" {
        didSet { needsDisplay = true; invalidateIntrinsicContentSize() }
    }

    private var text: String {
        switch state {
        case .connecting: return "Connecting…"
        case .home: return link.isEmpty ? "Home network" : "Home · \(link)"
        case .away: return "Away via Tailscale"
        }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let emboss = NSShadow()
        emboss.shadowColor = NSColor.white.withAlphaComponent(Theme.isModern ? 0 : 0.7)
        emboss.shadowOffset = NSSize(width: 0, height: -1)
        return [.font: Aqua.font(11), .foregroundColor: Theme.isModern ? Theme.secondaryText : NSColor(white: 0.25, alpha: 1), .shadow: emboss]
    }

    override var intrinsicContentSize: NSSize {
        let w = (text as NSString).size(withAttributes: attributes).width
        return NSSize(width: ceil(w) + 18, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let (top, bottom): (NSColor, NSColor)
        switch state {
        case .connecting:
            (top, bottom) = (NSColor(white: 0.80, alpha: 1), NSColor(white: 0.55, alpha: 1))
        case .home:
            (top, bottom) = (NSColor(srgbRed: 0.62, green: 0.93, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.20, green: 0.62, blue: 0.10, alpha: 1))
        case .away:
            (top, bottom) = (NSColor(srgbRed: 1.0, green: 0.85, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.85, green: 0.50, blue: 0.05, alpha: 1))
        }
        // The light: a gradient ball with a highlight, like the Aqua era's.
        let r = NSRect(x: 2, y: round(bounds.midY) - 5, width: 10, height: 10)
        let ball = NSBezierPath(ovalIn: r)
        if Theme.isModern {
            // A plain dot, the modern status light.
            bottom.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            let a = attributes
            let s = (text as NSString).size(withAttributes: a)
            (text as NSString).draw(at: NSPoint(x: r.maxX + 5, y: round(bounds.midY - s.height / 2)), withAttributes: a)
            return
        }
        NSGradient(starting: top, ending: bottom)?.draw(in: ball, angle: -90)
        bottom.withAlphaComponent(0.7).setStroke()
        ball.lineWidth = 0.8
        ball.stroke()
        let gloss = NSBezierPath(ovalIn: NSRect(x: r.minX + 2, y: r.midY + 1, width: r.width - 4, height: r.height / 2 - 1.5))
        NSGradient(starting: NSColor.white.withAlphaComponent(0.85), ending: NSColor.white.withAlphaComponent(0.05))?.draw(in: gloss, angle: -90)

        let a = attributes
        let s = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: r.maxX + 5, y: round(bounds.midY - s.height / 2)), withAttributes: a)
    }
}
