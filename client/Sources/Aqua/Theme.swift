import Cocoa

/// Which of the two looks the app wears: the iTunes 10 Aqua that every
/// control was drawn for, or a modern one — flat, translucent, with the
/// system's glass under the toolbar, the display and the transport buttons.
///
/// Every drawn control asks here at draw time. The choice is read once at
/// launch (View ▸ Appearance relaunches the app to switch), so nothing
/// half-redraws. The modern look is light-only for now: the app's own
/// labels carry fixed greys that a dark window would swallow.
enum Theme {
    static let isModern: Bool = UserDefaults.standard.string(forKey: "appearance") == "modern"
    static var name: String { isModern ? "Modern Glass" : "Classic iTunes 10" }

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        isModern ? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) : Aqua.lucida(size, bold: bold)
    }

    // The modern palette: dynamic, so the same names answer in light and dark.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let windowBackground = dynamic(NSColor(white: 0.965, alpha: 1), NSColor(white: 0.15, alpha: 1))
    static let contentBackground = dynamic(.white, NSColor(white: 0.11, alpha: 1))
    static let sidebarBackground = dynamic(NSColor(white: 0.955, alpha: 1), NSColor(white: 0.17, alpha: 1))
    static let hairline = dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 1, alpha: 0.12))
    static let text = dynamic(NSColor(white: 0.12, alpha: 1), NSColor(white: 0.92, alpha: 1))
    static let secondaryText = dynamic(NSColor(white: 0.45, alpha: 1), NSColor(white: 0.60, alpha: 1))
    static let controlFill = dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.08))
    static let controlFillPressed = dynamic(NSColor(white: 0, alpha: 0.13), NSColor(white: 1, alpha: 0.16))
    static let stripe = dynamic(NSColor(white: 0.975, alpha: 1), NSColor(white: 0.135, alpha: 1))
    /// Something that sits up off the surface: a knob, a pill, a button.
    static let raised = dynamic(.white, NSColor(white: 0.34, alpha: 1))
    static var accent: NSColor { NSColor.controlAccentColor }

    /// A page-white background: paper in the light, near-black in the dark.
    /// Classic stays white.
    static var paper: NSColor { isModern ? contentBackground : .white }

    /// A fixed grey from the classic drawing, kept as it is there and
    /// turned over for the modern look in the dark: a 0.2 text grey becomes
    /// a light one, a 0.97 panel becomes a dark one.
    static func ink(_ white: CGFloat) -> NSColor {
        guard isModern else { return NSColor(white: white, alpha: 1) }
        return dynamic(NSColor(white: white, alpha: 1), NSColor(white: max(0.05, min(0.95, 0.92 - 0.85 * white)), alpha: 1))
    }

    /// The system appearance the app should wear: the modern look follows
    /// the system (light or dark); classic is always Aqua.
    static var appearance: NSAppearance? {
        if CommandLine.arguments.contains("--dark") { return NSAppearance(named: .darkAqua) }
        return isModern ? nil : NSAppearance(named: .aqua)
    }

    static var scrollerStyle: NSScroller.Style { isModern ? .overlay : .legacy }

    /// A translucent surface: the desktop shows through, blurred.
    static func material(_ material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    /// A glass card holding `content`. The system's glass on macOS 26; a
    /// rounded translucent panel before that.
    static func glass(around content: NSView, radius: CGFloat) -> NSView {
        let frame = content.frame
        let mask = content.autoresizingMask
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26, *) {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = radius
            g.contentView = content
            g.autoresizingMask = mask
            return g
        }
        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        v.addSubview(content)
        v.autoresizingMask = mask
        return v
    }

    /// A rounded selection pill, the modern table's highlight.
    static func selectionPill(in bounds: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6)
    }
}
