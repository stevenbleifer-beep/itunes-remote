import Cocoa

/// Shared colours and fonts for the iTunes 10 look. Nothing is loaded from
/// disk; every surface is a gradient drawn in code.
enum Aqua {
    /// The app's text face: Lucida Grande in the classic look, the system
    /// font in the modern one. Every label goes through here.
    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont { Theme.font(size, bold: bold) }

    static func lucida(_ size: CGFloat, bold: Bool) -> NSFont {
        let name = bold ? "LucidaGrande-Bold" : "LucidaGrande"
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    // Lists
    static let stripe = NSColor(srgbRed: 0.953, green: 0.965, blue: 0.980, alpha: 1)      // #F3F6FA
    static let gridLine = Theme.ink(0.87)
    static let selectionTopKey = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.89, alpha: 1)
    static let selectionBottomKey = NSColor(srgbRed: 0.20, green: 0.41, blue: 0.79, alpha: 1)
    static let selectionTopInactive = Theme.ink(0.72)
    static let selectionBottomInactive = Theme.ink(0.58)

    // Sidebar
    static let classicSidebarBackground = NSColor(srgbRed: 0.878, green: 0.902, blue: 0.933, alpha: 1)  // #E0E6EE
    static var sidebarBackground: NSColor { Theme.isModern ? Theme.sidebarBackground : classicSidebarBackground }
    static var sidebarHeaderText: NSColor { Theme.isModern ? Theme.secondaryText : NSColor(srgbRed: 0.40, green: 0.45, blue: 0.52, alpha: 1) }

    // Chrome (toolbar, status bar, panels)
    static let chromeTop = Theme.ink(0.92)
    static let chromeBottom = Theme.ink(0.76)
    static let chromeLine = Theme.ink(0.48)
    static let chromeHighlight = NSColor(white: 1.0, alpha: 0.55)
    static let glyph = Theme.ink(0.22)
    static var accent: NSColor { Theme.isModern ? Theme.accent : NSColor(srgbRed: 0.16, green: 0.42, blue: 0.85, alpha: 1) }

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
    /// Makes this bar behave like a title bar: drag it to move the window, and
    /// double-click an empty part to zoom the window to fill the screen. The
    /// toolbar's buttons and display panel handle their own clicks first, so
    /// only clicks on the empty chrome reach this.
    var actsAsTitleBar = false
    /// Modern look: a translucent bar with the desktop blurred behind it
    /// (the toolbar and status bar) rather than a flat fill.
    var usesMaterial = false {
        didSet { if usesMaterial { installMaterial() } }
    }
    private var materialView: NSVisualEffectView?

    override var isOpaque: Bool { !Theme.isModern }

    private func installMaterial() {
        guard Theme.isModern, materialView == nil else { return }
        let v = Theme.material(.titlebar)
        v.frame = bounds
        v.autoresizingMask = [.width, .height]
        addSubview(v, positioned: .below, relativeTo: nil)
        materialView = v
    }

    override func mouseDown(with event: NSEvent) {
        guard actsAsTitleBar else { super.mouseDown(with: event); return }
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if Theme.isModern {
            // Flat, unless a material sits under it; hairlines either way.
            if materialView == nil {
                Theme.windowBackground.setFill()
                bounds.fill()
            }
            Theme.hairline.setFill()
            if topLine { NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill() }
            if bottomLine { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
            return
        }
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

    /// The glyphs and arrows are controls; a click on an inactive window
    /// should work them, as it does a real button.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Views

    /// What the display is showing. iTunes 10 stacked a pair of small arrows
    /// on the display when it had more than one thing to show — the song and
    /// an import or a sync — and clicking them cycled through. Same here.
    enum Mode { case player, sync }
    var mode: Mode = .player { didSet { needsDisplay = true; syncPulse() } }
    /// The views on offer. The arrows appear only when there is more than one.
    var modes: [Mode] = [.player] { didSet { if !modes.contains(mode) { mode = modes.first ?? .player }; needsDisplay = true } }
    var onCycleMode: (Mode) -> Void = { _ in }

    /// The sync view: a title, a line of detail, and a bar that is
    /// determinate when the job has a known size and a barber pole otherwise.
    var syncTitle: String = "" { didSet { needsDisplay = true } }
    var syncDetail: String = "" { didSet { needsDisplay = true } }
    var syncFraction: Double? { didSet { needsDisplay = true; syncPulse() } }

    private var poleTimer: Timer?
    private var polePhase: CGFloat = 0

    /// The barber pole moves only while it is on screen.
    private func syncPulse() {
        let wants = mode == .sync && syncFraction == nil
        if wants, poleTimer == nil {
            poleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.polePhase = (self.polePhase + 0.6).truncatingRemainder(dividingBy: 14)
                    self.setNeedsDisplay(self.grooveRect.insetBy(dx: -2, dy: -4))
                }
            }
        } else if !wants {
            poleTimer?.invalidate()
            poleTimer = nil
        }
    }

