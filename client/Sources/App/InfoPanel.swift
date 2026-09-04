import Cocoa

/// The Get Info sheet, for one track or for a whole selection.
///
/// Only fields the user actually edits are sent. With several tracks selected,
/// a field whose tracks disagree shows "Mixed" and is left alone unless typed
/// into, which is how iTunes behaved and is the safe default for a bulk edit.
@MainActor
final class InfoPanel: NSObject, NSTextFieldDelegate {

    private struct Row {
        let apiName: String
        let label: String
        let width: CGFloat
        let numeric: Bool
    }

    private static let rows: [Row] = [
        Row(apiName: "name", label: "Name:", width: 320, numeric: false),
        Row(apiName: "artist", label: "Artist:", width: 320, numeric: false),
        Row(apiName: "albumArtist", label: "Album Artist:", width: 320, numeric: false),
        Row(apiName: "album", label: "Album:", width: 320, numeric: false),
        Row(apiName: "composer", label: "Composer:", width: 320, numeric: false),
        Row(apiName: "genre", label: "Genre:", width: 220, numeric: false),
        Row(apiName: "year", label: "Year:", width: 80, numeric: true),
        Row(apiName: "trackNumber", label: "Track Number:", width: 80, numeric: true),
        Row(apiName: "discNumber", label: "Disc Number:", width: 80, numeric: true),
    ]

    let panel: NSPanel
    private let tracks: [Track]
    /// The cover, with Choose… and Remove under it. What the listener does
    /// here travels in the payload as `artwork` (JPEG bytes) or
    /// `clearArtwork`, beside the field edits.
    private let well = ArtworkWell()
    private let chooseButton = AquaPushButton(title: "Choose…")
    private let removeButton = AquaPushButton(title: "Remove")
    private var artworkChange: ArtworkChange = .none
    private enum ArtworkChange { case none, set(NSImage), clear }
    /// Loads the current cover for the well, given a track id.
    var loadArtwork: (String, @escaping (NSImage?) -> Void) -> Void = { _, done in done(nil) }
    private var fields: [String: NSTextField] = [:]
    private var initial: [String: String] = [:]
    private var mixed: Set<String> = []
    private let compilation = NSButton(checkboxWithTitle: "Compilation", target: nil, action: nil)
    private var initialCompilation: NSControl.StateValue = .off
    private let statusLabel = NSTextField(labelWithString: "")
    private let okButton = AquaPushButton(title: "OK", isDefault: true)
    private let cancelButton = AquaPushButton(title: "Cancel")

    /// Called with the fields to write. The panel closes itself when the
    /// completion reports success.
    var onApply: ([String: Any], @escaping (String?) -> Void) -> Void = { _, done in done(nil) }
    /// Existing genres, for the genre field's autocomplete.
    var knownGenres: [String] = []
    /// Reads one track's lyrics; nil means they could not be read.
    var loadLyrics: (String, @escaping (String?) -> Void) -> Void = { _, done in done(nil) }

    // Info | Lyrics, for a single song. Lyrics are not in the library the
    // app holds, so they are fetched when the sheet opens and written back
    // as a field of their own if they changed.
    private let tabs = InfoTabStrip(titles: ["Info", "Lyrics"])
    private var infoViews: [NSView] = []
    private let lyricsScroll = NSScrollView()
    private let lyricsView = NSTextView()
    private var initialLyrics: String?
    private var lyricsLoaded = false

