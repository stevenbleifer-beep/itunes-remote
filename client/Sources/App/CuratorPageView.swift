import Cocoa

/// The curator's page: a conversation on the left, the playlist it is
/// building on the right, and Save along the bottom — laid out the way the
/// device page is, in the same grey and white.
///
/// The list is the listener's to edit: drag to reorder, Delete to drop a
/// song, double-click to hear one, drag songs out to any playlist in the
/// sidebar. Feedback typed after an edit starts from the edited list.
@MainActor
final class CuratorPageView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onAsk: (String) -> Void = { _ in }
    var onPlay: ([Track], Int) -> Void = { _, _ in }
    var onSave: ([Track], String) -> Void = { _, _ in }
    var onNew: () -> Void = {}
    /// The list after the listener reordered or removed something.
    var onEdited: ([CuratorPick]) -> Void = { _ in }

    private(set) var picks: [CuratorPick] = []
    private var suggestedName = ""

    let table = AquaTableView()
    let field = NSTextField()
    private let tableScroll = NSScrollView()
    private let transcript = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let askButton = AquaPushButton(title: "Ask", isDefault: true)
    private let newButton = AquaPushButton(title: "New")
    private let playButton = AquaPushButton(title: "Play")
    private let saveButton = AquaPushButton(title: "Save to iTunes…")
    private let heading = NSTextField(labelWithString: "Playlist Curator")
    private let statusLabel = NSTextField(labelWithString: "")
    private let indexLabel = NSTextField(labelWithString: "")

    /// Shown along the bottom whenever the curator is idle: which model is
    /// doing the picking, and where it runs.
    var modelLine = "" { didSet { if !busy { statusLabel.stringValue = modelLine } } }

    private var busy = false
    private var busySince: Date?
    private var busyText = ""
    private var busyTimer: Timer?

    private static let dragType = NSPasteboard.PasteboardType("local.stevenbleifer.itunesremote.curator")
    private static let columnWidth: CGFloat = 300

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [transcriptScroll as NSView, field, askButton, heading, tableScroll, statusLabel, indexLabel,
                  newButton, playButton, saveButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // The conversation.
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = true
        transcript.backgroundColor = .white
        transcript.textContainerInset = NSSize(width: 6, height: 8)
        transcript.font = Aqua.font(12)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.scrollerStyle = .legacy
        transcriptScroll.verticalScroller = AquaScroller()
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.drawsBackground = true
        transcriptScroll.backgroundColor = .white

        field.font = Aqua.font(13)
        field.bezelStyle = .squareBezel
        field.placeholderString = "Ask for a playlist, or say what to change"
        field.target = self
        field.action = #selector(ask(_:))
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        askButton.target = self
        askButton.action = #selector(ask(_:))
        newButton.target = self
        newButton.action = #selector(startOver(_:))
        playButton.target = self
        playButton.action = #selector(play(_:))
        saveButton.target = self
        saveButton.action = #selector(save(_:))

        heading.font = Aqua.font(13, bold: true)
        heading.textColor = NSColor(white: 0.25, alpha: 1)
        heading.lineBreakMode = .byTruncatingTail
        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        indexLabel.font = Aqua.font(11)
        indexLabel.textColor = NSColor(white: 0.45, alpha: 1)
        indexLabel.lineBreakMode = .byTruncatingTail
        indexLabel.alignment = .right

        // The playlist.
        for (id, title, width, right) in [
            ("n", "", 28.0, true), ("name", "Name", 190.0, false), ("artist", "Artist", 130.0, false),
            ("album", "Album", 140.0, false), ("year", "Year", 40.0, true), ("time", "Time", 46.0, true), ("why", "Why", 200.0, false),
        ] as [(String, String, CGFloat, Bool)] {
            table.addTableColumn(AquaTables.column(id, title: title, width: width, min: 24, sortable: false, rightAligned: right))
        }
        AquaTables.style(table, rowHeight: 18, header: true)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([CuratorPageView.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = .legacy
        tableScroll.verticalScroller = AquaScroller()
        tableScroll.borderType = .bezelBorder
        tableScroll.autohidesScrollers = false

        let pad: CGFloat = 14
        let col = CuratorPageView.columnWidth
        NSLayoutConstraint.activate([
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            transcriptScroll.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            transcriptScroll.widthAnchor.constraint(equalToConstant: col),
            transcriptScroll.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -8),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            field.trailingAnchor.constraint(equalTo: askButton.leadingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 22),
            askButton.trailingAnchor.constraint(equalTo: transcriptScroll.trailingAnchor, constant: 4),
            askButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            heading.leadingAnchor.constraint(equalTo: transcriptScroll.trailingAnchor, constant: pad),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: indexLabel.leadingAnchor, constant: -10),

            tableScroll.leadingAnchor.constraint(equalTo: transcriptScroll.trailingAnchor, constant: pad),
            tableScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            tableScroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            tableScroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -8),

            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad + 4),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 4),
            playButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: 2),
            playButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            newButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: 2),
            newButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: newButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            indexLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad - 2),
            indexLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
        ])
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        welcome()
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
    }

    // MARK: Transcript

    private func welcome() {
        transcript.string = ""
        append("Ask for a playlist and it will build one from your own library — nothing it names is a song you do not have.\n\n", color: NSColor(white: 0.35, alpha: 1), italic: false)
        append("Try: “make a playlist for date night”, “upbeat 80s for a road trip”, “something like Bill Evans for a rainy Sunday”.\n\n", color: NSColor(white: 0.45, alpha: 1), italic: true)
        append("Then say what to change: “less jazz, add a couple of slow indie rock songs, keep it to 20”.\n", color: NSColor(white: 0.45, alpha: 1), italic: true)
    }

    private func append(_ text: String, color: NSColor, italic: Bool = false, bold: Bool = false) {
        var font = Aqua.font(12, bold: bold)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 2
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        transcript.textStorage?.append(s)
        transcript.scrollToEndOfDocument(nil)
    }

    func say(listener text: String) {
        if !(transcript.string.isEmpty || transcript.string.hasSuffix("\n\n")) { append("\n", color: .black) }
        append("You: ", color: NSColor(white: 0.2, alpha: 1), bold: true)
        append(text + "\n\n", color: NSColor(white: 0.2, alpha: 1))
    }

    func say(curator text: String) {
        append("Curator: ", color: Aqua.accent, bold: true)
        append(text + "\n\n", color: NSColor(white: 0.2, alpha: 1))
    }

    /// A quiet line: what was saved, how long it took, what went wrong.
    func note(_ text: String) {
        append(text + "\n\n", color: NSColor(white: 0.45, alpha: 1), italic: true)
    }

    // MARK: State

    func show(_ reply: CuratorEngine.Reply) {
        picks = reply.picks
        suggestedName = reply.name
        table.reloadData()
        heading.stringValue = reply.name.isEmpty ? "Playlist Curator" : "Playlist Curator — \(reply.name)"
        if !reply.note.isEmpty { say(curator: reply.note) }
        let total = picks.reduce(0) { $0 + ($1.track.totalTime ?? 0) }
        note("\(picks.count) songs, \(StatusFormat.duration(total)) · took \(Int(reply.seconds.rounded())) s")
        updateButtons()
    }

    func setBusy(_ on: Bool) {
        busy = on
        field.isEnabled = !on
        askButton.isEnabled = !on
        busyTimer?.invalidate()
        busyTimer = nil
        if on {
            busySince = Date()
            busyText = "Thinking…"
            busyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            tick()
        } else {
            statusLabel.stringValue = modelLine
            window?.makeFirstResponder(field)
        }
        updateButtons()
    }

    func setStatus(_ text: String) {
        busyText = text
        tick()
    }

    /// The indexing line, or nil when the index is complete.
    func setIndexing(_ text: String?) {
        indexLabel.stringValue = text ?? ""
    }

    private func tick() {
        guard busy, let since = busySince else { return }
        let s = Int(Date().timeIntervalSince(since))
        statusLabel.stringValue = "\(busyText) \(s) s"
    }

    private func updateButtons() {
        let has = !picks.isEmpty
        playButton.isEnabled = has
        saveButton.isEnabled = has && !busy
        newButton.isEnabled = !busy && (has || transcript.string.contains("You: "))
    }

    private var tracks: [Track] { picks.map { $0.track } }

    // MARK: Actions

    @objc private func ask(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        field.stringValue = ""
        onAsk(text)
    }

    @objc private func startOver(_ sender: Any?) {
        picks = []
        suggestedName = ""
        heading.stringValue = "Playlist Curator"
        table.reloadData()
        welcome()
        onNew()
        updateButtons()
        window?.makeFirstResponder(field)
    }

    @objc private func play(_ sender: Any?) {
        guard !picks.isEmpty else { return }
        onPlay(tracks, max(0, table.selectedRow))
    }

    func playSelection() { play(nil) }

    @objc private func save(_ sender: Any?) {
        guard !picks.isEmpty else { return }
        onSave(tracks, suggestedName)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < picks.count else { return }
        onPlay(tracks, row)
    }

    func deleteSelection() {
        let doomed = table.selectedRowIndexes.filter { $0 < picks.count }.sorted().reversed()
        guard !doomed.isEmpty else { return }
        for i in doomed { picks.remove(at: i) }
        table.reloadData()
        onEdited(picks)
        updateButtons()
    }

    func focusField() { window?.makeFirstResponder(field) }

    /// Development only: what the views hold.
    func debugDescriptionOfContents() -> String {
        var s = "heading='\(heading.stringValue)' frame=\(heading.frame) font=\(heading.font?.fontName ?? "-") color=\(heading.textColor?.description ?? "-")\n"
        s += "transcript frame=\(transcript.frame) chars=\(transcript.string.count) container=\(transcript.textContainer?.size ?? .zero) clip=\(transcriptScroll.contentView.bounds)\n"
        s += "field='\(field.stringValue)' placeholder='\(field.placeholderString ?? "")' frame=\(field.frame)\n"
        s += "table rows=\(table.numberOfRows) frame=\(table.frame) clip=\(tableScroll.contentView.bounds) header=\(table.headerView?.frame ?? .zero)\n"
        if table.numberOfRows > 0, let rv = table.rowView(atRow: 0, makeIfNecessary: true) {
            s += "row0 frame=\(rv.frame) subviews=\(rv.subviews.count)\n"
            if let cell = rv.view(atColumn: 1) as? NSTableCellView {
                s += "cell1 frame=\(cell.frame) text='\(cell.textField?.stringValue ?? "")' tfFrame=\(cell.textField?.frame ?? .zero) hidden=\(cell.textField?.isHidden ?? true)\n"
            }
        }
        s += "page layer=\(layer != nil) wantsLayer=\(wantsLayer) window=\(window != nil) visible=\(window?.isVisible ?? false) occlusion=\(window?.occlusionState.contains(.visible) ?? false)"
        return s
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { picks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < picks.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let p = picks[row]
        let right = id == "n" || id == "time" || id == "year"
        let cell = AquaTables.labelCell(tableView, id: right ? "curatorR" : "curator", rightAligned: right)
        let text: String
        switch id {
        case "n": text = String(row + 1)
        case "name": text = p.track.name
        case "artist": text = p.track.artist
        case "album": text = p.track.album
        case "time": text = p.track.durationText
        case "year": text = p.track.year.map(String.init) ?? ""
        case "why": text = p.why
        default: text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = id == "why" ? NSColor(white: 0.4, alpha: 1) : .controlTextColor
        cell.textField?.font = Aqua.font(11)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AquaTables.rowView(tableView, row: row, striped: true, background: .white, selection: .blue)
    }

    // MARK: Dragging: reorder here, or carry songs to a sidebar playlist

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < picks.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: CuratorPageView.dragType)
        item.setString(picks[row].track.persistentId, forType: MainWindowController.trackDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === table else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let moved = (info.draggingPasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: CuratorPageView.dragType) }
            .compactMap { Int($0) }
            .filter { $0 >= 0 && $0 < picks.count }
        guard !moved.isEmpty else { return false }
        var slot = row - moved.filter { $0 < row }.count
        let taken = moved.sorted().reversed().map { picks.remove(at: $0) }.reversed()
        slot = max(0, min(slot, picks.count))
        picks.insert(contentsOf: taken, at: slot)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integersIn: slot..<(slot + taken.count)), byExtendingSelection: false)
        onEdited(picks)
        return true
    }
}
