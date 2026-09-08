import Cocoa

/// The album header row of the Album List view: cover at the left, then the
/// album title, artist, and year with the track count.
@MainActor
final class AlbumGroupView: NSView {
    private let art = ArtworkView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var token = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        art.caption = ""
        art.fillsBounds = true
        art.frame = NSRect(x: 6, y: 4, width: 58, height: 58)
        art.autoresizingMask = [.maxXMargin]
        addSubview(art)
        title.font = Aqua.font(12, bold: true)
        artist.font = Aqua.font(11)
        detail.font = Aqua.font(10)
        detail.textColor = Theme.ink(0.45)
        for (label, y) in [(title, 42.0), (artist, 26.0), (detail, 11.0)] as [(NSTextField, CGFloat)] {
            label.frame = NSRect(x: 70, y: y, width: 600, height: 16)
            label.lineBreakMode = .byTruncatingTail
            label.autoresizingMask = [.width]
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        Theme.ink(0.84).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    func configure(_ album: AlbumEntry, cache: ArtworkCache) {
        title.stringValue = album.title
        artist.stringValue = album.artistName
        var bits: [String] = []
        if let y = album.year { bits.append(String(y)) }
        if album.trackCount > 0 { bits.append("\(album.trackCount) song\(album.trackCount == 1 ? "" : "s")") }
        detail.stringValue = bits.joined(separator: " · ")
        token += 1
        let mine = token
        art.image = nil
        guard let pid = album.coverTrackId else { return }
        if let hit = cache.cached(pid) { art.image = hit; return }
        cache.image(for: pid) { [weak self] image in
            guard let self = self, mine == self.token else { return }
            self.art.image = image
        }
    }
}


/// iTunes 10's "Album by Artist" column: the cover, the album in bold, the
/// artist and the rating dots, sitting beside the album's songs and as
/// tall as they are. One of these is laid over the table for every album
/// block on screen; clicks fall through to the rows beneath.
@MainActor
final class AlbumColumnView: NSView {
    private var image: NSImage?
    private var albumTitle = ""
    private var artistName = ""
    private var token = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ album: AlbumEntry, cache: ArtworkCache) {
        albumTitle = album.title
        artistName = album.artistName
        token += 1
        let mine = token
        image = nil
        needsDisplay = true
        guard let pid = album.coverTrackId else { return }
        if let hit = cache.cached(pid) { image = hit; needsDisplay = true; return }
        cache.image(for: pid) { [weak self] img in
            guard let self = self, mine == self.token else { return }
            self.image = img
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        // The rule under the album, and the column's right edge.
        Theme.ink(0.84).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()

        let pad: CGFloat = 8
        let textW = bounds.width - 2 * pad - 2
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        // One or two songs: the album's name alone, on the row, as iTunes did.
        if bounds.height < 40 {
            (albumTitle as NSString).draw(in: NSRect(x: pad, y: bounds.midY - 8, width: textW, height: 15), withAttributes: [
                .font: Aqua.font(11, bold: true), .foregroundColor: Theme.ink(0.15), .paragraphStyle: style])
            return
        }
        var y = bounds.maxY - (bounds.height < 60 ? 3 : pad)
        // Room for the cover only when the album is tall enough for it,
        // as iTunes did: short albums get their names alone.
        let side = min(bounds.width - 2 * pad - 2, 112)
        if bounds.height >= side + 52 {
            let box = NSRect(x: pad, y: y - side, width: side, height: side)
            if let img = image {
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
                sh.shadowBlurRadius = 3
                sh.shadowOffset = NSSize(width: 0, height: -1)
                sh.set()
                Theme.paper.setFill()
                NSBezierPath(rect: box).fill()
                NSGraphicsContext.restoreGraphicsState()
                img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                NSGradient(starting: Theme.ink(0.97), ending: Theme.ink(0.88))!.draw(in: box, angle: -90)
            }
            Theme.ink(0.55).setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
            y = box.minY - 6
        }
        if y - 16 > 2 {
            (albumTitle as NSString).draw(in: NSRect(x: pad, y: y - 15, width: textW, height: 15), withAttributes: [
                .font: Aqua.font(11, bold: true), .foregroundColor: Theme.ink(0.15), .paragraphStyle: style])
            y -= 16
        }
        if y - 15 > 2 {
            (artistName as NSString).draw(in: NSRect(x: pad, y: y - 14, width: textW, height: 14), withAttributes: [
                .font: Aqua.font(11), .foregroundColor: Theme.ink(0.30), .paragraphStyle: style])
            y -= 16
        }
        if y - 10 > 2 {
            // The rating, unset: five grey dots, as the Rating column shows them.
            Theme.ink(0.72).setFill()
            for i in 0..<5 {
                NSBezierPath(ovalIn: NSRect(x: pad + 1 + CGFloat(i) * 9, y: y - 9, width: 4, height: 4)).fill()
            }
        }
    }
}