    init(tracks: [Track]) {
        self.tracks = tracks
        let rowHeight: CGFloat = 27
        let hasLyrics = tracks.count == 1
        let top: CGFloat = hasLyrics ? 76 : 46
        let height = top + CGFloat(InfoPanel.rows.count) * rowHeight + 34 + 52
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        content.gradientTop = NSColor(white: 0.93, alpha: 1)
        content.gradientBottom = NSColor(white: 0.88, alpha: 1)
        panel = NSPanel(contentRect: content.frame,
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content
        panel.title = tracks.count == 1 ? "Get Info" : "Multiple Item Information"
        super.init()

        // Heading
        let heading = NSTextField(labelWithString: headingText)
        heading.font = Aqua.font(13, bold: true)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 20, y: height - 34, width: 600, height: 18)
        content.addSubview(heading)

        if hasLyrics {
            let ts = tabs.intrinsicContentSize
            tabs.frame = NSRect(x: (640 - ts.width) / 2, y: height - 66, width: ts.width, height: ts.height)
            tabs.onChange = { [weak self] i in self?.showTab(i) }
            content.addSubview(tabs)

            lyricsView.font = Aqua.font(12)
            lyricsView.isRichText = false
            lyricsView.isAutomaticQuoteSubstitutionEnabled = false
            lyricsView.isAutomaticDashSubstitutionEnabled = false
            lyricsView.textContainerInset = NSSize(width: 6, height: 6)
            lyricsView.isVerticallyResizable = true
            lyricsView.autoresizingMask = [.width]
            lyricsView.textContainer?.widthTracksTextView = true
            lyricsView.isEditable = false
            lyricsView.string = "Reading lyrics…"
            lyricsScroll.documentView = lyricsView
            lyricsScroll.hasVerticalScroller = true
            lyricsScroll.scrollerStyle = .legacy
            lyricsScroll.verticalScroller = AquaScroller()
            lyricsScroll.borderType = .bezelBorder
            lyricsScroll.frame = NSRect(x: 20, y: 52, width: 600, height: height - top - 52 + 10)
            lyricsScroll.isHidden = true
            content.addSubview(lyricsScroll)
        }

        // The cover, at the right, the way iTunes' Info window put it.
        well.frame = NSRect(x: 640 - 20 - 120, y: height - top - 120 + 4, width: 120, height: 120)
        well.onImage = { [weak self] image in self?.pickedArtwork(image) }
        content.addSubview(well)
        infoViews.append(well)
        chooseButton.target = self
        chooseButton.action = #selector(chooseArtwork)
        removeButton.target = self
        removeButton.action = #selector(removeArtwork)
        // Stacked under the well: side by side they ran past the edge.
        let cs = chooseButton.intrinsicContentSize, rs = removeButton.intrinsicContentSize
        let bw = max(cs.width, rs.width, 100)
        chooseButton.frame = NSRect(x: well.frame.midX - bw / 2, y: well.frame.minY - 30, width: bw, height: cs.height)
        removeButton.frame = NSRect(x: well.frame.midX - bw / 2, y: well.frame.minY - 58, width: bw, height: rs.height)
        content.addSubview(chooseButton)
        content.addSubview(removeButton)
        infoViews += [chooseButton, removeButton]
        removeButton.isEnabled = false

        var y = height - top - rowHeight
        for row in InfoPanel.rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = Aqua.font(12)
            label.alignment = .right
            label.frame = NSRect(x: 12, y: y + 3, width: 120, height: 18)
            content.addSubview(label)
            infoViews.append(label)

            let field = NSTextField(string: "")
            field.font = Aqua.font(12)
            field.bezelStyle = .squareBezel
            field.frame = NSRect(x: 142, y: y, width: row.width, height: 22)
            field.delegate = self
            if row.numeric {
                let f = NumberFormatter()
                f.numberStyle = .none
                f.allowsFloats = false
                field.formatter = f
            }
            content.addSubview(field)
            infoViews.append(field)
            fields[row.apiName] = field

            let (common, isMixed) = InfoPanel.commonValue(row.apiName, tracks)
            if isMixed {
                mixed.insert(row.apiName)
                field.placeholderString = "Mixed"
                initial[row.apiName] = ""
            } else {
                field.stringValue = common
                initial[row.apiName] = common
            }
            y -= rowHeight
        }

        // Compilation
        compilation.font = Aqua.font(12)
        compilation.frame = NSRect(x: 142, y: y + 2, width: 200, height: 20)
        compilation.allowsMixedState = tracks.count > 1
        let comps = Set(tracks.map { $0.compilation })
        if comps.count > 1 {
            compilation.state = .mixed
        } else {
            compilation.state = (comps.first ?? false) ? .on : .off
        }
        initialCompilation = compilation.state
        content.addSubview(compilation)
        infoViews.append(compilation)

        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.frame = NSRect(x: 20, y: 20, width: 300, height: 16)
        content.addSubview(statusLabel)

        okButton.target = self
        okButton.action = #selector(apply)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let ok = okButton.intrinsicContentSize
        okButton.frame = NSRect(x: 640 - 16 - ok.width, y: 14, width: ok.width, height: ok.height)
        let cc = cancelButton.intrinsicContentSize
        cancelButton.frame = NSRect(x: okButton.frame.minX - cc.width - 2, y: 14, width: cc.width, height: cc.height)
        content.addSubview(okButton)
        content.addSubview(cancelButton)

