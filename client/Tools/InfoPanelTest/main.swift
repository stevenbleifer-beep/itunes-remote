import Cocoa

// Renders the Get Info panel with sample data so its layout can be reviewed
// without driving the running app. --snapshot writes a PNG and exits.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .aqua)

func track(_ name: String, _ artist: String, _ album: String, _ genre: String,
           _ year: Int?, _ n: Int?) -> Track {
    Track(persistentId: "0000000000000001", name: name, artist: artist, album: album,
          albumArtist: artist, genre: genre, year: year, trackNumber: n, discNumber: 1,
          totalTime: 251000, size: 8_000_000, compilation: false)
}

let multi = CommandLine.arguments.contains("--multi")
let tracks: [Track] = multi
    ? [track("Everything in Its Right Place", "Radiohead", "Kid A", "Electronic", 2000, 1),
       track("Kid A", "Radiohead", "Kid A", "Electronic", 2000, 2),
       track("The National Anthem", "Radiohead", "Kid A", "Alternative", 2000, 3)]
    : [track("Everything in Its Right Place", "Radiohead", "Kid A", "Electronic", 2000, 1)]

MainActor.assumeIsolated {
let info = InfoPanel(tracks: tracks)
info.knownGenres = ["Electronic", "Electronica", "Alternative", "Rock"]
let content = info.panel.contentView!
content.layoutSubtreeIfNeeded()
content.displayIfNeeded()

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let b = content.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    content.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print("wrote \(CommandLine.arguments[i + 1])")
    exit(0)
}
info.panel.center()
info.panel.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
}
app.run()
