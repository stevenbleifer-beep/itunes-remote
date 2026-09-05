import Cocoa

enum SidebarIcon {
    case music, recent, duplicates, playlist, smartPlaylist, folder, curator, ipod, speaker, none
}

/// The small grey triangle beside a folder: right when closed, down when
/// open. It takes the click itself, so opening a folder does not also
/// select it.
final class SidebarDisclosureView: NSView {
    var expanded = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let cx = bounds.midX, cy = bounds.midY
        let p = NSBezierPath()
        if expanded {
            p.move(to: NSPoint(x: cx - 4, y: cy + 2.5))
            p.line(to: NSPoint(x: cx + 4, y: cy + 2.5))
            p.line(to: NSPoint(x: cx, y: cy - 2.5))
        } else {
            p.move(to: NSPoint(x: cx - 2.5, y: cy + 4))
            p.line(to: NSPoint(x: cx - 2.5, y: cy - 4))
            p.line(to: NSPoint(x: cx + 2.5, y: cy))
        }
        p.close()
        NSColor(srgbRed: 0.40, green: 0.45, blue: 0.52, alpha: 1).setFill()
        p.fill()
    }
}

/// The sidebar row: a small drawn icon and a label, as iTunes 10 laid out
/// its source list. The icons are paths, not images.
final class SidebarCellView: NSTableCellView {
    let iconView = SidebarIconView()
    let label = NSTextField(labelWithString: "")
    let triangle = SidebarDisclosureView()
    private var iconLeading: NSLayoutConstraint!
    private var triangleLeading: NSLayoutConstraint!

    /// How far in the row sits: playlists inside a folder step in under it.
    var indent: CGFloat = 0 { didSet { relayout() } }
    /// nil for an ordinary row; true or false for a folder that is open or shut.
    var disclosure: Bool? = nil { didSet { relayout() } }
    var onToggle: (() -> Void)? { didSet { triangle.onClick = onToggle } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        triangle.translatesAutoresizingMaskIntoConstraints = false
        triangle.isHidden = true
        label.font = Aqua.font(12)
        label.textColor = .controlTextColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(triangle)
        addSubview(iconView)
        addSubview(label)
        textField = label
        iconLeading = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        triangleLeading = triangle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            iconLeading,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            triangleLeading,
            triangle.centerYAnchor.constraint(equalTo: centerYAnchor),
            triangle.widthAnchor.constraint(equalToConstant: 10),
            triangle.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func relayout() {
        triangle.isHidden = disclosure == nil
        triangle.expanded = disclosure ?? false
        triangleLeading.constant = 4 + indent
        iconLeading.constant = 6 + indent + (disclosure == nil ? 0 : 12)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            label.font = Aqua.font(12, bold: selected && !Theme.isModern)
            iconView.selected = selected
        }
    }
}

