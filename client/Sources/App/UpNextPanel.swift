import Cocoa

/// The play queue, shown and editable.
///
/// The app has always owned the queue — `play <track>` gives iTunes a one-item
/// queue, so what plays next is decided here — but until now that decision was
/// made on demand and never shown. This panel makes it visible in two parts:
/// the songs explicitly queued up, which can be reordered and removed, and
/// below them a read-only look at what the current list would carry on with.
@MainActor
final class UpNextPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    enum Row {
        case header(String)
        case queued(Int)      // index into `queue`
        case coming(Int)      // index into `upcoming`
    }

    let panel: UpNextWindow
    private let table = AquaTableView()
    private let scroll = NSScrollView()
    private let clearButton = AquaPushButton(title: "Clear")
    private let emptyLabel = NSTextField(labelWithString: "")

    /// The manual queue, newest last. Owned by the window; this panel edits it
    /// through the callbacks below rather than holding the only copy.
    private var queue: [Track] = []
    private var upcoming: [Track] = []
    private var sourceName = ""
    private var rows: [Row] = []

    /// Called with the reordered queue whenever the user drags or deletes.
    var onQueueChanged: ([Track]) -> Void = { _ in }
    /// Play this queued entry now, dropping everything queued before it.
    var onPlayQueued: (Int) -> Void = { _ in }
    /// Play this entry from the list the window is showing.
    var onPlayUpcoming: (Int) -> Void = { _ in }

    private static let dragType = NSPasteboard.PasteboardType("local.stevenbleifer.itunesremote.upnext")

    override init() {
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))
        content.gradientTop = Theme.ink(0.93)
        content.gradientBottom = Theme.ink(0.88)
        panel = UpNextWindow(contentRect: content.frame,
                             styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.onDelete = { [weak self] in self?.deleteSelection() }
        panel.contentView = content
        panel.title = "Up Next"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 320, height: 240)

        table.tag = 0
        table.rowHeight = 18
        table.allowsMultipleSelection = true
        table.addTableColumn(AquaTables.column("track", title: "", width: 300, min: 120))
        AquaTables.style(table, rowHeight: 18, header: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([UpNextPanel.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = Theme.scrollerStyle
        scroll.verticalScroller = AquaScroller()
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = false
        scroll.frame = NSRect(x: 12, y: 46, width: 396, height: 402)
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        emptyLabel.font = Aqua.font(11)
        emptyLabel.textColor = Theme.ink(0.45)
        emptyLabel.frame = NSRect(x: 14, y: 16, width: 300, height: 16)
        emptyLabel.autoresizingMask = [.width]
        content.addSubview(emptyLabel)

        clearButton.target = self
        clearButton.action = #selector(clearQueue(_:))
        let cs = clearButton.intrinsicContentSize
        clearButton.frame = NSRect(x: 420 - 12 - cs.width, y: 12, width: cs.width, height: cs.height)
        clearButton.autoresizingMask = [.minXMargin]
        content.addSubview(clearButton)
    }

    // MARK: Contents

    func update(queue: [Track], upcoming: [Track], sourceName: String) {
        self.queue = queue
        self.upcoming = upcoming
        self.sourceName = sourceName
        rebuild()
    }

    private func rebuild() {
        var out: [Row] = []
        if !queue.isEmpty {
            out.append(.header("QUEUED"))
            out.append(contentsOf: queue.indices.map { .queued($0) })
        }
        if !upcoming.isEmpty {
            out.append(.header(sourceName.isEmpty ? "CONTINUING" : "CONTINUING FROM \(sourceName.uppercased())"))
            out.append(contentsOf: upcoming.indices.map { .coming($0) })
        }
        rows = out
        table.reloadData()
        clearButton.isEnabled = !queue.isEmpty
        if queue.isEmpty && upcoming.isEmpty {
            emptyLabel.stringValue = "Nothing up next."
        } else if queue.isEmpty {
            emptyLabel.stringValue = "Right-click a song for Play Next or Add to Up Next."
        } else {
            let n = queue.count
            emptyLabel.stringValue = "\(n) queued. Drag to reorder, Delete to remove."
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell = AquaTables.labelCell(tableView, id: "upnext")
        switch rows[row] {
        case .header(let s):
            cell.textField?.attributedStringValue = NSAttributedString(string: s, attributes: [
                .font: Aqua.font(10, bold: true), .foregroundColor: Aqua.sidebarHeaderText])
        case .queued(let i):
            cell.textField?.attributedStringValue = label(queue[i], dim: false)
        case .coming(let i):
            cell.textField?.attributedStringValue = label(upcoming[i], dim: true)
        }
        return cell
    }

    private func label(_ t: Track, dim: Bool) -> NSAttributedString {
        let text = t.name + "  —  " + t.artist
        return NSAttributedString(string: text, attributes: [
            .font: Aqua.font(11),
            .foregroundColor: dim ? Theme.ink(0.45) : NSColor.controlTextColor,
        ])
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count, case .header = rows[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count, case .header = rows[row] else { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AquaTables.rowView(tableView, row: row, striped: true, background: Theme.paper, selection: .blue)
    }

    // MARK: Reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Only the manual queue can be rearranged; the continuation is a
        // preview of the list, and reordering it would mean nothing.
        guard row < rows.count, case .queued(let i) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(i), forType: UpNextPanel.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard op == .above, let target = queueSlot(forProposedRow: row) else { return [] }
        tableView.setDropRow(rowForQueueSlot(target), dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let moved = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: UpNextPanel.dragType) }
            .compactMap { Int($0) }
            .filter { $0 >= 0 && $0 < queue.count }
        guard !moved.isEmpty, var slot = queueSlot(forProposedRow: row) else { return false }
        // Everything removed from above the insertion point shifts it up.
        slot -= moved.filter { $0 < slot }.count
        let taken = moved.sorted().reversed().map { queue.remove(at: $0) }.reversed()
        queue.insert(contentsOf: taken, at: max(0, min(slot, queue.count)))
        onQueueChanged(queue)
        rebuild()
        return true
    }

    /// The position within `queue` that a proposed table row corresponds to,
    /// or nil when the row is outside the queued section.
    private func queueSlot(forProposedRow row: Int) -> Int? {
        guard !queue.isEmpty else { return nil }
        // Row 0 is the QUEUED header; the queue occupies rows 1...queue.count,
        // and a drop "above" row queue.count + 1 means the end of the queue.
        let slot = row - 1
        guard slot >= 0, slot <= queue.count else { return nil }
        return slot
    }

    private func rowForQueueSlot(_ slot: Int) -> Int { slot + 1 }

    // MARK: Actions

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .queued(let i): onPlayQueued(i)
        case .coming(let i): onPlayUpcoming(i)
        case .header: break
        }
    }

    @objc private func clearQueue(_ sender: Any?) {
        guard !queue.isEmpty else { return }
        queue.removeAll()
        onQueueChanged(queue)
        rebuild()
    }

    /// Delete removes the selected queued songs. Handled here rather than
    /// through the window's monitor because this is a separate panel.
    func deleteSelection() {
        let doomed = table.selectedRowIndexes.compactMap { r -> Int? in
            guard r < rows.count, case .queued(let i) = rows[r] else { return nil }
            return i
        }.sorted().reversed()
        guard !doomed.isEmpty else { return }
        for i in doomed { queue.remove(at: i) }
        onQueueChanged(queue)
        rebuild()
    }

    func show(near parent: NSWindow?) {
        if let parent = parent, !panel.isVisible {
            var f = panel.frame
            f.origin = NSPoint(x: parent.frame.maxX - f.width - 24, y: parent.frame.maxY - f.height - 48)
            panel.setFrame(f, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Escape closes it, and Delete removes the selected queued songs.
final class UpNextWindow: NSPanel {
    var onDelete: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete()
            return
        }
        super.keyDown(with: event)
    }
}
