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
    // Outside the rounded square stays transparent.

    let inset = 40 * s
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.255
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Face: deep blue overall, violet in the top-left corner, a bright cyan
    // glow behind the note, and a glossy upper half.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor(srgbRed: 0.07, green: 0.42, blue: 0.93, alpha: 1).setFill()
    body.fill()

    // A bright cyan core behind the note: the dominant feature of the face.
    let glow = NSPoint(x: c.x, y: c.y - body.height * 0.02)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.58, green: 0.90, blue: 1.00, alpha: 1.0), 0.0),
        (NSColor(srgbRed: 0.32, green: 0.76, blue: 1.00, alpha: 0.92), 0.24),
        (NSColor(srgbRed: 0.13, green: 0.55, blue: 1.00, alpha: 0.65), 0.48),
        (NSColor(srgbRed: 0.05, green: 0.32, blue: 0.90, alpha: 0.20), 0.74),
        (NSColor(srgbRed: 0.03, green: 0.20, blue: 0.70, alpha: 0.0), 1.0))!
        .draw(fromCenter: glow, radius: 0, toCenter: glow, radius: body.width * 0.56, options: [])

    // Violet, only in the top-left corner.
    let violet = NSPoint(x: body.minX + body.width * 0.06, y: body.maxY - body.height * 0.04)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.48, green: 0.28, blue: 0.86, alpha: 0.95), 0.0),
        (NSColor(srgbRed: 0.34, green: 0.30, blue: 0.88, alpha: 0.45), 0.42),
        (NSColor(srgbRed: 0.10, green: 0.36, blue: 0.92, alpha: 0.0), 1.0))!
        .draw(fromCenter: violet, radius: 0, toCenter: violet, radius: body.width * 0.46, options: [])

    // Darker corners so the face reads as domed.
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.02, green: 0.16, blue: 0.55, alpha: 0.0), 0.62),
        (NSColor(srgbRed: 0.02, green: 0.12, blue: 0.46, alpha: 0.45), 1.0))!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: body.width * 0.82, options: [])

    // Gloss: the top half, curving down to a soft horizon.
    let horizon = NSBezierPath()
    horizon.move(to: NSPoint(x: body.minX, y: body.maxY))
    horizon.line(to: NSPoint(x: body.minX, y: body.midY + body.height * 0.10))
    horizon.curve(to: NSPoint(x: body.maxX, y: body.midY + body.height * 0.10),
                  controlPoint1: NSPoint(x: body.minX + body.width * 0.30, y: body.midY - body.height * 0.10),
                  controlPoint2: NSPoint(x: body.maxX - body.width * 0.30, y: body.midY - body.height * 0.10))
    horizon.line(to: NSPoint(x: body.maxX, y: body.maxY))
    horizon.close()
    NSGraphicsContext.saveGraphicsState()
    horizon.addClip()
    NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.44), 0.0),
        (NSColor.white.withAlphaComponent(0.16), 0.55),
        (NSColor.white.withAlphaComponent(0.03), 1.0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // The note: two oval heads, two slim stems, one slanted beam. Measured
    // off the reference: the beam is about 8% of the body's height and the
    // stems about 4.5% of its width, which is far slimmer than it first looks.
    let note = NSBezierPath()
    let headRX = 76 * s, headRY = 63 * s
    let stemW = 43 * s
    let beamH = 78 * s
    let leftHead = NSPoint(x: c.x - 128 * s, y: c.y - 236 * s)
    let rightHead = NSPoint(x: c.x + 130 * s, y: c.y - 178 * s)
    for h in [leftHead, rightHead] {
        note.append(NSBezierPath(ovalIn: NSRect(x: h.x - headRX, y: h.y - headRY, width: headRX * 2, height: headRY * 2)))
    }
    let leftStemX = leftHead.x + headRX - stemW
    let rightStemX = rightHead.x + headRX - stemW
    let beamTopL = c.y + 232 * s, beamTopR = c.y + 292 * s
    note.append(NSBezierPath(rect: NSRect(x: leftStemX, y: leftHead.y, width: stemW, height: beamTopL - leftHead.y)))
    note.append(NSBezierPath(rect: NSRect(x: rightStemX, y: rightHead.y, width: stemW, height: beamTopR - rightHead.y)))
    let beam = NSBezierPath()
    beam.move(to: NSPoint(x: leftStemX, y: beamTopL))
    beam.line(to: NSPoint(x: rightStemX + stemW, y: beamTopR))
    beam.line(to: NSPoint(x: rightStemX + stemW, y: beamTopR - beamH))
    beam.line(to: NSPoint(x: leftStemX, y: beamTopL - beamH))
    beam.close()
    beam.lineJoinStyle = .miter
    note.append(beam)
    note.windingRule = .nonZero

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // A soft shadow under the note lifts it off the glass.
    let noteShadow = NSShadow()
    noteShadow.shadowColor = NSColor(srgbRed: 0.01, green: 0.08, blue: 0.30, alpha: 0.55)
    noteShadow.shadowBlurRadius = 26 * s
    noteShadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    noteShadow.set()
    NSColor.black.setFill()
    note.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Near-black, a touch lighter at the top as the reference has it.
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1), 0.5),
        (NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1), 1.0))!
        .draw(in: note, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Border: a dark navy edge with a fine light line just inside it.
    NSColor(srgbRed: 0.03, green: 0.09, blue: 0.30, alpha: 1).setStroke()
    shape.lineWidth = max(1, 14 * s)
    shape.stroke()
    let innerEdge = NSBezierPath(roundedRect: body.insetBy(dx: 11 * s, dy: 11 * s),
                                 xRadius: radius - 10 * s, yRadius: radius - 10 * s)
    NSColor.white.withAlphaComponent(0.22).setStroke()
    innerEdge.lineWidth = max(1, 5 * s)
    innerEdge.stroke()

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
