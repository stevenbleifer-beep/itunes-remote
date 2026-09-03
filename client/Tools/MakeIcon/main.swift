import Cocoa

// Draws the app icon in the manner of iTunes 10's: a gray bezel ring, a
// glossy blue disc, and a white double eighth-note. Original drawing, no
// Apple artwork. Usage: MakeIcon <outdir>  -> writes the iconset PNGs.

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = size / 1024
    let c = NSPoint(x: size / 2, y: size / 2)
    // Everything outside the disc stays transparent.

    func circle(_ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // Silver ring, lit from the top left.
    let ringR = 496 * s
    NSGradient(colorsAndLocations:
        (NSColor(white: 1.00, alpha: 1), 0.0),
        (NSColor(white: 0.96, alpha: 1), 0.40),
        (NSColor(white: 0.84, alpha: 1), 0.80),
        (NSColor(white: 0.93, alpha: 1), 1.0))!
        .draw(in: circle(ringR), angle: -75)

    // Dark navy rim just inside it, deepest at the top.
    let rimR = 462 * s
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.02, green: 0.09, blue: 0.20, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.02, green: 0.20, blue: 0.42, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.01, green: 0.36, blue: 0.66, alpha: 1), 1.0))!
        .draw(in: circle(rimR), angle: -90)

    // The face.
    let faceR = 448 * s
    let faceRect = NSRect(x: c.x - faceR, y: c.y - faceR, width: faceR * 2, height: faceR * 2)
    let face = circle(faceR)
    NSGraphicsContext.saveGraphicsState()
    face.addClip()

    // Deep navy at the top falling to a bright cyan blue at the bottom.
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.07, green: 0.18, blue: 0.32, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.22, green: 0.36, blue: 0.52, alpha: 1), 0.30),
        (NSColor(srgbRed: 0.20, green: 0.48, blue: 0.72, alpha: 1), 0.50),
        (NSColor(srgbRed: 0.02, green: 0.58, blue: 0.91, alpha: 1), 0.72),
        (NSColor(srgbRed: 0.00, green: 0.68, blue: 0.98, alpha: 1), 1.0))!
        .draw(in: faceRect, angle: -90)

    // Cyan core behind the note, low and centred.
    let glow = NSPoint(x: c.x, y: c.y - faceR * 0.34)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.55, green: 0.90, blue: 1.00, alpha: 0.95), 0.0),
        (NSColor(srgbRed: 0.20, green: 0.74, blue: 1.00, alpha: 0.72), 0.34),
        (NSColor(srgbRed: 0.02, green: 0.52, blue: 0.96, alpha: 0.26), 0.66),
        (NSColor(srgbRed: 0.02, green: 0.30, blue: 0.78, alpha: 0.0), 1.0))!
        .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: faceR * 0.92, options: [])

    // The gloss: a bright sheet over the top half, cut off along a hard
    // horizon that bulges downward in the middle. This edge is what makes the
    // disc read as glass rather than as a flat gradient.
    let horizon = NSBezierPath()
    horizon.move(to: NSPoint(x: c.x - faceR, y: c.y + faceR))
    horizon.line(to: NSPoint(x: c.x - faceR, y: c.y + faceR * 0.24))
    horizon.curve(to: NSPoint(x: c.x + faceR, y: c.y + faceR * 0.24),
                  controlPoint1: NSPoint(x: c.x - faceR * 0.34, y: c.y - faceR * 0.30),
                  controlPoint2: NSPoint(x: c.x + faceR * 0.34, y: c.y - faceR * 0.30))
    horizon.line(to: NSPoint(x: c.x + faceR, y: c.y + faceR))
    horizon.close()
    NSGraphicsContext.saveGraphicsState()
    horizon.addClip()
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.50), 0.0),
        (NSColor.white.withAlphaComponent(0.26), 0.50),
        (NSColor.white.withAlphaComponent(0.10), 0.86),
        (NSColor.white.withAlphaComponent(0.16), 1.0))!
        .draw(in: NSRect(x: c.x - faceR, y: c.y - faceR * 0.34, width: faceR * 2, height: faceR * 1.34), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // The note: two oval heads, two stems, one broad beam. Centred on the
    // disc and sized so the beam clears the gloss horizon.
    let note = NSBezierPath()
    let headRX = 92 * s, headRY = 74 * s
    let stemW = 52 * s
    let beamH = 138 * s
    let leftHead = NSPoint(x: c.x - 180 * s, y: c.y - 192 * s)
    let rightHead = NSPoint(x: c.x + 142 * s, y: c.y - 124 * s)
    for h in [leftHead, rightHead] {
        note.append(NSBezierPath(ovalIn: NSRect(x: h.x - headRX, y: h.y - headRY, width: headRX * 2, height: headRY * 2)))
    }
    let leftStemX = leftHead.x + headRX - stemW
    let rightStemX = rightHead.x + headRX - stemW
    let beamTopL = c.y + 274 * s, beamTopR = c.y + 262 * s
    note.append(NSBezierPath(rect: NSRect(x: leftStemX, y: leftHead.y, width: stemW, height: beamTopL - leftHead.y)))
    note.append(NSBezierPath(rect: NSRect(x: rightStemX, y: rightHead.y, width: stemW, height: beamTopR - rightHead.y)))
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: leftStemX, y: beamTopL))
    beam.line(to: NSPoint(x: rightStemX + stemW, y: beamTopR))
    beam.line(to: NSPoint(x: rightStemX + stemW, y: beamTopR - beamH))
    beam.line(to: NSPoint(x: leftStemX, y: beamTopL - beamH))
    beam.close()
    note.append(beam)
    note.windingRule = .nonZero

    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    let noteShadow = NSShadow()
    noteShadow.shadowColor = NSColor(srgbRed: 0.01, green: 0.06, blue: 0.24, alpha: 0.45)
    noteShadow.shadowBlurRadius = 26 * s
    noteShadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    NSGraphicsContext.saveGraphicsState()
    noteShadow.set()
    NSColor.black.setFill()
    note.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Charcoal, not black: the reference note is lit from above.
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.32, green: 0.33, blue: 0.35, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1), 0.42),
        (NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1), 1.0))!
        .draw(in: note, angle: -90)
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
