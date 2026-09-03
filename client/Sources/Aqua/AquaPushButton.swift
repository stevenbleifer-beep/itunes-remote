import Cocoa

/// The colours that make up one gel button variant. Every colour here is
/// drawn, never loaded; see SPEC.md section 5A.
struct AquaGelPalette {
    var top: NSColor        // just under the gloss at the very top
    var middle: NSColor     // the body colour at the gloss edge
    var bottom: NSColor     // the deep colour before the bounce light
    var bounce: NSColor     // light reflected back up from the bottom edge
    var strokeTop: NSColor
    var strokeBottom: NSColor
    var text: NSColor

    static let blue = AquaGelPalette(
        top: NSColor(srgbRed: 0.66, green: 0.80, blue: 0.97, alpha: 1),
        middle: NSColor(srgbRed: 0.24, green: 0.50, blue: 0.88, alpha: 1),
        bottom: NSColor(srgbRed: 0.16, green: 0.40, blue: 0.82, alpha: 1),
        bounce: NSColor(srgbRed: 0.56, green: 0.78, blue: 1.00, alpha: 1),
        strokeTop: NSColor(srgbRed: 0.28, green: 0.45, blue: 0.72, alpha: 1),
        strokeBottom: NSColor(srgbRed: 0.12, green: 0.30, blue: 0.62, alpha: 1),
        text: .black
    )

    static let white = AquaGelPalette(
        top: NSColor(white: 1.00, alpha: 1),
        middle: NSColor(white: 0.90, alpha: 1),
        bottom: NSColor(white: 0.84, alpha: 1),
        bounce: NSColor(white: 1.00, alpha: 1),
        strokeTop: NSColor(white: 0.58, alpha: 1),
        strokeBottom: NSColor(white: 0.46, alpha: 1),
        text: .black
    )

    /// The lighter palette the default button pulses toward.
    func lightened(by amount: CGFloat) -> AquaGelPalette {
        func mix(_ c: NSColor) -> NSColor {
            let s = c.usingColorSpace(.sRGB)!
            let k = amount * 0.45
            return NSColor(srgbRed: s.redComponent + (1 - s.redComponent) * k,
                           green: s.greenComponent + (1 - s.greenComponent) * k,
                           blue: s.blueComponent + (1 - s.blueComponent) * k,
                           alpha: 1)
        }
        var p = self
        p.top = mix(top)
        p.middle = mix(middle)
        p.bottom = mix(bottom)
        return p
    }
}

/// A Tiger-era Aqua push button: capsule body, top-half gloss, bottom bounce
/// light, gradient stroke, soft drop shadow, black Lucida Grande label. The
/// default variant is blue and pulses.
final class AquaPushButton: NSView {

    // MARK: Public state

