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

    // The modern palette. Light, quiet, with the system accent for anything selected.
    static let windowBackground = NSColor(white: 0.965, alpha: 1)
    static let contentBackground = NSColor.white
    static let sidebarBackground = NSColor(white: 0.955, alpha: 1)
    static let hairline = NSColor(white: 0, alpha: 0.10)
    static let text = NSColor(white: 0.12, alpha: 1)
    static let secondaryText = NSColor(white: 0.45, alpha: 1)
    static let controlFill = NSColor(white: 0, alpha: 0.06)
    static let controlFillPressed = NSColor(white: 0, alpha: 0.13)
    static let stripe = NSColor(white: 0.975, alpha: 1)
    static var accent: NSColor { NSColor.controlAccentColor }

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
