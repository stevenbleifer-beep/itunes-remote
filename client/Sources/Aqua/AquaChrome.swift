import Cocoa

/// Shared colours and fonts for the iTunes 10 look. Nothing is loaded from
/// disk; every surface is a gradient drawn in code.
enum Aqua {
    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let name = bold ? "LucidaGrande-Bold" : "LucidaGrande"
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    // Lists
    static let stripe = NSColor(srgbRed: 0.953, green: 0.965, blue: 0.980, alpha: 1)      // #F3F6FA
    static let gridLine = NSColor(white: 0.87, alpha: 1)
    static let selectionTopKey = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.89, alpha: 1)
    static let selectionBottomKey = NSColor(srgbRed: 0.20, green: 0.41, blue: 0.79, alpha: 1)
    static let selectionTopInactive = NSColor(white: 0.72, alpha: 1)
    static let selectionBottomInactive = NSColor(white: 0.58, alpha: 1)

    // Sidebar
    static let sidebarBackground = NSColor(srgbRed: 0.878, green: 0.902, blue: 0.933, alpha: 1)  // #E0E6EE
    static let sidebarHeaderText = NSColor(srgbRed: 0.40, green: 0.45, blue: 0.52, alpha: 1)

    // Chrome (toolbar, status bar, panels)
    static let chromeTop = NSColor(white: 0.92, alpha: 1)
    static let chromeBottom = NSColor(white: 0.76, alpha: 1)
    static let chromeLine = NSColor(white: 0.48, alpha: 1)
    static let chromeHighlight = NSColor(white: 1.0, alpha: 0.55)
    static let glyph = NSColor(white: 0.22, alpha: 1)
}

/// A flat light-gray gradient surface: the unified toolbar of Snow Leopard
/// and Lion. `topLine` / `bottomLine` add the one-pixel separators.
class ChromeView: NSView {
    var topLine = false
    var bottomLine = false
    var gradientTop: NSColor = Aqua.chromeTop
    var gradientBottom: NSColor = Aqua.chromeBottom

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: gradientTop, ending: gradientBottom)!.draw(in: bounds, angle: -90)
        if topLine {
            Aqua.chromeLine.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
            Aqua.chromeHighlight.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 1).fill()
        }
        if bottomLine {
            Aqua.chromeLine.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }
}

/// The recessed display in the middle of the toolbar. Milestone 4 fills it
/// with the now-playing state and a scrubber; for now it shows status text.
final class AquaDisplayPanel: NSView {
    var primary: String = "" { didSet { needsDisplay = true } }
    var secondary: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)

        // A one-pixel white line below the panel: the bevel of the recess.
        NSColor(white: 1, alpha: 0.6).setStroke()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: -1), xRadius: 4, yRadius: 4).stroke()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: NSColor(white: 0.90, alpha: 1), ending: NSColor(white: 0.97, alpha: 1))!
            .draw(in: r, angle: -90)
        // Inset shadow that falls into the panel from the top edge.
        let inset = NSShadow()
        inset.shadowColor = NSColor.black.withAlphaComponent(0.35)
        inset.shadowBlurRadius = 3
        inset.shadowOffset = NSSize(width: 0, height: -2)
        inset.set()
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: -6, dy: -6), xRadius: 8, yRadius: 8)
        outer.append(path)
        outer.windingRule = .evenOdd
        NSColor.black.setFill()
        outer.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 0.55, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let pStyle = NSMutableParagraphStyle()
        pStyle.alignment = .center
        pStyle.lineBreakMode = .byTruncatingTail
        let color = NSColor(white: 0.25, alpha: 1)
        let a1: [NSAttributedString.Key: Any] = [.font: Aqua.font(12, bold: true), .foregroundColor: color, .paragraphStyle: pStyle]
        let a2: [NSAttributedString.Key: Any] = [.font: Aqua.font(11), .foregroundColor: color, .paragraphStyle: pStyle]
        if secondary.isEmpty {
            (primary as NSString).draw(in: NSRect(x: 8, y: bounds.midY - 8, width: bounds.width - 16, height: 17), withAttributes: a1)
        } else {
            (primary as NSString).draw(in: NSRect(x: 8, y: bounds.midY + 1, width: bounds.width - 16, height: 17), withAttributes: a1)
            (secondary as NSString).draw(in: NSRect(x: 8, y: bounds.midY - 15, width: bounds.width - 16, height: 15), withAttributes: a2)
        }
    }
}
