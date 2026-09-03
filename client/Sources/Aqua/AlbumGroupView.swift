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
        detail.textColor = NSColor(white: 0.45, alpha: 1)
        for (label, y) in [(title, 42.0), (artist, 26.0), (detail, 11.0)] as [(NSTextField, CGFloat)] {
            label.frame = NSRect(x: 70, y: y, width: 600, height: 16)
            label.lineBreakMode = .byTruncatingTail
            label.autoresizingMask = [.width]
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.84, alpha: 1).setFill()
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