final class SidebarIconView: NSView {
    var icon: SidebarIcon = .none { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // Modern: the accent colour, the way the Finder's sidebar tints its icons.
        let fill = Theme.isModern ? Theme.accent : (selected ? NSColor.white : NSColor(srgbRed: 0.32, green: 0.40, blue: 0.52, alpha: 1))
        let dark = Theme.isModern ? Theme.accent : (selected ? NSColor(white: 1, alpha: 0.9) : NSColor(srgbRed: 0.20, green: 0.27, blue: 0.38, alpha: 1))
        let cx = bounds.midX, cy = bounds.midY
        switch icon {
        case .none:
            return
        case .music:
            // A beamed eighth-note pair.
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 6.5, y: cy - 6, width: 5, height: 3.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx + 1, y: cy - 4.5, width: 5, height: 3.6)).fill()
            NSRect(x: cx - 2.4, y: cy - 4.5, width: 1.4, height: 9).fill()
            NSRect(x: cx + 5, y: cy - 3, width: 1.4, height: 9).fill()
            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: cx - 2.4, y: cy + 4.5)); beam.line(to: NSPoint(x: cx + 6.4, y: cy + 6))
            beam.line(to: NSPoint(x: cx + 6.4, y: cy + 3.5)); beam.line(to: NSPoint(x: cx - 2.4, y: cy + 2))
            beam.close(); beam.fill()
        case .recent:
            // A clock face, for Recently Added.
            let r: CGFloat = 7
            let dial = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            (selected ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 1, alpha: 0.9)).setFill()
            dial.fill()
            fill.setStroke()
            dial.lineWidth = 1.6
            dial.stroke()
            let hands = NSBezierPath()
            hands.lineWidth = 1.5
            hands.lineCapStyle = .round
            hands.move(to: NSPoint(x: cx, y: cy)); hands.line(to: NSPoint(x: cx, y: cy + 4))
            hands.move(to: NSPoint(x: cx, y: cy)); hands.line(to: NSPoint(x: cx + 3, y: cy - 1))
            fill.setStroke()
            hands.stroke()
        case .playlist:
            // A note on a small square page.
            let page = NSBezierPath(roundedRect: NSRect(x: cx - 6.5, y: cy - 6.5, width: 13, height: 13), xRadius: 2, yRadius: 2)
            (selected ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 1, alpha: 0.9)).setFill()
            page.fill()
            dark.setStroke()
            page.lineWidth = 1
            page.stroke()
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 3.5, y: cy - 4, width: 4, height: 3)).fill()
            NSRect(x: cx - 0.2, y: cy - 3, width: 1.2, height: 7).fill()
            NSRect(x: cx - 0.2, y: cy + 3, width: 3.5, height: 1.2).fill()
        case .smartPlaylist:
            // A gear on a page.
            let page = NSBezierPath(roundedRect: NSRect(x: cx - 6.5, y: cy - 6.5, width: 13, height: 13), xRadius: 2, yRadius: 2)
            (selected ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 1, alpha: 0.9)).setFill()
            page.fill()
            dark.setStroke()
            page.lineWidth = 1
            page.stroke()
            fill.setFill()
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                NSRect(x: cx + cos(a) * 3.6 - 0.9, y: cy + sin(a) * 3.6 - 0.9, width: 1.8, height: 1.8).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: cx - 3, y: cy - 3, width: 6, height: 6)).fill()
            (selected ? NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1) : NSColor(white: 1, alpha: 0.9)).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 1.2, y: cy - 1.2, width: 2.4, height: 2.4)).fill()
        case .folder:
            // A folder: the tab, then the body over it.
            let tab = NSBezierPath(roundedRect: NSRect(x: cx - 7, y: cy - 1, width: 6.5, height: 5.5), xRadius: 1, yRadius: 1)
            fill.setFill()
            tab.fill()
            let body = NSBezierPath(roundedRect: NSRect(x: cx - 7, y: cy - 5.5, width: 14, height: 8.5), xRadius: 1.2, yRadius: 1.2)
            body.fill()
            (selected ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 1, alpha: 0.35)).setFill()
            NSRect(x: cx - 6, y: cy + 1.5, width: 12, height: 1).fill()
        case .duplicates:
            // Two overlapping sheets: the same thing, twice.
            for (dx, dy) in [(-2.5, 1.5), (1.5, -2.5)] as [(CGFloat, CGFloat)] {
                let sheet = NSBezierPath(roundedRect: NSRect(x: cx - 4 + dx, y: cy - 4.5 + dy, width: 8, height: 9), xRadius: 1, yRadius: 1)
                (selected ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 1, alpha: 0.9)).setFill()
                sheet.fill()
                fill.setStroke()
                sheet.lineWidth = 1.3
                sheet.stroke()
            }
        case .curator:
            // The Genius atom iTunes 8 wore: a nucleus with two crossed
            // orbits. The curator does what Genius did, with a mind of its own.
            fill.setStroke()
            for angle in [-55.0, 55.0] as [CGFloat] {
                let orbit = NSBezierPath(ovalIn: NSRect(x: -7, y: -3, width: 14, height: 6))
                var t = AffineTransform(translationByX: cx, byY: cy)
                t.rotate(byDegrees: angle)
                orbit.transform(using: t)
                orbit.lineWidth = 1.2
                orbit.stroke()
            }
            fill.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - 2.2, y: cy - 2.2, width: 4.4, height: 4.4)).fill()
        case .ipod:
            let body = NSBezierPath(roundedRect: NSRect(x: cx - 4.5, y: cy - 7, width: 9, height: 14), xRadius: 2, yRadius: 2)
            fill.setFill()
            body.fill()
            (selected ? NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
            NSRect(x: cx - 3, y: cy + 1, width: 6, height: 4.5).fill()
            NSBezierPath(ovalIn: NSRect(x: cx - 2.75, y: cy - 5.75, width: 5.5, height: 5.5)).fill()
        case .speaker:
            // Marks the source the current song is playing from, the way
            // iTunes put a small speaker beside the playing playlist.
            fill.setFill()
            let cone = NSBezierPath()
            cone.move(to: NSPoint(x: cx - 6, y: cy - 2.5))
            cone.line(to: NSPoint(x: cx - 3, y: cy - 2.5))
            cone.line(to: NSPoint(x: cx + 0.5, y: cy - 6))
            cone.line(to: NSPoint(x: cx + 0.5, y: cy + 6))
            cone.line(to: NSPoint(x: cx - 3, y: cy + 2.5))
            cone.line(to: NSPoint(x: cx - 6, y: cy + 2.5))
            cone.close()
            cone.fill()
            dark.setStroke()
            for (r, w) in [(3.0, 1.2), (5.5, 1.2)] as [(CGFloat, CGFloat)] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: cx + 0.5, y: cy), radius: r,
                              startAngle: -42, endAngle: 42)
                arc.lineWidth = w
                arc.stroke()
            }
        }
    }
}