        panel.initialFirstResponder = fields["name"]
    }

    /// Switches tabs from outside (the `--info-lyrics` test flag).
    func selectTab(_ i: Int) {
        guard tracks.count == 1 else { return }
        tabs.selectedIndex = i
        showTab(i)
    }

    private func showTab(_ i: Int) {
        let lyrics = i == 1
        for v in infoViews { v.isHidden = lyrics }
        lyricsScroll.isHidden = !lyrics
        if lyrics { panel.makeFirstResponder(lyricsView) }
    }

    /// Fetches the song's lyrics once the owner has wired `loadLyrics`.
    func loadCurrentLyrics() {
        guard tracks.count == 1, let first = tracks.first else { return }
        loadLyrics(first.persistentId) { [weak self] text in
            guard let self = self else { return }
            self.lyricsLoaded = true
            if let text = text {
                self.initialLyrics = text
                self.lyricsView.string = text
                self.lyricsView.isEditable = true
            } else {
                self.lyricsView.string = "The lyrics could not be read from iTunes."
                self.lyricsView.textColor = NSColor(white: 0.45, alpha: 1)
            }
        }
    }

    /// Asks for the first track's cover once the owner has wired `loadArtwork`.
    func loadCurrentArtwork() {
        guard let first = tracks.first else { return }
        loadArtwork(first.persistentId) { [weak self] image in
            guard let self = self, case .none = self.artworkChange else { return }
            self.well.image = image
            self.removeButton.isEnabled = image != nil
        }
    }

    @objc private func chooseArtwork() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .gif, .bmp]
        open.allowsMultipleSelection = false
        open.message = "Choose a picture for \(tracks.count == 1 ? "this song" : "these \(tracks.count) songs")"
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url, let image = NSImage(contentsOf: url) else { return }
            self?.pickedArtwork(image)
        }
    }

    private func pickedArtwork(_ image: NSImage) {
        artworkChange = .set(image)
        well.image = image
        removeButton.isEnabled = true
        statusLabel.stringValue = "New artwork chosen; OK writes it to iTunes."
    }

    @objc private func removeArtwork() {
        artworkChange = .clear
        well.image = nil
        removeButton.isEnabled = false
        statusLabel.stringValue = "Artwork will be removed when you click OK."
    }

    /// The picture as iTunes should store it: JPEG, no bigger than 1400 px
    /// on a side, which is more than any screen here shows and keeps a
    /// phone photo from becoming a 12 MB cover on every song of an album.
    static func coverData(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, 1400 / max(w, h))
        let size = NSSize(width: max(1, round(w * scale)), height: max(1, round(h * scale)))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    private var headingText: String {
        if tracks.count == 1 {
            let t = tracks[0]
            return t.name.isEmpty ? "Untitled" : t.name
        }
        let albums = Set(tracks.map { $0.album }).count
        let artists = Set(tracks.map { $0.displayArtist }).count
        var parts = ["\(tracks.count) tracks"]
        if artists == 1, let a = tracks.first?.displayArtist, !a.isEmpty { parts.append(a) }
        if albums == 1, let a = tracks.first?.album, !a.isEmpty { parts.append(a) }
        return parts.joined(separator: " — ")
    }

    private static func value(_ apiName: String, _ t: Track) -> String {
        switch apiName {
        case "name": return t.name
        case "artist": return t.artist
        case "albumArtist": return t.albumArtist
        case "album": return t.album
        case "composer": return ""            // not carried in the compact row
        case "genre": return t.genre
        case "year": return t.year.map(String.init) ?? ""
        case "trackNumber": return t.trackNumber.map(String.init) ?? ""
        case "discNumber": return t.discNumber.map(String.init) ?? ""
        default: return ""
        }
    }

    private static func commonValue(_ apiName: String, _ tracks: [Track]) -> (String, Bool) {
        let values = Set(tracks.map { value(apiName, $0) })
        if values.count == 1 { return (values.first ?? "", false) }
        return ("", true)
    }

    // MARK: Actions

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func apply() {
        var payload: [String: Any] = [:]
        for row in InfoPanel.rows {
            guard let field = fields[row.apiName] else { continue }
            let text = field.stringValue
            // An untouched Mixed field stays untouched.
            if mixed.contains(row.apiName) && text.isEmpty { continue }
            if text == (initial[row.apiName] ?? "") { continue }
            if row.numeric {
                payload[row.apiName] = Int(text) ?? 0
            } else {
                payload[row.apiName] = text
            }
        }
        if compilation.state != initialCompilation && compilation.state != .mixed {
            payload["compilation"] = compilation.state == .on
        }
        if let before = initialLyrics {
            let now = lyricsView.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if now != before { payload["lyrics"] = now }
        }
        switch artworkChange {
        case .set(let image):
            guard let data = InfoPanel.coverData(image) else {
                statusLabel.stringValue = "That picture could not be read."
                return
            }
            payload["artwork"] = data
        case .clear:
            payload["clearArtwork"] = true
        case .none:
            break
        }
        guard !payload.isEmpty else {
            cancel()
            return
        }
        setBusy(true, "Updating \(tracks.count) track\(tracks.count == 1 ? "" : "s")…")
        onApply(payload) { [weak self] error in
            guard let self = self else { return }
            self.setBusy(false, error ?? "")
            if error == nil {
                self.panel.sheetParent?.endSheet(self.panel, returnCode: .OK)
            }
        }
    }

    private func setBusy(_ busy: Bool, _ message: String) {
        okButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        for f in fields.values { f.isEnabled = !busy }
        compilation.isEnabled = !busy
        chooseButton.isEnabled = !busy
        removeButton.isEnabled = !busy && well.image != nil
        lyricsView.isEditable = !busy && initialLyrics != nil
        statusLabel.stringValue = message
    }

    // MARK: Genre completion

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard control === fields["genre"] else { return [] }
        let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
        guard !prefix.isEmpty else { return [] }
        return knownGenres.filter { $0.lowercased().hasPrefix(prefix) }.prefix(12).map { $0 }
    }

    // MARK: Presentation

    func present(in parent: NSWindow) {
        parent.beginSheet(panel, completionHandler: nil)
    }
}

