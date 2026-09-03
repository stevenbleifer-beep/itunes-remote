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
    static let accent = NSColor(srgbRed: 0.16, green: 0.42, blue: 0.85, alpha: 1)

    /// mm:ss, as the display panel and track table show durations.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
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

/// The recessed display in the middle of the toolbar. Two modes: an idle mode
/// showing the library name and count, and a playing mode with the track,
/// "artist — album", and a scrubber that can be dragged to seek.
final class AquaDisplayPanel: NSView {
    var primary: String = "" { didSet { needsDisplay = true } }
    var secondary: String = "" { didSet { needsDisplay = true } }

    /// Nil puts the panel in idle mode.
    var duration: Double? { didSet { needsDisplay = true } }
    var position: Double = 0 {
        didSet { if !isScrubbing && abs(position - oldValue) > 0.2 { needsDisplay = true } }
    }
    var onSeek: (Double) -> Void = { _ in }
    /// The two circled glyphs are real controls, not decoration: the left one
    /// plays and pauses, the right one opens the output menu.
    var onPlayPause: () -> Void = {}
    var onAirPlay: (NSView) -> Void = { _ in }

    private(set) var isScrubbing = false
    private var scrubPosition: Double = 0

    // Room either side of the groove for the corner glyph and the elapsed /
    // remaining label. 40 clipped "-2:40" to "-2:".
    private let sideInset: CGFloat = 56
    private let glyphRadius: CGFloat = 6

    private var grooveRect: NSRect {
        NSRect(x: sideInset, y: 6, width: bounds.width - 2 * sideInset, height: 5)
    }

    private var leftGlyphRect: NSRect {
        NSRect(x: 12 - glyphRadius, y: bounds.midY - glyphRadius, width: glyphRadius * 2, height: glyphRadius * 2)
    }

    private var rightGlyphRect: NSRect {
        NSRect(x: bounds.width - 12 - glyphRadius, y: bounds.midY - glyphRadius,
               width: glyphRadius * 2, height: glyphRadius * 2)
    }

