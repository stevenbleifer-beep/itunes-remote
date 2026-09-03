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
    }

    private enum Row {
        case header(String)
        case artist(FacetEntry)
        case album(AlbumEntry)
        case song(Track)
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
            i = rows.firstIndex { if case .song = $0 { return true }; return false }
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
        }
        hide()
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
        let grey = NSColor(white: 0.45, alpha: 1)
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
        AquaTables.rowView(tableView, row: row, striped: false, background: .white, selection: .blue)
    }
}

/// White with a one-pixel grey line round it.
final class SearchPopupBezel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