    var title: String { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var isDefault: Bool { didSet { updatePulse(); needsDisplay = true } }
    var isEnabled = true { didSet { updatePulse(); needsDisplay = true } }
    var pulses = true { didSet { updatePulse() } }
    weak var target: AnyObject?
    var action: Selector?

    /// Test hooks. `pressedOverride` forces the pressed look; `pulseOverride`
    /// freezes the pulse at 0 (deep blue) to 1 (lightest).
    var pressedOverride: Bool?
    var pulseOverride: CGFloat? { didSet { needsDisplay = true } }

    static let font = NSFont(name: "LucidaGrande", size: 13) ?? NSFont.systemFont(ofSize: 13)
    static let bodyHeight: CGFloat = 20
    static let margin: CGFloat = 4   // room for shadow and glow on every side

    // MARK: Init

    init(title: String, isDefault: Bool = false) {
        self.title = title
        self.isDefault = isDefault
        super.init(frame: .zero)
        updatePulse()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let w = ceil(titleSize.width) + 2 * AquaPushButton.bodyHeight
        return NSSize(width: max(w, 68) + 2 * AquaPushButton.margin,
                      height: AquaPushButton.bodyHeight + 2 * AquaPushButton.margin)
    }

    // MARK: Pulse

    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0

    private func updatePulse() {
        let shouldPulse = isDefault && isEnabled && pulses && pulseOverride == nil
        if shouldPulse, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.pulsePhase += (2 * .pi) / (30 * 1.1)   // one cycle per 1.1 s
                self.needsDisplay = true
            }
        } else if !shouldPulse {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    private var pulseAmount: CGFloat {
        if let o = pulseOverride { return o }
        guard isDefault, isEnabled, pulses else { return 0 }
        return (1 + sin(pulsePhase)) / 2
    }

    // MARK: Mouse

    private var isPressed = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
        var inside = true
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let p = convert(e.locationInWindow, from: nil)
            let nowInside = bounds.contains(p)
            if nowInside != inside {
                inside = nowInside
                isPressed = inside
                needsDisplay = true
            }
            if e.type == .leftMouseUp { break }
        }
        isPressed = false
        needsDisplay = true
        if inside, let a = action {
            NSApp.sendAction(a, to: target, from: self)
        }
    }

    // MARK: Drawing

    private var titleSize: NSSize {
        (title as NSString).size(withAttributes: [.font: AquaPushButton.font])
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = AquaPushButton.margin
        let body = NSRect(x: m, y: m, width: bounds.width - 2 * m, height: AquaPushButton.bodyHeight)
            .insetBy(dx: 0.5, dy: 0.5)   // pixel-aligned 1px stroke
        let radius = body.height / 2
        let capsule = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        let pressed = pressedOverride ?? isPressed
        let pulse = pulseAmount
        let base: AquaGelPalette = isDefault ? .blue : .white
        let palette = pulse > 0 ? base.lightened(by: pulse) : base

        // Outer glow: the pulsing default button breathes a faint halo.
        if isDefault && isEnabled {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor(srgbRed: 0.35, green: 0.60, blue: 1.0, alpha: 0.25 + 0.35 * pulse)
            glow.shadowBlurRadius = 3 + 2 * pulse
            glow.shadowOffset = .zero
            glow.set()
            palette.bottom.setFill()
            capsule.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Drop shadow: light source is top centre, so a short soft shadow below.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isEnabled ? 0.30 : 0.15)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        palette.bottom.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Body: vertical gradient, top light, deep at the bottom.
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        NSGradient(colorsAndLocations: (palette.top, 0.0), (palette.middle, 0.50), (palette.bottom, 1.0))!
            .draw(in: body, angle: -90)

        // Bottom bounce: a soft radial light reflected up from the lower edge.
        let bounceCenter = NSPoint(x: body.midX, y: body.minY)
        NSGradient(colorsAndLocations:
            (palette.bounce.withAlphaComponent(0.85), 0.0),
            (palette.bounce.withAlphaComponent(0.35), 0.45),
            (palette.bounce.withAlphaComponent(0.0), 1.0))!
            .draw(fromCenter: bounceCenter, radius: 0,
                  toCenter: bounceCenter, radius: body.height * 0.75,
                  options: [])

        // Gloss: the upper half is a bright, crisp-edged highlight.
        let glossRect = NSRect(x: body.minX + 1, y: body.midY,
                               width: body.width - 2, height: body.height / 2 - 1)
        let gloss = NSBezierPath(roundedRect: glossRect, xRadius: radius - 1, yRadius: radius - 1)
        NSGradient(colorsAndLocations:
            (NSColor.white.withAlphaComponent(0.95), 0.0),
            (NSColor.white.withAlphaComponent(0.55), 0.55),
            (NSColor.white.withAlphaComponent(0.18), 1.0))!
            .draw(in: gloss, angle: -90)

        if pressed {
            NSColor(srgbRed: 0.0, green: 0.05, blue: 0.25, alpha: 0.22).setFill()
            capsule.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Stroke: darker along the bottom, lighter at the top.
        NSGraphicsContext.saveGraphicsState()
        let strokePath = capsule.copy() as! NSBezierPath
        strokePath.lineWidth = 1
        let strokeRegion = NSBezierPath(roundedRect: body.insetBy(dx: -0.5, dy: -0.5),
                                        xRadius: radius + 0.5, yRadius: radius + 0.5)
        strokeRegion.append(NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                         xRadius: radius - 0.5, yRadius: radius - 0.5))
        strokeRegion.windingRule = .evenOdd
        strokeRegion.addClip()
        NSGradient(starting: palette.strokeTop, ending: palette.strokeBottom)!
            .draw(in: body.insetBy(dx: -1, dy: -1), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Inner top-edge highlight: one bright hairline just inside the stroke.
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        NSBezierPath(rect: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2)).addClip()
        let inner = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
        inner.lineWidth = 1
        NSColor.white.withAlphaComponent(0.55).setStroke()
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Label.
        let color = isEnabled ? palette.text : NSColor.black.withAlphaComponent(0.35)
        let attrs: [NSAttributedString.Key: Any] = [.font: AquaPushButton.font, .foregroundColor: color]
        let size = titleSize
        let origin = NSPoint(x: round(body.midX - size.width / 2),
                             y: round(body.midY - size.height / 2) + 1)
        (title as NSString).draw(at: origin, withAttributes: attrs)

        if !isEnabled {
            NSColor(white: 0.93, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: body.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1).fill()
        }
    }
}
