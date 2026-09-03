import Cocoa

// Draws the app icon in the manner of iTunes 10's: a gray bezel ring, a
// glossy blue disc, and a white double eighth-note. Original drawing, no
// Apple artwork. Usage: MakeIcon <outdir>  -> writes the iconset PNGs.

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    let c = NSPoint(x: size / 2, y: size / 2)

    // Bezel ring with a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
    sh.shadowBlurRadius = 18 * s
    sh.shadowOffset = NSSize(width: 0, height: -10 * s)
    sh.set()
    let ringR = 470 * s
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
    NSColor(white: 0.85, alpha: 1).setFill()
    ring.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.70, alpha: 1))!.draw(in: ring, angle: -90)
    NSColor(white: 0.45, alpha: 1).setStroke()
    ring.lineWidth = max(1, 3 * s)
    ring.stroke()

    // Blue disc.
    let discR = 418 * s
    let discRect = NSRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2)
    let disc = NSBezierPath(ovalIn: discRect)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.42, green: 0.70, blue: 0.98, alpha: 1), 0),
        (NSColor(srgbRed: 0.16, green: 0.45, blue: 0.90, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.08, green: 0.30, blue: 0.72, alpha: 1), 1))!.draw(in: disc, angle: -90)
    // Radial glow from the upper centre.
    NSGraphicsContext.saveGraphicsState()
    disc.addClip()
    let glowC = NSPoint(x: c.x, y: c.y + discR * 0.45)
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.55), 0),
        (NSColor.white.withAlphaComponent(0.0), 1))!
        .draw(fromCenter: glowC, radius: 0, toCenter: glowC, radius: discR * 1.1, options: [])
    // Gloss cap.
    let cap = NSBezierPath(ovalIn: NSRect(x: c.x - discR * 0.92, y: c.y - discR * 0.05, width: discR * 1.84, height: discR * 1.1))
    NSGradient(starting: NSColor.white.withAlphaComponent(0.42), ending: NSColor.white.withAlphaComponent(0.02))!.draw(in: cap, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.05, green: 0.20, blue: 0.50, alpha: 1).setStroke()
    disc.lineWidth = max(1, 4 * s)
    disc.stroke()

    // Double eighth-note, white, with a faint drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let nsh = NSShadow()
    nsh.shadowColor = NSColor.black.withAlphaComponent(0.30)
    nsh.shadowBlurRadius = 10 * s
    nsh.shadowOffset = NSSize(width: 0, height: -6 * s)
    nsh.set()
    NSColor.white.setFill()
    let note = NSBezierPath()
    let headW = 150 * s, headH = 108 * s, stemW = 34 * s
    let leftX = c.x - 150 * s, rightX = c.x + 90 * s
    let baseY = c.y - 170 * s
    // heads (tilted ovals)
    for x in [leftX, rightX] {
        var t = AffineTransform(translationByX: x + headW / 2, byY: baseY + headH / 2)
        t.rotate(byDegrees: -22)
        let head = NSBezierPath(ovalIn: NSRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH))
        head.transform(using: t)
        note.append(head)
    }
    // stems
    note.appendRect(NSRect(x: leftX + headW - stemW, y: baseY + headH / 2, width: stemW, height: 330 * s))
    note.appendRect(NSRect(x: rightX + headW - stemW, y: baseY + headH / 2 + 60 * s, width: stemW, height: 300 * s))
    // beam, angled up to the right
    let beam = NSBezierPath()
    let bx0 = leftX + headW - stemW, bx1 = rightX + headW
    let by0 = baseY + headH / 2 + 330 * s, by1 = by0 + 60 * s
    beam.move(to: NSPoint(x: bx0, y: by0 - 95 * s))
    beam.line(to: NSPoint(x: bx1, y: by1 - 95 * s))
    beam.line(to: NSPoint(x: bx1, y: by1))
    beam.line(to: NSPoint(x: bx0, y: by0))
    beam.close()
    note.append(beam)
    note.windingRule = .nonZero
    note.fill()
    NSGraphicsContext.restoreGraphicsState()

    img.unlockFocus()
    return img
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    let image = draw(size: px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
}
print("wrote \(sizes.count) icons to \(outDir)")
