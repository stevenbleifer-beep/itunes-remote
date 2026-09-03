import Cocoa

// Snapshots AquaDisplayPanel at the size the main window uses, so its spacing
// can be checked without playing anything. Usage: DisplayTest out.png
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "display.png"
let W: CGFloat = 380, H: CGFloat = 44, gap: CGFloat = 12

func panel(_ configure: (AquaDisplayPanel) -> Void) -> AquaDisplayPanel {
    let p = AquaDisplayPanel(frame: NSRect(x: 0, y: 0, width: W, height: H))
    configure(p)
    return p
}

let panels = [
    panel { p in
        p.primary = "Back In Black"
        p.secondary = "AC/DC — Back In Black"
        p.duration = 255
        p.position = 95
        p.isPlaying = true
    },
    panel { p in
        p.primary = "Everytime"
        p.secondary = "Boy Pablo — Roy Pablo"
        p.duration = 169
        p.position = 12
        p.isPlaying = true
        p.airPlayActive = true
    },
    panel { p in
        p.primary = "Music"
        p.secondary = "95,521 songs in iTunes 12.9.5"
    },
]

let total = NSRect(x: 0, y: 0, width: W + 24, height: (H + gap) * CGFloat(panels.count) + gap)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total.width * 2), pixelsHigh: Int(total.height * 2),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = total.size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.85, alpha: 1).setFill()
total.fill()
for (i, p) in panels.enumerated() {
    let y = total.height - gap - (H + gap) * CGFloat(i) - H
    NSGraphicsContext.current!.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 12, yBy: y)
    t.concat()
    p.draw(p.bounds)
    NSGraphicsContext.current!.restoreGraphicsState()
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