    // Room either side of the groove for the corner glyph and the elapsed /
    // remaining label. 40 clipped "-2:40" to "-2:".
    private let sideInset: CGFloat = 56
    private let glyphRadius: CGFloat = 6

    /// The stacked ▲▼ pair, between the text column and the AirPlay glyph.
    private var arrowsRect: NSRect {
        NSRect(x: bounds.width - 34, y: bounds.midY - 5, width: 8, height: 10)
    }
    private var showsArrows: Bool { modes.count > 1 }

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
        if showsArrows, arrowsRect.insetBy(dx: -5, dy: -6).contains(p) {
            guard let i = modes.firstIndex(of: mode) else { return }
            // Top half steps back, bottom half forward; with two views both
            // simply switch.
            let next = p.y > arrowsRect.midY ? modes[(i + modes.count - 1) % modes.count]
                                             : modes[(i + 1) % modes.count]
            mode = next
            onCycleMode(next)
            return
        }
        guard mode == .player, let total = duration, total > 0 else { return }
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
        if Theme.isModern {
            // The glass card behind this view is the bezel; only content here.
            switch mode {
            case .sync: drawSync()
            case .player: duration == nil ? drawIdle() : drawPlaying()
            }
            drawCornerGlyphs()
            if showsArrows { drawArrows() }
            return
        }
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

        Theme.ink(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        switch mode {
        case .sync: drawSync()
        case .player: duration == nil ? drawIdle() : drawPlaying()
        }
        drawCornerGlyphs()
        if showsArrows { drawArrows() }
    }

    /// Two small chevrons, one above the other, as iTunes 10 drew them.
    private func drawArrows() {
        let r = arrowsRect
        Theme.ink(0.40).setFill()
        let up = NSBezierPath()
        up.move(to: NSPoint(x: r.minX, y: r.midY + 1.5))
        up.line(to: NSPoint(x: r.midX, y: r.maxY))
        up.line(to: NSPoint(x: r.maxX, y: r.midY + 1.5))
        up.close()
        up.fill()
        let down = NSBezierPath()
        down.move(to: NSPoint(x: r.minX, y: r.midY - 1.5))
        down.line(to: NSPoint(x: r.midX, y: r.minY))
        down.line(to: NSPoint(x: r.maxX, y: r.midY - 1.5))
        down.close()
        down.fill()
    }