    // MARK: Scrubbing

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The glyphs are small, so give them a slightly larger target than
        // they are drawn, and test them before the groove.
        if leftGlyphRect.insetBy(dx: -4, dy: -4).contains(p) {
            onPlayPause()
            return
        }
        if rightGlyphRect.insetBy(dx: -4, dy: -4).contains(p) {
            onAirPlay(self)
            return
        }
        guard let total = duration, total > 0 else { return }
        let hit = grooveRect.insetBy(dx: -6, dy: -7)
        guard hit.contains(p) else { return }
        isScrubbing = true
        update(with: event, total: total)
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            update(with: e, total: total)
            if e.type == .leftMouseUp { break }
        }
        isScrubbing = false
        position = scrubPosition
        onSeek(scrubPosition)
    }

    private func update(with event: NSEvent, total: Double) {
        let p = convert(event.locationInWindow, from: nil)
        let g = grooveRect
        let f = min(1, max(0, (p.x - g.minX) / g.width))
        scrubPosition = Double(f) * total
        needsDisplay = true
    }

    private var shownPosition: Double { isScrubbing ? scrubPosition : position }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)

        // A one-pixel white line below the panel: the bevel of the recess.
        NSColor(white: 1, alpha: 0.6).setStroke()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: -1), xRadius: 4, yRadius: 4).stroke()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // The pale yellow-green of the iTunes 10 display.
        NSGradient(starting: NSColor(srgbRed: 0.85, green: 0.88, blue: 0.78, alpha: 1),
                   ending: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1))!
            .draw(in: r, angle: -90)
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

        if duration == nil {
            drawIdle()
        } else {
            drawPlaying()
        }
        drawCornerGlyphs()
    }

    /// The small circled glyphs in the display's corners: play or pause at the
    /// left, the output picker at the right. Both are clickable.
    var isPlaying = false { didSet { needsDisplay = true } }
    var airPlayActive = false { didSet { needsDisplay = true } }

    private func drawCornerGlyphs() {
        let color = airPlayActive ? Aqua.accent : NSColor(white: 0.45, alpha: 1)
        let cy = bounds.midY
        func circle(_ cx: CGFloat, _ fill: NSColor) {
            let p = NSBezierPath(ovalIn: NSRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
            fill.setFill()
            p.fill()
        }
        // Left: play (triangle) or pause (bars), knocked out of a dark disc.
        let lx: CGFloat = 12
        circle(lx, NSColor(white: 0.45, alpha: 1))
        NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1).setFill()
        if isPlaying {
            NSRect(x: lx - 2.6, y: cy - 2.6, width: 1.8, height: 5.2).fill()
            NSRect(x: lx + 0.8, y: cy - 2.6, width: 1.8, height: 5.2).fill()
        } else {
            let t = NSBezierPath()
            t.move(to: NSPoint(x: lx - 2, y: cy - 3)); t.line(to: NSPoint(x: lx + 3, y: cy)); t.line(to: NSPoint(x: lx - 2, y: cy + 3))
            t.close(); t.fill()
        }
        // Right: the AirPlay mark, lit when something other than this Mac is
        // playing. Clicking it opens the same output menu as the toolbar.
        let rx = bounds.width - 12
        circle(rx, color)
        let ink = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.87, alpha: 1)
        ink.setStroke()
        ink.setFill()
        let screen = NSBezierPath(roundedRect: NSRect(x: rx - 3.6, y: cy - 1.2, width: 7.2, height: 4.8),
                                  xRadius: 0.8, yRadius: 0.8)
        screen.lineWidth = 1
        screen.stroke()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: rx - 2.8, y: cy - 3.8)); tri.line(to: NSPoint(x: rx + 2.8, y: cy - 3.8))
        tri.line(to: NSPoint(x: rx, y: cy - 1.2))
        tri.close(); tri.fill()
    }

    private func centred(_ text: String, _ rect: NSRect, size: CGFloat, bold: Bool = false, alpha: CGFloat = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: Aqua.font(size, bold: bold),
            .foregroundColor: NSColor(white: 0.25, alpha: alpha),
            .paragraphStyle: style,
        ])
    }

    private func drawIdle() {
        if secondary.isEmpty {
            centred(primary, NSRect(x: 8, y: bounds.midY - 8, width: bounds.width - 16, height: 17), size: 12, bold: true)
        } else {
            centred(primary, NSRect(x: 8, y: bounds.midY + 1, width: bounds.width - 16, height: 17), size: 12, bold: true)
            centred(secondary, NSRect(x: 8, y: bounds.midY - 15, width: bounds.width - 16, height: 15), size: 11)
        }
    }

    private func drawPlaying() {
        let total = duration ?? 0
        let pos = min(total, max(0, shownPosition))
        let w = bounds.width - 52

        // Lay the two lines out from the top and the groove from the bottom,
        // so the subtitle no longer sits on the scrubber the way it did at
        // this panel's real height.
        let titleH: CGFloat = 14, subtitleH: CGFloat = 13
        let titleY = bounds.maxY - 3 - titleH
        centred(primary, NSRect(x: 26, y: titleY, width: w, height: titleH), size: 12, bold: true)
        centred(secondary, NSRect(x: 26, y: titleY - subtitleH, width: w, height: subtitleH), size: 11)

        // Times either side of the groove.
        let g = grooveRect
        let timeStyle = NSMutableParagraphStyle()
        timeStyle.alignment = .center
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(9), .foregroundColor: NSColor(white: 0.35, alpha: 1), .paragraphStyle: timeStyle,
        ]
        let timeY = g.midY - 6
        (Aqua.clock(pos) as NSString).draw(
            in: NSRect(x: 21, y: timeY, width: sideInset - 25, height: 12), withAttributes: timeAttrs)
        (("-" + Aqua.clock(max(0, total - pos))) as NSString).draw(
            in: NSRect(x: g.maxX + 4, y: timeY, width: sideInset - 25, height: 12), withAttributes: timeAttrs)

        // Groove, recessed.
        let groove = NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(white: 0.72, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))!
            .draw(in: groove, angle: -90)
        NSColor(white: 0.56, alpha: 1).setStroke()
        NSBezierPath(roundedRect: g.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()

        guard total > 0 else { return }
        let f = CGFloat(pos / total)

        // Filled portion.
        if f > 0.01 {
            let filled = NSRect(x: g.minX, y: g.minY, width: g.width * f, height: g.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2).addClip()
            NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.88, alpha: 1),
                       ending: NSColor(srgbRed: 0.26, green: 0.46, blue: 0.80, alpha: 1))!
                .draw(in: filled, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Knob.
        let d: CGFloat = isScrubbing ? 12 : 10
        let c = NSPoint(x: g.minX + g.width * f, y: g.midY)
        let kr = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let knob = NSBezierPath(ovalIn: kr.insetBy(dx: 0.5, dy: 0.5))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 1.5
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()
        NSColor(white: 0.85, alpha: 1).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.80, alpha: 1))!
            .draw(in: knob, angle: -90)
        NSColor(white: 0.40, alpha: 1).setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }
}

