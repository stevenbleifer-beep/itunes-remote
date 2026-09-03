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

    // Silver ring.
    let ringR = 498 * s
    NSGradient(starting: NSColor(white: 1.00, alpha: 1), ending: NSColor(white: 0.66, alpha: 1))!
        .draw(in: circle(ringR), angle: -90)

    // Dark navy rim just inside it.
    let rimR = 468 * s
    NSGradient(starting: NSColor(srgbRed: 0.06, green: 0.13, blue: 0.26, alpha: 1),
               ending: NSColor(srgbRed: 0.01, green: 0.03, blue: 0.10, alpha: 1))!
        .draw(in: circle(rimR), angle: -90)

    // The face.
    let faceR = 452 * s
    let faceRect = NSRect(x: c.x - faceR, y: c.y - faceR, width: faceR * 2, height: faceR * 2)
    let face = circle(faceR)
    NSGraphicsContext.saveGraphicsState()
    face.addClip()

    // Steel blue at the top falling to a bright blue at the bottom.
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.24, green: 0.42, blue: 0.62, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.10, green: 0.36, blue: 0.72, alpha: 1), 0.42),
        (NSColor(srgbRed: 0.03, green: 0.44, blue: 0.94, alpha: 1), 0.72),
        (NSColor(srgbRed: 0.02, green: 0.34, blue: 0.82, alpha: 1), 1.0))!
        .draw(in: faceRect, angle: -90)

    // Cyan core behind the note, low and centred.
    let glow = NSPoint(x: c.x, y: c.y - faceR * 0.26)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.42, green: 0.84, blue: 1.00, alpha: 0.95), 0.0),
        (NSColor(srgbRed: 0.16, green: 0.66, blue: 1.00, alpha: 0.70), 0.32),
        (NSColor(srgbRed: 0.04, green: 0.44, blue: 0.96, alpha: 0.28), 0.62),
        (NSColor(srgbRed: 0.02, green: 0.28, blue: 0.78, alpha: 0.0), 1.0))!
        .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: faceR * 0.95, options: [])

    // Gloss over the top half, ending on a hard curved horizon.
    let horizon = NSBezierPath()
    horizon.move(to: NSPoint(x: c.x - faceR, y: c.y + faceR))
    horizon.line(to: NSPoint(x: c.x - faceR, y: c.y + faceR * 0.06))
    horizon.curve(to: NSPoint(x: c.x + faceR, y: c.y + faceR * 0.06),
                  controlPoint1: NSPoint(x: c.x - faceR * 0.35, y: c.y - faceR * 0.30),
                  controlPoint2: NSPoint(x: c.x + faceR * 0.35, y: c.y - faceR * 0.30))
    horizon.line(to: NSPoint(x: c.x + faceR, y: c.y + faceR))
    horizon.close()
    NSGraphicsContext.saveGraphicsState()
    horizon.addClip()
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.42), 0.0),
        (NSColor.white.withAlphaComponent(0.20), 0.55),
        (NSColor.white.withAlphaComponent(0.06), 1.0))!
        .draw(in: NSRect(x: c.x - faceR, y: c.y - faceR * 0.30, width: faceR * 2, height: faceR * 1.30), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // The note: two oval heads, two slim stems, one slanted beam.
    let note = NSBezierPath()
    let headRX = 88 * s, headRY = 72 * s
    let stemW = 48 * s
    let beamH = 88 * s
    let leftHead = NSPoint(x: c.x - 150 * s, y: c.y - 232 * s)
    let rightHead = NSPoint(x: c.x + 152 * s, y: c.y - 168 * s)
    for h in [leftHead, rightHead] {
        note.append(NSBezierPath(ovalIn: NSRect(x: h.x - headRX, y: h.y - headRY, width: headRX * 2, height: headRY * 2)))
    }
    let leftStemX = leftHead.x + headRX - stemW
    let rightStemX = rightHead.x + headRX - stemW
    let beamTopL = c.y + 262 * s, beamTopR = c.y + 330 * s
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
    noteShadow.shadowColor = NSColor(srgbRed: 0.01, green: 0.06, blue: 0.24, alpha: 0.5)
    noteShadow.shadowBlurRadius = 24 * s
    noteShadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    noteShadow.set()
    NSColor.black.setFill()
    note.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.30, green: 0.32, blue: 0.35, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1), 0.5),
        (NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1), 1.0))!
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
