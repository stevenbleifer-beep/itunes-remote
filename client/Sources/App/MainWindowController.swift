import Cocoa

/// The iTunes-style main window: metal toolbar with the display panel and
/// search, source list on the left, genre/artist/album browser over the track
/// table on the right, status bar along the bottom.
@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    let controller = LibraryController()
    var snapshotPath: String?

    private enum Tag: Int { case source = 0, genre, artist, album, tracks }

    private enum SourceRow {
        case header(String)
        case library
        case playlist(Playlist)
    }

    private var sourceRows: [SourceRow] = [.header("LIBRARY"), .library, .header("PLAYLISTS")]

    private let toolbar = ChromeView()
    private let previousButton = AquaRoundButton(glyph: .previous, diameter: 26)
    private let playButton = AquaRoundButton(glyph: .play, diameter: 34)
    private let nextButton = AquaRoundButton(glyph: .next, diameter: 26)
    private let volumeSlider = AquaVolumeSlider()
    private let display = AquaDisplayPanel()
    private let searchField = NSSearchField()
    private let statusBar = ChromeView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let mainSplit = NSSplitView()
    private let rightSplit = NSSplitView()
    private let browserSplit = NSSplitView()
    private let sourceList = NSTableView()
    private let genreTable = NSTableView()
    private let artistTable = NSTableView()
    private let albumTable = NSTableView()
    private let trackTable = NSTableView()

    private var searchTimer: Timer?
    private var updatingUI = false

    // MARK: Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "iTunes Remote"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 520)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(white: 0.80, alpha: 1)
        buildViews()
        wireController()
        window.setFrameAutosaveName("MainWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildViews() {
        guard let window = window else { return }
        let content = ChromeView(frame: window.contentView!.bounds)
        content.gradientTop = NSColor(white: 0.80, alpha: 1)
        content.gradientBottom = NSColor(white: 0.80, alpha: 1)
        content.autoresizesSubviews = true
        window.contentView = content
        let W = content.bounds.width, H = content.bounds.height
        let toolbarH: CGFloat = 64, statusH: CGFloat = 24, gutter: CGFloat = 0

        // Toolbar: transport at the left, display centred, search at the right.
        toolbar.frame = NSRect(x: 0, y: H - toolbarH, width: W, height: toolbarH)
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.bottomLine = true
        content.addSubview(toolbar)

        let midY: CGFloat = 28   // keeps the controls clear of the traffic lights
        var x: CGFloat = 86
        for button in [previousButton, playButton, nextButton] {
            let s = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: round(midY - s.height / 2), width: s.width, height: s.height)
            toolbar.addSubview(button)
            x += s.width + 4
        }
        volumeSlider.frame = NSRect(x: x + 12, y: round(midY - 9), width: 120, height: 18)
        toolbar.addSubview(volumeSlider)

        display.frame = NSRect(x: round((W - 440) / 2), y: round(midY - 19), width: 440, height: 38)
        display.autoresizingMask = [.minXMargin, .maxXMargin]
        display.primary = "iTunes Remote"
        toolbar.addSubview(display)

        searchField.frame = NSRect(x: W - 180 - 16, y: round(midY - 11), width: 180, height: 22)
        searchField.autoresizingMask = [.minXMargin]
        searchField.font = Aqua.font(11)
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        toolbar.addSubview(searchField)

        // Status bar
        statusBar.frame = NSRect(x: 0, y: 0, width: W, height: statusH)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        statusBar.topLine = true
        content.addSubview(statusBar)
        statusLabel.frame = NSRect(x: 0, y: 4, width: W, height: 16)
        statusLabel.autoresizingMask = [.width]
        statusLabel.alignment = .center
        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.2, alpha: 1)
        statusBar.addSubview(statusLabel)

        // Main split: source list | right side
        mainSplit.frame = NSRect(x: gutter, y: statusH, width: W - 2 * gutter, height: H - toolbarH - statusH)
        mainSplit.autoresizingMask = [.width, .height]
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        content.addSubview(mainSplit)

        let sourceScroll = scroll(for: sourceList)
        sourceScroll.frame = NSRect(x: 0, y: 0, width: 190, height: mainSplit.bounds.height)
        mainSplit.addArrangedSubview(sourceScroll)

        rightSplit.frame = NSRect(x: 0, y: 0, width: mainSplit.bounds.width - 191, height: mainSplit.bounds.height)
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(rightSplit)
        mainSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        // Browser panes over track table
        browserSplit.frame = NSRect(x: 0, y: 0, width: rightSplit.bounds.width, height: 150)
        browserSplit.isVertical = true
        browserSplit.dividerStyle = .thin
        rightSplit.addArrangedSubview(browserSplit)
        let trackScroll = scroll(for: trackTable)
        rightSplit.addArrangedSubview(trackScroll)
        rightSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        let third = browserSplit.bounds.width / 3
        for (table, title) in [(genreTable, "Genres"), (artistTable, "Artists"), (albumTable, "Albums")] {
            let s = scroll(for: table)
            s.frame = NSRect(x: 0, y: 0, width: third, height: 150)
            browserSplit.addArrangedSubview(s)
            configureBrowser(table, title: title)
        }

        configureSourceList()
        configureTrackTable()
        mainSplit.adjustSubviews()
        window.initialFirstResponder = trackTable
    }

    private func scroll(for table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = false
        s.autohidesScrollers = true
        s.borderType = .lineBorder
        s.drawsBackground = true
        s.backgroundColor = .white
        return s
    }

    private func configureSourceList() {
        sourceList.tag = Tag.source.rawValue
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        c.resizingMask = .autoresizingMask
        sourceList.addTableColumn(c)
        AquaTables.style(sourceList, rowHeight: 20, background: Aqua.sidebarBackground, header: false)
        sourceList.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sourceList.dataSource = self
        sourceList.delegate = self
        sourceList.enclosingScrollView?.backgroundColor = Aqua.sidebarBackground
    }

    private func configureBrowser(_ table: NSTableView, title: String) {
        table.tag = title == "Genres" ? Tag.genre.rawValue : title == "Artists" ? Tag.artist.rawValue : Tag.album.rawValue
        let c = AquaTables.column(title.lowercased(), title: title, width: 200, sortable: false)
        c.resizingMask = .autoresizingMask
        table.addTableColumn(c)
        AquaTables.style(table, rowHeight: 18, header: true)
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    private func configureTrackTable() {
        trackTable.tag = Tag.tracks.rawValue
        trackTable.addTableColumn(AquaTables.column("name", title: "Name", width: 280, min: 100))
        trackTable.addTableColumn(AquaTables.column("totalTime", title: "Time", width: 52, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("artist", title: "Artist", width: 180, min: 60))
        trackTable.addTableColumn(AquaTables.column("album", title: "Album", width: 180, min: 60))
        trackTable.addTableColumn(AquaTables.column("genre", title: "Genre", width: 110, min: 50))
        trackTable.addTableColumn(AquaTables.column("year", title: "Year", width: 48, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("trackNumber", title: "Track #", width: 64, min: 40, rightAligned: true))
        AquaTables.style(trackTable, rowHeight: 18, header: true)
        trackTable.allowsMultipleSelection = true
        trackTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        trackTable.dataSource = self
        trackTable.delegate = self
    }

    // MARK: Controller wiring

    private func wireController() {
        controller.onPlaylistsChanged = { [weak self] in self?.reloadSourceList() }
        controller.onBrowserChanged = { [weak self] in self?.reloadBrowser() }
        controller.onTracksChanged = { [weak self] in self?.trackTable.reloadData() }
        controller.onStatusChanged = { [weak self] in self?.updateStatus() }
        controller.onFirstLoad = { [weak self] in self?.firstLoadDone() }
        updateStatus()
    }

    private func reloadSourceList() {
        updatingUI = true
        sourceRows = [.header("LIBRARY"), .library, .header("PLAYLISTS")]
        sourceRows += controller.playlists.map { .playlist($0) }
        sourceList.reloadData()
        sourceList.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        updatingUI = false
    }

    private func reloadBrowser() {
        updatingUI = true
        for (table, entries, selected) in [
            (genreTable, controller.genres, controller.selectedGenre),
            (artistTable, controller.artists, controller.selectedArtist),
            (albumTable, controller.albums, controller.selectedAlbum),
        ] {
            table.reloadData()
            var row = 0
            if let s = selected, let i = entries.firstIndex(where: { $0.name == s }) { row = i + 1 }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if row > 0 { table.scrollRowToVisible(row) }
        }
        updatingUI = false
    }

    private func updateStatus() {
        statusLabel.stringValue = controller.statusText
        switch controller.source {
        case .library: display.primary = "Library"
        case .playlist(let p): display.primary = p.name
        }
        if let e = controller.lastError {
            display.secondary = e
        } else if let info = controller.info {
            display.secondary = "\(info.trackCount) songs in iTunes \(info.applicationVersion)"
        } else {
            display.secondary = controller.api == nil ? "Not connected" : "Loading…"
        }
    }

    private func firstLoadDone() {
        guard let path = snapshotPath, let content = window?.contentView else { return }
        window?.makeKeyAndOrderFront(nil)
        trackTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        window?.makeFirstResponder(trackTable)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let b = content.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width) * 2, pixelsHigh: Int(b.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = b.size
        content.cacheDisplay(in: b, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        exit(0)
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        searchTimer?.invalidate()
        let text = searchField.stringValue
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.controller.searchText = text }
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch Tag(rawValue: tableView.tag) {
        case .source: return sourceRows.count
        case .genre: return controller.genres.count + 1
        case .artist: return controller.artists.count + 1
        case .album: return controller.albums.count + 1
        case .tracks: return controller.tracks.count
        case .none: return 0
        }
    }

    private func facetText(_ entries: [FacetEntry], row: Int, noun: String) -> String {
        if row == 0 { return "All (\(entries.count) \(noun)\(entries.count == 1 ? "" : "s"))" }
        let name = entries[row - 1].name
        return name.isEmpty ? "Unknown" : name
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch Tag(rawValue: tableView.tag) {
        case .source:
            let cell = AquaTables.labelCell(tableView, id: "source")
            switch sourceRows[row] {
            case .header(let s):
                // Embossed: a hard white shadow one pixel below the gray text.
                let emboss = NSShadow()
                emboss.shadowColor = NSColor.white.withAlphaComponent(0.9)
                emboss.shadowOffset = NSSize(width: 0, height: -1)
                emboss.shadowBlurRadius = 0
                cell.textField?.attributedStringValue = NSAttributedString(string: s, attributes: [
                    .font: Aqua.font(11, bold: true), .foregroundColor: Aqua.sidebarHeaderText, .shadow: emboss,
                ])
            case .library:
                cell.textField?.stringValue = "Library"
                cell.textField?.font = Aqua.font(11)
                cell.textField?.textColor = .controlTextColor
            case .playlist(let p):
                cell.textField?.stringValue = p.name
                cell.textField?.font = Aqua.font(11)
                cell.textField?.textColor = .controlTextColor
            }
            return cell
        case .genre:
            let cell = AquaTables.labelCell(tableView, id: "facet")
            cell.textField?.stringValue = facetText(controller.genres, row: row, noun: "Genre")
            return cell
        case .artist:
            let cell = AquaTables.labelCell(tableView, id: "facet")
            cell.textField?.stringValue = facetText(controller.artists, row: row, noun: "Artist")
            return cell
        case .album:
            let cell = AquaTables.labelCell(tableView, id: "facet")
            cell.textField?.stringValue = facetText(controller.albums, row: row, noun: "Album")
            return cell
        case .tracks:
            guard let id = tableColumn?.identifier.rawValue, row < controller.tracks.count else { return nil }
            let t = controller.tracks[row]
            let right = ["totalTime", "year", "trackNumber"].contains(id)
            let cell = AquaTables.labelCell(tableView, id: right ? "trackR" : "track", rightAligned: right)
            let text: String
            switch id {
            case "name": text = t.name
            case "totalTime": text = t.durationText
            case "artist": text = t.artist
            case "album": text = t.album
            case "genre": text = t.genre
            case "year": text = t.year.map(String.init) ?? ""
            case "trackNumber": text = t.trackNumber.map(String.init) ?? ""
            default: text = ""
            }
            cell.textField?.stringValue = text
            return cell
        case .none:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let tag = Tag(rawValue: tableView.tag)
        return AquaTables.rowView(tableView, row: row, striped: tag == .tracks,
                                  background: tag == .source ? Aqua.sidebarBackground : .white)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if Tag(rawValue: tableView.tag) == .source, case .header = sourceRows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingUI, let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        switch Tag(rawValue: table.tag) {
        case .source:
            guard row >= 0 else { return }
            switch sourceRows[row] {
            case .library: controller.source = .library
            case .playlist(let p): controller.source = .playlist(p)
            case .header: break
            }
        case .genre:
            controller.selectedGenre = row > 0 ? controller.genres[row - 1].name : nil
        case .artist:
            controller.selectedArtist = row > 0 ? controller.artists[row - 1].name : nil
        case .album:
            controller.selectedAlbum = row > 0 ? controller.albums[row - 1].name : nil
        default:
            break
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard Tag(rawValue: tableView.tag) == .tracks else { return }
        let d = tableView.sortDescriptors.first
        controller.setSort(key: d?.key, ascending: d?.ascending ?? true)
    }
}