    /// The sync view: what is being written, how far along, and a bar.
    private func drawSync() {
        let w = bounds.width - 52 - (showsArrows ? 12 : 0)
        let titleH: CGFloat = 14, subtitleH: CGFloat = 13
        let titleY = bounds.maxY - 3 - titleH
        centred(syncTitle, NSRect(x: 26, y: titleY, width: w, height: titleH), size: 12, bold: true)
        centred(syncDetail, NSRect(x: 26, y: titleY - subtitleH, width: w, height: subtitleH), size: 11)

        let g = grooveRect
        let groove = NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2)
        if Theme.isModern {
            Theme.controlFillPressed.setFill()
            groove.fill()
        } else {
            NSGradient(starting: Theme.ink(0.72), ending: Theme.ink(0.86))!
                .draw(in: groove, angle: -90)
        }
        NSGraphicsContext.saveGraphicsState()
        groove.addClip()
        if let f = syncFraction {
            if f > 0.005 {
                let filled = NSRect(x: g.minX, y: g.minY, width: g.width * CGFloat(f), height: g.height)
                NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.88, alpha: 1),
                           ending: NSColor(srgbRed: 0.26, green: 0.46, blue: 0.80, alpha: 1))!
                    .draw(in: filled, angle: -90)
            }
        } else {
            // Barber pole: diagonal blue stripes sliding right.
            NSGradient(starting: NSColor(srgbRed: 0.55, green: 0.70, blue: 0.92, alpha: 1),
                       ending: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.88, alpha: 1))!
                .draw(in: g, angle: -90)
            NSColor(srgbRed: 0.26, green: 0.46, blue: 0.80, alpha: 1).setFill()
            var x = g.minX - 14 + polePhase
            while x < g.maxX + 14 {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: x, y: g.minY - 1))
                stripe.line(to: NSPoint(x: x + 6, y: g.minY - 1))
                stripe.line(to: NSPoint(x: x + 12, y: g.maxY + 1))
                stripe.line(to: NSPoint(x: x + 6, y: g.maxY + 1))
                stripe.close()
                stripe.fill()
                x += 14
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if !Theme.isModern {
            Theme.ink(0.56).setStroke()
            NSBezierPath(roundedRect: g.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        }
    }

    /// The small circled glyphs in the display's corners: play or pause at the
    /// left, the output picker at the right. Both are clickable.
    var isPlaying = false { didSet { needsDisplay = true } }
    var airPlayActive = false { didSet { needsDisplay = true } }

    private func drawCornerGlyphs() {
        let color = airPlayActive ? Aqua.accent : (Theme.isModern ? Theme.secondaryText : Theme.ink(0.45))
        let cy = bounds.midY
        func circle(_ cx: CGFloat, _ fill: NSColor) {
            let p = NSBezierPath(ovalIn: NSRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
            fill.setFill()
            p.fill()
        }
        // Left: play (triangle) or pause (bars), knocked out of a dark disc.
        let lx: CGFloat = 12
        circle(lx, Theme.ink(0.45))
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
            .foregroundColor: (Theme.isModern ? Theme.text : Theme.ink(0.25)).withAlphaComponent(alpha),
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
        let w = bounds.width - 52 - (showsArrows ? 12 : 0)

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
            .font: Aqua.font(9), .foregroundColor: Theme.ink(0.35), .paragraphStyle: timeStyle,
        ]
        let timeY = g.midY - 6
        (Aqua.clock(pos) as NSString).draw(
            in: NSRect(x: 21, y: timeY, width: sideInset - 25, height: 12), withAttributes: timeAttrs)
        (("-" + Aqua.clock(max(0, total - pos))) as NSString).draw(
            in: NSRect(x: g.maxX + 4, y: timeY, width: sideInset - 25, height: 12), withAttributes: timeAttrs)

        // Groove, recessed.
        let groove = NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2)
        if Theme.isModern {
            Theme.controlFillPressed.setFill()
            groove.fill()
        } else {
            NSGradient(starting: Theme.ink(0.72), ending: Theme.ink(0.86))!
                .draw(in: groove, angle: -90)
            Theme.ink(0.56).setStroke()
            NSBezierPath(roundedRect: g.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
        }

        guard total > 0 else { return }
        let f = CGFloat(pos / total)

        // Filled portion.
        if f > 0.01 {
            let filled = NSRect(x: g.minX, y: g.minY, width: g.width * f, height: g.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: g, xRadius: 2, yRadius: 2).addClip()
            if Theme.isModern {
                Theme.accent.setFill()
                filled.fill()
            } else {
                NSGradient(starting: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.88, alpha: 1),
                           ending: NSColor(srgbRed: 0.26, green: 0.46, blue: 0.80, alpha: 1))!
                    .draw(in: filled, angle: -90)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Knob.
        let d: CGFloat = isScrubbing ? 12 : 10
        let c = NSPoint(x: g.minX + g.width * f, y: g.midY)
        let kr = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        let knob = NSBezierPath(ovalIn: kr.insetBy(dx: 0.5, dy: 0.5))
        if Theme.isModern {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
            sh.shadowBlurRadius = 2
            sh.shadowOffset = NSSize(width: 0, height: -0.5)
            sh.set()
            Theme.raised.setFill()
            knob.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.hairline.setStroke()
            knob.stroke()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 1.5
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()
        Theme.ink(0.85).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: Theme.ink(0.99), ending: Theme.ink(0.80))!
            .draw(in: knob, angle: -90)
        Theme.ink(0.40).setStroke()
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
        let color: NSColor = !isEnabled ? Theme.ink(0.62)
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
            sh.shadowColor = NSColor.black.withAlphaComponent(Theme.isModern ? 0.22 : 0.35)
            sh.shadowBlurRadius = Theme.isModern ? 6 : 3
            sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.set()
            Theme.paper.setFill()
            let shape = Theme.isModern ? NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6) : NSBezierPath(rect: box)
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSGradient(starting: Theme.ink(0.97), ending: Theme.ink(0.88))!
                .draw(in: box, angle: -90)
            // A drawn disc, so no artwork ships with the app.
            let c = NSPoint(x: box.midX, y: box.midY)
            let r = side * 0.24
            Theme.ink(0.78).setStroke()
            for k in [1.0, 0.72, 0.44] as [CGFloat] {
                let p = NSBezierPath(ovalIn: NSRect(x: c.x - r * k, y: c.y - r * k, width: r * k * 2, height: r * k * 2))
                p.lineWidth = 1
                p.stroke()
            }
            Theme.ink(0.80).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
        }
        if !Theme.isModern {
            Theme.ink(0.55).setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }

        if !caption.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let emboss = NSShadow()
            emboss.shadowColor = NSColor.white.withAlphaComponent(Theme.isModern ? 0 : 0.9)
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

/// A top-left origin view. NSScrollView shows the bottom of an unflipped
/// document first, which left a gap above the content; a flipped document
/// view scrolls from the top the way every other list does.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
