import Cocoa

/// The Grid view: covers in rows on white, title and artist under each.
/// Draws only the visible rows and asks for images lazily, so the 11,000
/// album library scrolls without building 11,000 views.
@MainActor
final class AlbumGridView: NSView, NSDraggingSource {
    var albums: [AlbumEntry] = [] {
        didSet {
            images.removeAll()
            // `requested` must be cleared too, or the indices the previous
            // album list already asked for are never fetched again and every
            // cover stays a placeholder.
            requested.removeAll()
            generation += 1
            if let s = selectedIndex, s >= albums.count { selectedIndex = nil }
            relayout()
            needsDisplay = true
        }
    }
    private(set) var selectedIndex: Int? {
        didSet { needsDisplay = true }
    }
    var onSelect: (Int?) -> Void = { _ in }
    var onOpen: (Int) -> Void = { _ in }
    var imageProvider: (String, @escaping (NSImage?) -> Void) -> Void = { _, done in done(nil) }
    /// Whether the cache has established for certain that a track has no
    /// cover. Anything else that comes back empty is worth asking about again.
    var knownMiss: (String) -> Bool = { _ in false }

    private var images: [Int: NSImage] = [:]
    private var requested: Set<Int> = []
    private var observing = false
    private var generation = 0
    private let cellW: CGFloat = 176
    private let cellH: CGFloat = 214
    private let art: CGFloat = 150
    private var columns = 1

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.relayout() }
            }
        }
        relayout()
    }

    private func relayout() {
        guard let clip = superview else { return }
        let width = clip.bounds.width
        columns = max(1, Int(width / cellW))
        let rows = (albums.count + columns - 1) / columns
        let height = max(clip.bounds.height, CGFloat(rows) * cellH + 12)
        if frame.size.width != width || frame.size.height != height {
            setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    private func rect(for index: Int) -> NSRect {
        let row = index / columns, col = index % columns
        let leftover = bounds.width - CGFloat(columns) * cellW
        return NSRect(x: leftover / 2 + CGFloat(col) * cellW, y: 8 + CGFloat(row) * cellH, width: cellW, height: cellH)
    }

    private func index(at p: NSPoint) -> Int? {
        let col = Int((p.x - (bounds.width - CGFloat(columns) * cellW) / 2) / cellW)
        let row = Int((p.y - 8) / cellH)
        guard col >= 0, col < columns, row >= 0 else { return nil }
        let i = row * columns + col
        return i < albums.count ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        guard !albums.isEmpty, columns > 0 else { return }
        let firstRow = max(0, Int((dirtyRect.minY - 8) / cellH))
        let lastRow = Int((dirtyRect.maxY - 8) / cellH)
        let start = firstRow * columns
        let end = min(albums.count, (lastRow + 1) * columns)
        guard start < end else { return }
        // Covers far from the screen are let go: every cover ever scrolled
        // past used to stay decoded, which is hundreds of megabytes across
        // a nine-thousand-album library.
        if images.count > 600 {
            let keep = (start - 12 * columns)...(end + 12 * columns)
            for i in Array(images.keys) where !keep.contains(i) {
                images[i] = nil
                requested.remove(i)
            }
        }

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byTruncatingTail
        for i in start..<end {
            let cell = rect(for: i)
            let album = albums[i]
            let selected = i == selectedIndex
            if selected {
                let hl = NSBezierPath(roundedRect: cell.insetBy(dx: 6, dy: 4), xRadius: 6, yRadius: 6)
                NSGradient(starting: Aqua.selectionTopKey, ending: Aqua.selectionBottomKey)!.draw(in: hl, angle: 90)
            }
            let artRect = NSRect(x: cell.midX - art / 2, y: cell.minY + 10, width: art, height: art)
            if let img = images[i] {
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
                sh.shadowBlurRadius = 3
                sh.shadowOffset = NSSize(width: 0, height: 2)
                sh.set()
                NSColor.white.setFill()
                NSBezierPath(rect: artRect).fill()
                NSGraphicsContext.restoreGraphicsState()
                img.draw(in: artRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSGradient(starting: NSColor(white: 0.90, alpha: 1), ending: NSColor(white: 0.80, alpha: 1))!.draw(in: artRect, angle: 90)
                NSColor(white: 0.72, alpha: 1).setStroke()
                let r = art * 0.28
                for k in [1.0, 0.7, 0.4] as [CGFloat] {
                    NSBezierPath(ovalIn: NSRect(x: artRect.midX - r * k, y: artRect.midY - r * k, width: r * k * 2, height: r * k * 2)).stroke()
                }
                request(i)
            }
            NSColor(white: 0.6, alpha: 1).setStroke()
            NSBezierPath(rect: artRect.insetBy(dx: 0.5, dy: 0.5)).stroke()

            let textColor: NSColor = selected ? .white : NSColor(white: 0.15, alpha: 1)
            let subColor: NSColor = selected ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0.45, alpha: 1)
            (album.title as NSString).draw(in: NSRect(x: cell.minX + 6, y: artRect.maxY + 6, width: cell.width - 12, height: 15), withAttributes: [
                .font: Aqua.font(11, bold: true), .foregroundColor: textColor, .paragraphStyle: titleStyle])
            (album.artistName as NSString).draw(in: NSRect(x: cell.minX + 6, y: artRect.maxY + 21, width: cell.width - 12, height: 14), withAttributes: [
                .font: Aqua.font(11), .foregroundColor: subColor, .paragraphStyle: titleStyle])
        }
    }

    private func request(_ index: Int) {
        // iTunes already says whether an album has art; asking the daemon for
        // one that has none costs a round trip that ends in a placeholder.
        guard !requested.contains(index), albums[index].hasArtwork,
              let pid = albums[index].coverTrackId else { return }
        requested.insert(index)
        let gen = generation
        imageProvider(pid) { [weak self] image in
            guard let self = self, gen == self.generation else { return }
            guard let image = image else {
                // Empty is not proof there is no cover. The daemon may have
                // been unreachable, or the client may not have connected yet —
                // which is exactly what happens when the window is built
                // behind the mini player. Leaving the index in `requested`
                // blanked the cell for the life of the album list, so let a
                // later draw ask again unless the cache is certain.
                if !self.knownMiss(pid) {
                    self.requested.remove(index)
                    self.scheduleRetry()
                }
                return
            }
            self.images[index] = image
            // Never repaint straight from here. A cover the cache already has
            // comes back synchronously, which means this runs *inside* the
            // draw pass that asked for it — and AppKit throws away a
            // setNeedsDisplay issued while drawing. The image was stored and
            // never shown, which is what left the Grid full of placeholder
            // discs even though every fetch had succeeded.
            self.scheduleRepaint()
        }
    }

    /// Coalesced repaint on the next turn of the run loop, so a screenful of
    /// covers costs one redraw and none of them are lost to the draw pass they
    /// were requested from.
    private var repaintScheduled = false

    private func scheduleRepaint() {
        guard !repaintScheduled else { return }
        repaintScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.repaintScheduled = false
            self.needsDisplay = true
        }
    }

    /// Redraw once, shortly, so covers that came back empty are asked for
    /// again without waiting for the user to scroll. Debounced to one pass in
    /// flight, so a screenful of failures costs a single retry rather than one
    /// per cell.
    private var retryScheduled = false

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            self.needsDisplay = true
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let hit = index(at: p)
        if event.clickCount == 2, let i = hit {
            onOpen(i)
            return
        }
        if hit != selectedIndex {
            selectedIndex = hit
            onSelect(hit)
        }
        dragStart = hit.map { ($0, p) }
    }

    /// Selects an album as a click would, and scrolls it into view.
    func select(_ index: Int) {
        guard albums.indices.contains(index) else { return }
        selectedIndex = index
        onSelect(index)
        // Its row at the top of the view, where a person would scroll to.
        let r = rect(for: index)
        scroll(NSPoint(x: 0, y: max(0, r.minY - 8)))
    }

    private func dragImage(for index: Int) -> NSImage? { images[index] }

    // MARK: Drag out

    /// The track ids a cover carries when dragged onto a playlist or the iPod.
    var dragIds: (Int) -> [String] = { _ in [] }
    private var dragStart: (index: Int, point: NSPoint)?

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.point.x, p.y - start.point.y) > 4 else { return }
        dragStart = nil
        let ids = dragIds(start.index)
        guard !ids.isEmpty else { return }
        let item = NSPasteboardItem()
        item.setString(ids.joined(separator: "\n"), forType: MainWindowController.trackDragType)
        if albums.indices.contains(start.index) {
            item.setString(albums[start.index].title + " — " + albums[start.index].artistName, forType: .string)
        }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let size = NSSize(width: 72, height: 72)
        let image = dragImage(for: start.index) ?? NSImage(size: size, flipped: false) { r in
            NSColor(white: 0.82, alpha: 1).setFill()
            r.fill()
            return true
        }
        dragItem.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                         width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    override func keyDown(with event: NSEvent) {
        guard !albums.isEmpty else { return }
        let cur = selectedIndex ?? 0
        var next = cur
        switch event.keyCode {
        case 123: next = cur - 1
        case 124: next = cur + 1
        case 126: next = cur - columns
        case 125: next = cur + columns
        case 36, 76: onOpen(cur); return
        default: super.keyDown(with: event); return
        }
        next = max(0, min(albums.count - 1, next))
        if next != selectedIndex {
            selectedIndex = next
            onSelect(next)
            scrollToVisible(rect(for: next))
        }
    }
}