/// The cover in the Info sheet: shows it, takes a dropped picture or file.
final class ArtworkWell: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onImage: (NSImage) -> Void = { _ in }
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        toolTip = "Drop a picture here, or click Choose…"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        NSColor.white.setFill()
        box.fill()
        if let img = image {
            let side = min(box.width, box.height)
            let r = NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSGradient(starting: NSColor(white: 0.92, alpha: 1), ending: NSColor(white: 0.84, alpha: 1))!.draw(in: box, angle: 90)
            let attrs: [NSAttributedString.Key: Any] = [.font: Aqua.font(11), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
            let text = "No Artwork" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
        }
        (highlighted ? Aqua.accent : NSColor(white: 0.55, alpha: 1)).setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = highlighted ? 2 : 1
        edge.stroke()
    }

    private func imageOn(_ board: NSPasteboard) -> NSImage? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let img = NSImage(contentsOf: url) { return img }
        if let imgs = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = imgs.first { return img }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = imageOn(sender.draggingPasteboard) != nil
        return highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let img = imageOn(sender.draggingPasteboard) else { return false }
        onImage(img)
        return true
    }
}

/// Two or three named tabs in an Aqua capsule, for the Info sheet.
final class InfoTabStrip: NSView {
    let titles: [String]
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onChange: (Int) -> Void = { _ in }
    private let segmentWidth: CGFloat = 78

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidth * CGFloat(titles.count) + 2, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int((p.x - 1) / segmentWidth)
        guard (0..<titles.count).contains(i), i != selectedIndex else { return }
        selectedIndex = i
        onChange(i)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!.draw(in: shape, angle: 90)
        for (i, title) in titles.enumerated() {
            let r = NSRect(x: 1 + CGFloat(i) * segmentWidth, y: 1, width: segmentWidth, height: bounds.height - 2)
            if i == selectedIndex {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSGradient(starting: NSColor(white: 0.72, alpha: 1), ending: NSColor(white: 0.80, alpha: 1))!.draw(in: r, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
            }
            if i > 0 {
                NSColor(white: 0.6, alpha: 1).setFill()
                NSRect(x: r.minX, y: 1, width: 1, height: bounds.height - 2).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Aqua.font(11, bold: i == selectedIndex),
                .foregroundColor: i == selectedIndex ? NSColor.white : NSColor(white: 0.2, alpha: 1),
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
        }
        NSColor(white: 0.55, alpha: 1).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}
