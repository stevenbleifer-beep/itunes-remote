import Cocoa

// Throwaway harness for milestone 2: one window, a few states of the gel
// button, and a 3x zoom of the default one. `--snapshot out.png` renders the
// window content at 2x and exits, so the look can be reviewed without a
// screen-recording permission.

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .aqua)

let args = CommandLine.arguments
var snapshotPath: String?
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    snapshotPath = args[i + 1]
}

final class ZoomView: NSView {
    let sample: AquaPushButton
    let scale: CGFloat
    init(sample: AquaPushButton, scale: CGFloat) {
        self.sample = sample
        self.scale = scale
        super.init(frame: .zero)
        let s = sample.intrinsicContentSize
        sample.frame = NSRect(origin: .zero, size: s)
        frame.size = NSSize(width: s.width * scale, height: s.height * scale)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        sample.draw(sample.bounds)
        ctx.restoreGState()
    }
}

final class Controller: NSObject {
    var clicks = 0
    let label = NSTextField(labelWithString: "")
    @objc func clicked(_ sender: AquaPushButton) {
        clicks += 1
        label.stringValue = "\(sender.title) clicked \(clicks)x"
    }
}
let controller = Controller()

let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))
content.wantsLayer = true
content.layer?.backgroundColor = NSColor(white: 0.925, alpha: 1).cgColor

func place(_ v: NSView, x: CGFloat, y: CGFloat) {
    let s = v.intrinsicContentSize
    v.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
    content.addSubview(v)
}
func caption(_ text: String, x: CGFloat, y: CGFloat) {
    let t = NSTextField(labelWithString: text)
    t.font = NSFont(name: "LucidaGrande", size: 11)
    t.textColor = NSColor(white: 0.35, alpha: 1)
    t.sizeToFit()
    t.frame.origin = NSPoint(x: x, y: y)
    content.addSubview(t)
}

let play = AquaPushButton(title: "Play", isDefault: true)
play.target = controller
play.action = #selector(Controller.clicked(_:))
let cancel = AquaPushButton(title: "Cancel")
cancel.target = controller
cancel.action = #selector(Controller.clicked(_:))
let pressed = AquaPushButton(title: "Pressed", isDefault: true)
pressed.pressedOverride = true
pressed.pulseOverride = 0
let disabled = AquaPushButton(title: "Disabled", isDefault: true)
disabled.isEnabled = false
let peak = AquaPushButton(title: "Pulse peak", isDefault: true)
peak.pulseOverride = 1

place(play, x: 20, y: 200)
place(cancel, x: 120, y: 200)
caption("default (pulsing) and plain", x: 24, y: 182)
place(pressed, x: 20, y: 140)
place(peak, x: 120, y: 140)
place(disabled, x: 240, y: 140)
caption("pressed, pulse peak, disabled", x: 24, y: 122)

let zoomSample = AquaPushButton(title: "Play", isDefault: true)
zoomSample.pulseOverride = 0
let zoom = ZoomView(sample: zoomSample, scale: 3)
zoom.frame.origin = NSPoint(x: 20, y: 24)
content.addSubview(zoom)
caption("3x", x: 24 + zoom.frame.width, y: 40)

controller.label.font = NSFont(name: "LucidaGrande", size: 11)
controller.label.frame = NSRect(x: 240, y: 200, width: 170, height: 20)
content.addSubview(controller.label)

let window = NSWindow(contentRect: content.frame,
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "Gel Button Test"
window.contentView = content
window.appearance = NSAppearance(named: .aqua)

if let path = snapshotPath {
    content.layoutSubtreeIfNeeded()
    let b = content.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    content.cacheDisplay(in: b, to: rep)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
    exit(0)
}

window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