/// The AirPlay output button: the speaker-and-triangle glyph, tinted blue when
/// something other than the computer is selected. Click opens the device menu.
final class AquaAirPlayButton: NSView {
    var isActive = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: (NSView) -> Void = { _ in }
    private var isPressed = false

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 22) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        onClick(self)
        isPressed = false
        needsDisplay = true
    }

    /// Apple's own AirPlay symbol, obtained through the system-symbol API at
    /// run time. Nothing is bundled; the system draws it.
    private static let symbol: NSImage? = {
        let base = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "AirPlay")
        return base?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
    }()

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = !isEnabled ? NSColor(white: 0.62, alpha: 1)
            : isActive ? Aqua.accent : Aqua.glyph
        if isPressed || isActive {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            (isActive ? Aqua.accent.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).setFill()
            bg.fill()
        }
        guard let symbol = AquaAirPlayButton.symbol,
              let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) else { return }
        let size = tinted.size
        let origin = NSPoint(x: round(bounds.midX - size.width / 2), y: round(bounds.midY - size.height / 2))
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Album art with the iTunes 10 frame, plus a drawn placeholder. Square.
final class ArtworkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var caption: String = "" { didSet { needsDisplay = true } }
    /// Thumbnail mode: the cover fills the view with no background or caption.
    var fillsBounds = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat
        let box: NSRect
        if fillsBounds {
            side = min(bounds.width, bounds.height) - 2
            box = NSRect(x: round(bounds.midX - side / 2), y: round(bounds.midY - side / 2), width: side, height: side)
        } else {
            Aqua.sidebarBackground.setFill()
            bounds.fill()
            side = min(bounds.width, bounds.height - 16) - 16
            box = NSRect(x: round(bounds.midX - side / 2), y: bounds.maxY - side - 6, width: side, height: side)
        }
        guard side > 12 else { return }

        if let img = image {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
            sh.shadowBlurRadius = 3
            sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.set()
            NSColor.white.setFill()
            NSBezierPath(rect: box).fill()
            NSGraphicsContext.restoreGraphicsState()
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.88, alpha: 1))!
                .draw(in: box, angle: -90)
            // A drawn disc, so no artwork ships with the app.
            let c = NSPoint(x: box.midX, y: box.midY)
            let r = side * 0.24
            NSColor(white: 0.78, alpha: 1).setStroke()
            for k in [1.0, 0.72, 0.44] as [CGFloat] {
                let p = NSBezierPath(ovalIn: NSRect(x: c.x - r * k, y: c.y - r * k, width: r * k * 2, height: r * k * 2))
                p.lineWidth = 1
                p.stroke()
            }
            NSColor(white: 0.80, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
        }
        NSColor(white: 0.55, alpha: 1).setStroke()
        NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()

        if !caption.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let emboss = NSShadow()
            emboss.shadowColor = NSColor.white.withAlphaComponent(0.9)
            emboss.shadowOffset = NSSize(width: 0, height: -1)
            emboss.shadowBlurRadius = 0
            (caption as NSString).draw(in: NSRect(x: 4, y: 2, width: bounds.width - 8, height: 14), withAttributes: [
                .font: Aqua.font(9, bold: true),
                .foregroundColor: Aqua.sidebarHeaderText,
                .paragraphStyle: style,
                .shadow: emboss,
            ])
        }
    }
}
