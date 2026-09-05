import Cocoa

/// Matches dropped under the search field as you type, the way iTunes 11
/// did it: a few artists, a few albums, a few songs, each a click away.
///
/// The list filters live as before; this is on top of it. The panel never
/// takes key focus — typing stays in the field, and the arrow keys, Return
/// and Escape are routed here by the window's key monitor.
@MainActor
final class SearchPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    enum Pick {
        case artist(String)
        case album(AlbumEntry)
        case song(Track)
        /// From Apple Music's catalogue, with the row's screen rect so the
        /// owner can drop an action menu under it.
        case catalogSong(AppleMusicCatalog.SongHit, NSRect)
        case catalogAlbum(AppleMusicCatalog.AlbumHit, NSRect)
    }

    private enum Row {
        case header(String)
        case artist(FacetEntry)
        case album(AlbumEntry)
        case song(Track)
        case catalogSong(AppleMusicCatalog.SongHit)
        case catalogAlbum(AppleMusicCatalog.AlbumHit)
    }

    let panel: NSPanel
    private let table = AquaTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    private static let width: CGFloat = 320

    var onPick: (Pick) -> Void = { _ in }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: SearchPopup.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu

        // Square, hairline-bordered, on white — the shape of an Aqua-era
        // completion list, not a rounded modern popover.
        let content = SearchPopupBezel(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content

        table.rowHeight = 18
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.addTableColumn(AquaTables.column("match", title: "", width: SearchPopup.width - 4, min: 100))
        AquaTables.style(table, rowHeight: 18, header: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        // A click must land even though the panel never becomes key.
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.frame = content.bounds.insetBy(dx: 1, dy: 1)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)
    }

    // MARK: Contents

    var isVisible: Bool { panel.isVisible }

    func update(artists: [FacetEntry], albums: [AlbumEntry], songs: [Track], below field: NSView) {
        var out: [Row] = []
        if !artists.isEmpty {
            out.append(.header("ARTISTS"))
            out.append(contentsOf: artists.prefix(3).map { .artist($0) })
        }
        if !albums.isEmpty {
            out.append(.header("ALBUMS"))
            out.append(contentsOf: albums.prefix(3).map { .album($0) })
        }
        if !songs.isEmpty {
            out.append(.header("SONGS"))
            out.append(contentsOf: songs.prefix(6).map { .song($0) })
        }
        place(out, below: field)
    }

    private func place(_ out: [Row], below field: NSView) {
        rows = out
        guard !rows.isEmpty, let window = field.window else { hide(); return }
        table.reloadData()
        table.deselectAll(nil)

        // Rows, plus the hairline border and a little breathing room below
        // the last one so it is not clipped.
        let height = CGFloat(rows.count) * 18 + 8
        let fieldRect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let frame = NSRect(x: fieldRect.maxX - SearchPopup.width, y: fieldRect.minY - height - 4,
                           width: SearchPopup.width, height: height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    /// Apple Music's answer for the text: albums, then songs. On the Apple
    /// Music library the popup is the catalogue, not the library — the
    /// list underneath still filters the library as it always did.
    func update(catalogSongs: [AppleMusicCatalog.SongHit], catalogAlbums: [AppleMusicCatalog.AlbumHit],
                note: String?, below field: NSView) {
        var out: [Row] = []
        if let note = note { out.append(.header(note)) }
        if !catalogAlbums.isEmpty {
            out.append(.header("APPLE MUSIC ALBUMS"))
            out.append(contentsOf: catalogAlbums.prefix(3).map { .catalogAlbum($0) })
        }
        if !catalogSongs.isEmpty {
            out.append(.header("APPLE MUSIC SONGS"))
            out.append(contentsOf: catalogSongs.prefix(6).map { .catalogSong($0) })
        }
        place(out, below: field)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
    }

    // MARK: Keyboard, routed from the window

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        var i = table.selectedRow
        repeat {
            i += delta
            if i < 0 { i = rows.count - 1 }
            if i >= rows.count { i = 0 }
        } while isHeader(i)
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    /// Return with nothing highlighted takes the first song, which is what
    /// someone who typed a title and hit Return meant.
    func activateSelection() {
        var i = table.selectedRow
        if i < 0 {
            i = rows.firstIndex { if case .song = $0 { return true }; if case .catalogSong = $0 { return true }; return false }
                ?? rows.firstIndex { !isHeaderRow($0) } ?? -1
        }
        guard i >= 0, i < rows.count else { return }
        pick(row: i)
    }

    private func isHeader(_ i: Int) -> Bool { i < rows.count && isHeaderRow(rows[i]) }
    private func isHeaderRow(_ r: Row) -> Bool { if case .header = r { return true }; return false }

    private func pick(row i: Int) {
        switch rows[i] {
        case .header: return
        case .artist(let a): onPick(.artist(a.name))
        case .album(let a): onPick(.album(a))
        case .song(let t): onPick(.song(t))
        case .catalogSong(let s): onPick(.catalogSong(s, rowRect(i)))
        case .catalogAlbum(let a): onPick(.catalogAlbum(a, rowRect(i)))
        }
        hide()
    }

    /// The row on screen, for a menu that should hang off it.
    private func rowRect(_ i: Int) -> NSRect {
        let r = table.rect(ofRow: i)
        let inWindow = table.convert(r, to: nil)
        return panel.convertToScreen(inWindow)
    }

    @objc private func clicked(_ sender: Any?) {
        let i = table.clickedRow
        guard i >= 0, i < rows.count, !isHeader(i) else { return }
        pick(row: i)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = AquaTables.labelCell(tableView, id: "search")
        let grey = Theme.ink(0.45)
        switch rows[row] {
        case .header(let s):
            cell.textField?.attributedStringValue = NSAttributedString(string: s, attributes: [
                .font: Aqua.font(10, bold: true), .foregroundColor: Aqua.sidebarHeaderText])
        case .artist(let a):
            cell.textField?.attributedStringValue = twoTone(a.name, "\(a.count) song\(a.count == 1 ? "" : "s")", grey)
        case .album(let a):
            cell.textField?.attributedStringValue = twoTone(a.title, a.artistName, grey)
        case .song(let t):
            cell.textField?.attributedStringValue = twoTone(t.name, t.artist, grey)
        case .catalogSong(let s):
            cell.textField?.attributedStringValue = twoTone(s.name, s.artist + (s.album.isEmpty ? "" : " · " + s.album), grey)
        case .catalogAlbum(let a):
            cell.textField?.attributedStringValue = twoTone(a.name, a.artist + (a.year.map { " · \($0)" } ?? ""), grey)
        }
        return cell
    }

    private func twoTone(_ main: String, _ sub: String, _ grey: NSColor) -> NSAttributedString {
        let s = NSMutableAttributedString(string: main, attributes: [
            .font: Aqua.font(11), .foregroundColor: NSColor.controlTextColor])
        s.append(NSAttributedString(string: "  —  " + sub, attributes: [
            .font: Aqua.font(11), .foregroundColor: grey]))
        return s
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeader(row) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeader(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AquaTables.rowView(tableView, row: row, striped: false, background: Theme.paper, selection: .blue)
    }
}

/// White with a one-pixel grey line round it.
final class SearchPopupBezel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        Theme.ink(0.55).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
