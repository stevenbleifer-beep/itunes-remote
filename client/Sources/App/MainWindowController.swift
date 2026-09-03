import Cocoa

/// The iTunes 10 main window: gray toolbar with transport, display panel and
/// search; source list and artwork on the left; genre/artist/album browser
/// over the track table on the right; status bar along the bottom.
@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    let controller = LibraryController()
    let player = PlayerController()
    let artworkCache = ArtworkCache()
    var snapshotPath: String?

    private enum Tag: Int { case source = 0, genre, artist, album, tracks }

    private enum SourceRow {
        case header(String)
        case library
        case playlist(Playlist)
        case device(DeviceSource)
    }

    private var sourceRows: [SourceRow] = [.header("LIBRARY"), .library, .header("PLAYLISTS")]

    private let toolbar = ChromeView()
    private let previousButton = AquaRoundButton(glyph: .previous, diameter: 26)
    private let playButton = AquaRoundButton(glyph: .play, diameter: 34)
    private let nextButton = AquaRoundButton(glyph: .next, diameter: 26)
    private let volumeSlider = AquaVolumeSlider()
    private let airPlayButton = AquaAirPlayButton()
    private let display = AquaDisplayPanel()
    private let searchField = NSSearchField()
    private let statusBar = ChromeView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let viewCaption = AquaCaption("View")
    private let searchCaption = AquaCaption("Search")
    private let plusButton = AquaBevelButton(glyph: .plus)
    private let shuffleButton = AquaBevelButton(glyph: .shuffle)
    private let repeatButton = AquaBevelButton(glyph: .repeatAll)
    private let artworkButton = AquaBevelButton(glyph: .artwork)
    private let syncButton = AquaBevelButton(glyph: .sync)
    private let ejectButton = AquaBevelButton(glyph: .eject)
    private var artworkHeight: NSLayoutConstraint?
    private var devices: [DeviceSource] = []
    private var deviceTimer: Timer?
    private let mainSplit = NSSplitView()
    private let rightSplit = NSSplitView()
    private let browserSplit = NSSplitView()
    private let sourceList = NSTableView()
    private let genreTable = NSTableView()
    private let artistTable = NSTableView()
    private let albumTable = NSTableView()
    private let trackTable = NSTableView()
    private let artworkView = ArtworkView()

    private var searchTimer: Timer?
    private var updatingUI = false
    private var keyMonitor: Any?
    private var artworkToken = 0
    private var addToPlaylistItem: NSMenuItem?
    private var removeFromPlaylistItem: NSMenuItem?

    // View mode
    enum ViewMode: Int {
        case list = 0, coverFlow = 1, albumList = 2
        /// Segment order in the switcher, as iTunes had it.
        static let segments: [ViewMode] = [.list, .albumList, .coverFlow]
        var segment: Int { ViewMode.segments.firstIndex(of: self) ?? 0 }
    }
    private(set) var viewMode: ViewMode = .list
    private let viewSwitcher = AquaSegmentedControl(glyphs: [.list, .albumList, .coverFlow])

    /// What each table row is: an album header in Album List, or a track.
    private enum DisplayRow {
        case group(AlbumEntry)
        case track(Int)     // index into rows
    }
    private var displayRows: [DisplayRow] = []
    private let topPane = NSView()
    private let coverFlow = CoverFlowView()
    /// What the track table shows: the whole filtered list, or one album.
    private var rows: [Track] = []
    private var albums: [AlbumEntry] = []
    private var albumGeneration = 0
    /// Development only: `--flow-index N` selects album N once the list loads.
    var initialFlowIndex: Int?
    private var infoPanel: InfoPanel?          // held while its sheet is up
    private var namePrompt: NamePrompt?        // held while its sheet is up
    private var statusOverride: String?
    private var statusOverrideTimer: Timer?

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
        window.minSize = NSSize(width: 900, height: 560)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(white: 0.80, alpha: 1)
        buildViews()
        wireController()
        window.setFrameAutosaveName("MainWindow")
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: Layout

    private func buildViews() {
        guard let window = window else { return }
        let content = ChromeView(frame: window.contentView!.bounds)
        content.gradientTop = NSColor(white: 0.80, alpha: 1)
        content.gradientBottom = NSColor(white: 0.80, alpha: 1)
        content.autoresizesSubviews = true
        window.contentView = content
        let W = content.bounds.width, H = content.bounds.height
        let toolbarH: CGFloat = 70, statusH: CGFloat = 24

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
            button.target = self
            toolbar.addSubview(button)
            x += s.width + 4
        }
        previousButton.action = #selector(previousTrack(_:))
        playButton.action = #selector(togglePlay(_:))
        nextButton.action = #selector(nextTrack(_:))

        volumeSlider.frame = NSRect(x: x + 12, y: round(midY - 9), width: 110, height: 18)
        volumeSlider.onChange = { [weak self] v in
            self?.player.setVolume(Int((v * 100).rounded()))
        }
        toolbar.addSubview(volumeSlider)

        display.frame = NSRect(x: round((W - 440) / 2), y: round(midY - 22), width: 440, height: 44)
        display.autoresizingMask = [.minXMargin, .maxXMargin]
        display.primary = "iTunes Remote"
        display.onSeek = { [weak self] seconds in self?.player.seek(to: seconds) }
        toolbar.addSubview(display)

        // Right side of the toolbar, laid out from the window edge inwards.
        let rightMargin: CGFloat = 14
        let searchWidth: CGFloat = 200
        let gap: CGFloat = 14
        let searchX = W - rightMargin - searchWidth
        let apSize = airPlayButton.intrinsicContentSize
        airPlayButton.frame = NSRect(x: searchX - gap - apSize.width, y: round(midY - apSize.height / 2),
                                     width: apSize.width, height: apSize.height)
        airPlayButton.autoresizingMask = [.minXMargin]
        airPlayButton.onClick = { [weak self] sender in self?.showOutputMenu(sender) }
        toolbar.addSubview(airPlayButton)

        let vs = viewSwitcher.intrinsicContentSize
        viewSwitcher.frame = NSRect(x: airPlayButton.frame.minX - gap - vs.width, y: round(midY - vs.height / 2),
                                    width: vs.width, height: vs.height)
        viewSwitcher.autoresizingMask = [.minXMargin]
        viewSwitcher.selectedIndex = (ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .list).segment
        viewSwitcher.onChange = { [weak self] i in self?.setViewMode(ViewMode.segments[i]) }
        toolbar.addSubview(viewSwitcher)

        // Small control size: its cell lays out for an 11-point font, so the
        // text sits on the right baseline instead of low in a regular cell.
        searchField.controlSize = .small
        searchField.frame = NSRect(x: searchX, y: round(midY - 10), width: searchWidth, height: 19)
        searchField.autoresizingMask = [.minXMargin]
        searchField.font = Aqua.font(11)
        searchField.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: Aqua.font(11),
            .foregroundColor: NSColor(white: 0.55, alpha: 1),
        ])

        // Window title, drawn in the toolbar since the real title bar is hidden.
        let emboss = NSShadow()
        emboss.shadowColor = NSColor.white.withAlphaComponent(0.8)
        emboss.shadowOffset = NSSize(width: 0, height: -1)
        emboss.shadowBlurRadius = 0
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        titleLabel.attributedStringValue = NSAttributedString(string: "iTunes Remote", attributes: [
            .font: Aqua.font(13, bold: true), .foregroundColor: NSColor(white: 0.30, alpha: 1),
            .shadow: emboss, .paragraphStyle: centred,
        ])
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: toolbarH - 19, width: W, height: 16)
        titleLabel.autoresizingMask = [.width]
        toolbar.addSubview(titleLabel)

        // "View" and "Search" captions under their controls.
        viewCaption.frame = NSRect(x: viewSwitcher.frame.minX - 10, y: 2, width: viewSwitcher.frame.width + 20, height: 13)
        viewCaption.autoresizingMask = [.minXMargin]
        toolbar.addSubview(viewCaption)
        searchCaption.frame = NSRect(x: searchField.frame.minX, y: 2, width: searchField.frame.width, height: 13)
        searchCaption.autoresizingMask = [.minXMargin]
        toolbar.addSubview(searchCaption)
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

        var bx: CGFloat = 8
        for (button, action, tip) in [
            (plusButton, #selector(newPlaylist(_:)), "New Playlist"),
            (shuffleButton, #selector(toggleShuffle(_:)), "Shuffle"),
            (repeatButton, #selector(cycleRepeat(_:)), "Repeat"),
            (artworkButton, #selector(toggleArtworkPane(_:)), "Show or hide artwork"),
        ] {
            button.frame = NSRect(x: bx, y: 2, width: 34, height: 20)
            button.target = self
            button.action = action
            button.toolTip = tip
            statusBar.addSubview(button)
            bx += 36
        }
        for (button, action, tip, offset) in [
            (syncButton, #selector(syncDevice(_:)), "Sync iPod", 8.0),
            (ejectButton, #selector(ejectDevice(_:)), "Eject iPod", 44.0),
        ] as [(AquaBevelButton, Selector, String, CGFloat)] {
            button.frame = NSRect(x: W - offset - 34, y: 2, width: 34, height: 20)
            button.autoresizingMask = [.minXMargin]
            button.target = self
            button.action = action
            button.toolTip = tip
            button.isHidden = true
            statusBar.addSubview(button)
        }
        artworkButton.isOn = UserDefaults.standard.object(forKey: "artworkPane") as? Bool ?? true

        // Main split: [source list over artwork] | right side
        mainSplit.frame = NSRect(x: 0, y: statusH, width: W, height: H - toolbarH - statusH)
        mainSplit.autoresizingMask = [.width, .height]
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        content.addSubview(mainSplit)

        // Constraints rather than autoresizing: the clip view kept coming up
        // scrolled by the artwork pane's height under the springs-and-struts
        // layout the split view drives.
        let leftPane = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: mainSplit.bounds.height))
        artworkView.caption = "SELECTED ITEM"
        let sourceScroll = scroll(for: sourceList)
        for v in [artworkView as NSView, sourceScroll as NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            leftPane.addSubview(v)
        }
        let artH = artworkView.heightAnchor.constraint(equalToConstant: artworkButton.isOn ? 200 : 0)
        artworkHeight = artH
        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
            artH,
            sourceScroll.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: leftPane.topAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: artworkView.topAnchor),
        ])
        mainSplit.addArrangedSubview(leftPane)

        rightSplit.frame = NSRect(x: 0, y: 0, width: mainSplit.bounds.width - 191, height: mainSplit.bounds.height)
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        mainSplit.addArrangedSubview(rightSplit)
        mainSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        // Browser panes (or Cover Flow) over the track table
        topPane.frame = NSRect(x: 0, y: 0, width: rightSplit.bounds.width, height: 150)
        topPane.autoresizesSubviews = true
        browserSplit.frame = topPane.bounds
        browserSplit.autoresizingMask = [.width, .height]
        browserSplit.isVertical = true
        browserSplit.dividerStyle = .thin
        topPane.addSubview(browserSplit)
        coverFlow.frame = topPane.bounds
        coverFlow.autoresizingMask = [.width, .height]
        coverFlow.isHidden = true
        coverFlow.onSelectionChanged = { [weak self] _ in self?.coverSelectionChanged() }
        coverFlow.onOpen = { [weak self] i in self?.playAlbum(at: i) }
        coverFlow.onToggleFullStage = { [weak self] in self?.toggleFullStage() }
        coverFlow.imageProvider = { [weak self] pid, done in
            guard let self = self else { done(nil); return }
            self.artworkCache.image(for: pid, then: done)
        }
        topPane.addSubview(coverFlow)
        rightSplit.addArrangedSubview(topPane)
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
        if let saved = ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")), saved != .list {
            // The split view has no real height until the window is on screen,
            // so the divider position must be applied after the first pass.
            DispatchQueue.main.async { [weak self] in self?.setViewMode(saved, animated: false) }
        }
    }

    // MARK: View mode

    private func setViewMode(_ mode: ViewMode, animated: Bool = true) {
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
        viewSwitcher.selectedIndex = mode.segment
        let flow = mode == .coverFlow
        browserSplit.isHidden = flow
        coverFlow.isHidden = !flow
        fullStage = false
        // Cover Flow needs room; Album List hides the browser; List keeps it short.
        let total = rightSplit.bounds.height
        let top: CGFloat = flow ? round(total * 0.58) : (mode == .albumList ? 0 : 150)
        rightSplit.setPosition(top, ofDividerAt: 0)
        rightSplit.layoutSubtreeIfNeeded()
        trackTable.floatsGroupRows = false
        if mode == .list {
            albums = []
            refreshRows()
            window?.makeFirstResponder(trackTable)
        } else {
            // The browser's narrowing does not apply here; clear it.
            controller.selectedGenre = nil
            controller.selectedArtist = nil
            controller.selectedAlbum = nil
            loadAlbums()
            window?.makeFirstResponder(flow ? coverFlow : trackTable)
        }
    }

    private var fullStage = false

    /// Cover Flow's corner button: give the stage the whole right side, or
    /// bring the track table back.
    private func toggleFullStage() {
        fullStage.toggle()
        let total = rightSplit.bounds.height
        let top = fullStage ? total - 1 : round(total * 0.58)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            rightSplit.animator().setPosition(top, ofDividerAt: 0)
        }
    }

    private func loadAlbums() {
        guard let api = controller.api, viewMode != .list else { return }
        albumGeneration += 1
        let gen = albumGeneration
        let filter = controller.trackFilter
        let keep = albums.indices.contains(coverFlow.selectedIndex) ? albums[coverFlow.selectedIndex] : nil
        Task { @MainActor in
            do {
                let list = try await api.albumList(filter: filter)
                guard gen == albumGeneration else { return }
                albums = list
                if viewMode == .coverFlow { coverFlow.albums = list }
                if let k = keep, viewMode == .coverFlow,
                   let i = list.firstIndex(where: { $0.album == k.album && $0.artist == k.artist }) {
                    coverFlow.select(i, animated: false)
                } else if let i = initialFlowIndex {
                    initialFlowIndex = nil
                    coverFlow.select(i, animated: false)
                }
                refreshRows()
            } catch {
                flashStatus("Albums: \(error.localizedDescription)")
            }
        }
    }

    private func coverSelectionChanged() {
        refreshRows()
        updateArtwork()
    }

    /// Recomputes the rows the table shows and reloads it.
    private func refreshRows() {
        if viewMode == .coverFlow, albums.indices.contains(coverFlow.selectedIndex) {
            let a = albums[coverFlow.selectedIndex]
            let artist = a.artist.lowercased()
            let album = a.album.lowercased()
            rows = controller.tracks.filter {
                $0.displayArtist.lowercased() == artist && $0.album.lowercased() == album
            }
        } else if viewMode == .coverFlow {
            rows = []
        } else {
            rows = controller.tracks
        }
        if viewMode == .albumList {
            // A header row before each run of tracks from the same album. The
            // rows arrive sorted by artist, album, disc, track already.
            var out: [DisplayRow] = []
            var lookup: [String: AlbumEntry] = [:]
            for a in albums { lookup[a.artist.lowercased() + "\u{1f}" + a.album.lowercased()] = a }
            var lastKey = ""
            for (i, t) in rows.enumerated() {
                let key = t.displayArtist.lowercased() + "\u{1f}" + t.album.lowercased()
                if key != lastKey {
                    lastKey = key
                    let entry = lookup[key] ?? AlbumEntry(
                        album: t.album, artist: t.displayArtist, year: t.year, trackCount: 0, totalTime: 0,
                        coverTrackId: t.persistentId, hasArtwork: false)
                    out.append(.group(entry))
                }
                out.append(.track(i))
            }
            displayRows = out
        } else {
            displayRows = rows.indices.map { .track($0) }
        }
        trackTable.reloadData()
    }

    /// Track index for a table row, or nil for an album header.
    private func trackIndex(forRow row: Int) -> Int? {
        guard row >= 0, row < displayRows.count, case .track(let i) = displayRows[row] else { return nil }
        return i
    }

    private func tableRow(forTrackIndex index: Int) -> Int? {
        displayRows.firstIndex { if case .track(let i) = $0 { return i == index }; return false }
    }

    private func playAlbum(at index: Int) {
        guard albums.indices.contains(index) else { return }
        refreshRows()
        guard let first = rows.first else { return }
        player.play(first, playlist: controller.source.playlistId)
    }

    private func scroll(for table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        table.autoresizingMask = [.width]
        s.documentView = table
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = false
        s.autohidesScrollers = true
        s.scrollerStyle = .legacy
        s.verticalScroller = AquaScroller()
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
        sourceList.target = self
        sourceList.doubleAction = #selector(sourceDoubleClicked(_:))

        let menu = NSMenu()
        let item = NSMenuItem(title: "New Playlist…", action: #selector(newPlaylist(_:)), keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(string: "New Playlist…", attributes: [.font: Aqua.font(13)])
        menu.addItem(item)
        sourceList.menu = menu
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
        let check = AquaTables.column("enabled", title: "", width: 22, min: 22, sortable: false)
        check.maxWidth = 22
        check.resizingMask = []
        trackTable.addTableColumn(check)
        trackTable.addTableColumn(AquaTables.column("name", title: "Name", width: 280, min: 100))
        trackTable.addTableColumn(AquaTables.column("totalTime", title: "Time", width: 52, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("artist", title: "Artist", width: 180, min: 60))
        trackTable.addTableColumn(AquaTables.column("album", title: "Album", width: 180, min: 60))
        trackTable.addTableColumn(AquaTables.column("genre", title: "Genre", width: 110, min: 50))
        trackTable.addTableColumn(AquaTables.column("rating", title: "Rating", width: 70, min: 66))
        trackTable.addTableColumn(AquaTables.column("playCount", title: "Plays", width: 46, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("year", title: "Year", width: 48, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("trackNumber", title: "Track #", width: 64, min: 40, rightAligned: true))
        AquaTables.style(trackTable, rowHeight: 18, header: true)
        trackTable.allowsMultipleSelection = true
        trackTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        trackTable.dataSource = self
        trackTable.delegate = self
        trackTable.target = self
        trackTable.doubleAction = #selector(trackDoubleClicked(_:))

        let menu = NSMenu()
        let info = NSMenuItem(title: "Get Info", action: #selector(showGetInfo(_:)), keyEquivalent: "")
        info.target = self
        info.attributedTitle = NSAttributedString(string: "Get Info", attributes: [.font: Aqua.font(13)])
        menu.addItem(info)
        let play = NSMenuItem(title: "Play", action: #selector(playSelection(_:)), keyEquivalent: "")
        play.target = self
        play.attributedTitle = NSAttributedString(string: "Play", attributes: [.font: Aqua.font(13)])
        menu.addItem(play)
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        add.attributedTitle = NSAttributedString(string: "Add to Playlist", attributes: [.font: Aqua.font(13)])
        add.submenu = NSMenu()
        menu.addItem(add)
        addToPlaylistItem = add
        let remove = NSMenuItem(title: "Remove from Playlist", action: #selector(removeFromPlaylist(_:)), keyEquivalent: "")
        remove.target = self
        remove.attributedTitle = NSAttributedString(string: "Remove from Playlist", attributes: [.font: Aqua.font(13)])
        menu.addItem(remove)
        removeFromPlaylistItem = remove
        menu.delegate = self
        trackTable.menu = menu
    }

    // MARK: Controller wiring

    private func wireController() {
        controller.onPlaylistsChanged = { [weak self] in self?.reloadSourceList() }
        controller.onBrowserChanged = { [weak self] in self?.reloadBrowser() }
        controller.onTracksChanged = { [weak self] in
            guard let self = self else { return }
            if self.viewMode == .coverFlow {
                self.loadAlbums()
            } else {
                self.refreshRows()
            }
            self.updateArtwork()
        }
        controller.onStatusChanged = { [weak self] in self?.updateStatus() }
        controller.onFirstLoad = { [weak self] in self?.firstLoadDone() }
        player.onChange = { [weak self] in self?.updatePlayerUI() }
        player.onOutputsChanged = { [weak self] in self?.updateAirPlayButton() }
        player.onLocalTrackFinished = { [weak self] in self?.step(by: 1) }
        updateStatus()
    }

    func connect(_ api: APIClient) {
        controller.connect(api)
        player.api = api
        artworkCache.api = api
        artworkCache.clear()
        player.start()
        loadDevices()
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadDevices() }
        }
    }

    // MARK: Devices

    private func loadDevices() {
        guard let api = controller.api else { return }
        Task { @MainActor in
            guard let list = try? await api.sources() else { return }
            let ipods = list.filter { $0.isIPod }
            if ipods != devices {
                devices = ipods
                reloadSourceList()
            }
            syncButton.isHidden = ipods.isEmpty
            ejectButton.isHidden = ipods.isEmpty
        }
    }

    @objc private func syncDevice(_ sender: Any?) {
        guard let device = devices.first, let api = controller.api else { return }
        syncButton.isEnabled = false
        Task { @MainActor in
            defer { syncButton.isEnabled = true }
            do {
                try await api.syncSource(device.name)
                flashStatus("Sync started on \(device.name). iTunes reports no progress; watch the iPod.")
            } catch {
                flashStatus("Sync failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func ejectDevice(_ sender: Any?) {
        guard let device = devices.first, let api = controller.api else { return }
        Task { @MainActor in
            do {
                try await api.ejectSource(device.name)
                flashStatus("Ejected \(device.name).")
                devices = []
                reloadSourceList()
                syncButton.isHidden = true
                ejectButton.isHidden = true
            } catch {
                flashStatus("Eject failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Bottom bar

    @objc private func toggleShuffle(_ sender: Any?) {
        player.setShuffle(!(player.state?.shuffle ?? false))
    }

    @objc private func cycleRepeat(_ sender: Any?) {
        player.cycleRepeat()
    }

    @objc private func toggleArtworkPane(_ sender: Any?) {
        let show = !artworkButton.isOn
        artworkButton.isOn = show
        UserDefaults.standard.set(show, forKey: "artworkPane")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            artworkHeight?.animator().constant = show ? 200 : 0
        }
    }

    @objc private func ratingChanged(_ sender: AquaRatingView) {
        guard let index = trackIndex(forRow: trackTable.row(for: sender)), let api = controller.api else { return }
        let track = rows[index]
        let value = sender.rating
        Task { @MainActor in
            do {
                _ = try await api.patchTracks(ids: [track.persistentId], fields: ["rating": value])
                controller.setRating(track.persistentId, value)
                refreshRows()
            } catch {
                sender.rating = track.rating
                flashStatus("Could not set the rating: \(error.localizedDescription)")
            }
        }
    }

    @objc private func enabledToggled(_ sender: AquaCheckbox) {
        guard let index = trackIndex(forRow: trackTable.row(for: sender)), let api = controller.api else { return }
        let track = rows[index]
        let on = sender.isOn
        Task { @MainActor in
            do {
                _ = try await api.patchTracks(ids: [track.persistentId], fields: ["enabled": on])
                controller.setEnabled(track.persistentId, on)
                refreshRows()
            } catch {
                sender.isOn = !on
                flashStatus("Could not change the checkbox: \(error.localizedDescription)")
            }
        }
    }

    private func reloadSourceList() {
        updatingUI = true
        sourceRows = [.header("LIBRARY"), .library]
        if !devices.isEmpty {
            sourceRows.append(.header("DEVICES"))
            sourceRows += devices.map { .device($0) }
        }
        sourceRows.append(.header("PLAYLISTS"))
        sourceRows += controller.playlists.map { .playlist($0) }
        sourceList.reloadData()
        var select = 1
        if let current = controller.source.playlistId,
           let i = sourceRows.firstIndex(where: { if case .playlist(let p) = $0 { return p.persistentId == current }; return false }) {
            select = i
        }
        sourceList.selectRowIndexes(IndexSet(integer: select), byExtendingSelection: false)
        updatingUI = false
        // The clip view comes up offset by the artwork pane's height once the
        // split view has laid out, so pin it to the top after that pass.
        pinSourceListToTop()
        DispatchQueue.main.async { [weak self] in self?.pinSourceListToTop() }
    }

    private func pinSourceListToTop() {
        guard let scroll = sourceList.enclosingScrollView else { return }
        scroll.contentView.setBoundsOrigin(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        sourceList.scrollRowToVisible(0)
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
        statusLabel.stringValue = statusOverride ?? controller.statusText
        updatePlayerUI()
    }

    /// Shows a result line in the status bar for a few seconds.
    private func flashStatus(_ text: String) {
        statusOverride = text
        statusOverrideTimer?.invalidate()
        statusOverrideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.statusOverride = nil
                self?.updateStatus()
            }
        }
        updateStatus()
    }

    // MARK: Editing

    private var selectedTracks: [Track] {
        trackTable.selectedRowIndexes.compactMap { trackIndex(forRow: $0) }.map { rows[$0] }
    }

    @objc func showGetInfo(_ sender: Any?) {
        let selected = selectedTracks
        guard !selected.isEmpty, let window = window, let api = controller.api else { return }
        let panel = InfoPanel(tracks: selected)
        panel.knownGenres = controller.genres.map { $0.name }.filter { !$0.isEmpty }
        let ids = selected.map { $0.persistentId }
        panel.onApply = { [weak self] fields, done in
            Task { @MainActor in
                do {
                    let result = try await api.patchTracks(ids: ids, fields: fields)
                    self?.flashStatus(result.summary)
                    self?.controller.reload()
                    done(result.failed == 0 ? nil : result.summary)
                } catch {
                    done(error.localizedDescription)
                }
            }
        }
        panel.present(in: window)
        infoPanel = panel
    }

    // MARK: Playlists

    @objc func newPlaylist(_ sender: Any?) {
        guard let window = window, let api = controller.api else { return }
        let selected = selectedTracks
        let prompt = NamePrompt(title: "New Playlist", prompt: "Name of the new playlist:",
                                placeholder: "untitled playlist", acceptTitle: "Create")
        prompt.onAccept = { [weak self] name, done in
            Task { @MainActor in
                do {
                    let playlist = try await api.createPlaylist(name: name)
                    var message = "Created \(playlist.name)."
                    // Creating with tracks selected fills the new playlist.
                    if !selected.isEmpty {
                        let change = try await api.addToPlaylist(playlist.persistentId,
                                                                 ids: selected.map { $0.persistentId })
                        message = change.summary("Added")
                    }
                    self?.flashStatus(message)
                    await self?.reloadPlaylists()
                    done(nil)
                } catch {
                    done(error.localizedDescription)
                }
            }
        }
        prompt.present(in: window)
        namePrompt = prompt
    }

    @objc private func addToPlaylistPicked(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String,
              let api = controller.api else { return }
        let ids = selectedTracks.map { $0.persistentId }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            do {
                let change = try await api.addToPlaylist(playlistId, ids: ids)
                flashStatus(change.summary("Added"))
                await reloadPlaylists()
                if controller.source.playlistId == playlistId { controller.reload() }
            } catch {
                flashStatus("Add failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func removeFromPlaylist(_ sender: Any?) {
        guard let playlistId = controller.source.playlistId, let api = controller.api else { return }
        let ids = selectedTracks.map { $0.persistentId }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            do {
                let change = try await api.removeFromPlaylist(playlistId, ids: ids)
                flashStatus(change.summary("Removed"))
                await reloadPlaylists()
                controller.reload()
            } catch {
                flashStatus("Remove failed: \(error.localizedDescription)")
            }
        }
    }

    private func reloadPlaylists() async {
        guard let api = controller.api else { return }
        if let playlists = try? await api.playlists() {
            controller.replacePlaylists(playlists)
            reloadSourceList()
        }
    }

    @objc func playSelection(_ sender: Any?) {
        guard let first = selectedTracks.first else { return }
        player.play(first, playlist: controller.source.playlistId)
    }

    // MARK: Player UI

    private func updatePlayerUI() {
        let state = player.state
        let playing = state?.isPlaying ?? false
        playButton.glyph = playing ? .pause : .play
        display.isPlaying = playing
        display.airPlayActive = player.nonComputerOutputSelected

        if let t = state?.track, state?.state != "stopped" {
            display.duration = t.duration
            display.position = player.displayPosition
            display.primary = t.name
            let parts = [t.artist, t.album].filter { !$0.isEmpty }
            display.secondary = parts.joined(separator: " — ")
        } else {
            display.duration = nil
            switch controller.source {
            case .library: display.primary = "Library"
            case .playlist(let p): display.primary = p.name
            }
            if let e = player.lastError, !player.itunesRunning {
                display.secondary = e
            } else if let e = controller.lastError {
                display.secondary = e
            } else if let info = controller.info {
                let n = NumberFormatter()
                n.numberStyle = .decimal
                let count = n.string(from: NSNumber(value: info.trackCount)) ?? "\(info.trackCount)"
                display.secondary = "\(count) songs in iTunes \(info.itunesVersion ?? info.applicationVersion)"
            } else {
                display.secondary = controller.api == nil ? "Not connected" : "Loading…"
            }
        }
        if let v = state?.volume, !volumeSlider.isDragging {
            volumeSlider.value = Double(v) / 100.0
        }
        shuffleButton.isOn = state?.shuffle ?? false
        let mode = state?.repeatMode ?? "off"
        repeatButton.glyph = mode == "one" ? .repeatOne : .repeatAll
        repeatButton.isOn = mode != "off"
        let up = player.itunesRunning
        for b in [previousButton, playButton, nextButton] { b.isEnabled = up }
        airPlayButton.isEnabled = up
        updateArtwork()
    }

    private func updateAirPlayButton() {
        airPlayButton.isActive = player.nonComputerOutputSelected
    }

    private func showOutputMenu(_ sender: NSView) {
        let menu = NSMenu()
        menu.font = Aqua.font(13)
        if player.outputs.isEmpty {
            let item = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for output in player.outputs {
            let item = NSMenuItem(title: output.name, action: #selector(outputPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = output.name
            item.state = output.selected ? .on : .off
            item.isEnabled = output.available
            item.attributedTitle = NSAttributedString(string: output.name, attributes: [
                .font: Aqua.font(13),
                .foregroundColor: output.available ? NSColor.controlTextColor : NSColor.disabledControlTextColor,
            ])
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // iTunes 12.9.5 cannot AirPlay to a modern Mac (error -15022), so this
        // streams the file from the daemon and plays it here instead.
        let mine = NSMenuItem(title: "Play on This Mac", action: #selector(playHere(_:)), keyEquivalent: "")
        mine.target = self
        mine.state = player.mode == .local ? .on : .off
        mine.attributedTitle = NSAttributedString(string: "Play on This Mac", attributes: [.font: Aqua.font(13)])
        mine.toolTip = "Play through this Mac's speakers; the file streams from the MacBook Pro"
        menu.addItem(mine)
        let refresh = NSMenuItem(title: "Refresh Devices", action: #selector(refreshOutputs(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.attributedTitle = NSAttributedString(string: "Refresh Devices", attributes: [.font: Aqua.font(13)])
        menu.addItem(refresh)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: sender)
    }

    @objc private func outputPicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        player.setMode(.remote)
        player.toggleOutput(name)
    }

    @objc private func playHere(_ sender: Any?) {
        player.setMode(player.mode == .local ? .remote : .local)
        flashStatus(player.mode == .local ? "Playing on this Mac. Double-click a track." : "Playing on the MacBook Pro.")
    }

    @objc private func refreshOutputs(_ sender: Any?) {
        Task { await player.loadOutputs() }
    }

    // MARK: Artwork

    /// Shows the playing track's art, or the selected row's when nothing plays.
    private func updateArtwork() {
        var pid: String?
        var caption = "SELECTED ITEM"
        if let t = player.state?.track, player.state?.state != "stopped" {
            pid = t.persistentId
            caption = "NOW PLAYING"
        } else if let i = trackIndex(forRow: trackTable.selectedRow) {
            pid = rows[i].persistentId
        }
        artworkView.caption = caption
        guard let id = pid else {
            artworkView.image = nil
            return
        }
        if let hit = artworkCache.cached(id) {
            artworkView.image = hit
            return
        }
        if artworkCache.isKnownMiss(id) {
            artworkView.image = nil
            return
        }
        artworkToken += 1
        let token = artworkToken
        artworkView.image = nil
        artworkCache.image(for: id) { [weak self] image in
            guard let self = self, token == self.artworkToken else { return }
            self.artworkView.image = image
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

    // MARK: Transport

    @objc func togglePlay(_ sender: Any?) { player.playPause() }
    @objc func nextTrack(_ sender: Any?) { step(by: 1) }
    @objc func previousTrack(_ sender: Any?) { step(by: -1) }

    /// iTunes 12 treats `play <track>` as a one-item queue, so its own
    /// `next track` stops playback instead of advancing. Step through the list
    /// the user is actually looking at instead, which is also what they expect
    /// after a search, a browser filter, or a column sort.
    private func step(by delta: Int) {
        guard let playing = player.state?.track?.persistentId,
              let i = rows.firstIndex(where: { $0.persistentId == playing }) else {
            delta > 0 ? player.next() : player.previous()
            return
        }
        let j = i + delta
        guard j >= 0, j < rows.count else { return }
        player.play(rows[j], playlist: controller.source.playlistId)
        if let r = tableRow(forTrackIndex: j) {
            trackTable.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            trackTable.scrollRowToVisible(r)
        }
    }

    @objc private func trackDoubleClicked(_ sender: Any?) {
        guard let i = trackIndex(forRow: trackTable.clickedRow) else { return }
        player.play(rows[i], playlist: controller.source.playlistId)
    }

    @objc private func sourceDoubleClicked(_ sender: Any?) {
        let row = sourceList.clickedRow
        guard row >= 0, row < sourceRows.count else { return }
        if case .playlist(let p) = sourceRows[row], let first = rows.first {
            player.play(first, playlist: p.persistentId)
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            // Space toggles playback unless a text field has focus.
            if event.charactersIgnoringModifiers == " ",
               !(self.window?.firstResponder is NSText) {
                self.player.playPause()
                return nil
            }
            if event.charactersIgnoringModifiers == "i", event.modifierFlags.contains(.command) {
                self.showGetInfo(nil)
                return nil
            }
            if event.keyCode == 36, self.window?.firstResponder === self.trackTable {   // Return
                self.trackDoubleClickedFromSelection()
                return nil
            }
            return event
        }
    }

    private func trackDoubleClickedFromSelection() {
        guard let i = trackIndex(forRow: trackTable.selectedRow) else { return }
        player.play(rows[i], playlist: controller.source.playlistId)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === trackTable.menu else { return }
        let editable = controller.playlists.filter { !$0.smart }
        let submenu = NSMenu()
        if editable.isEmpty {
            let none = NSMenuItem(title: "No playlists", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for playlist in editable {
            let item = NSMenuItem(title: playlist.name, action: #selector(addToPlaylistPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = playlist.persistentId
            item.attributedTitle = NSAttributedString(string: playlist.name, attributes: [.font: Aqua.font(13)])
            submenu.addItem(item)
        }
        addToPlaylistItem?.submenu = submenu
        addToPlaylistItem?.isEnabled = !selectedTracks.isEmpty
        removeFromPlaylistItem?.isHidden = controller.source.playlistId == nil
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
        case .tracks: return displayRows.count
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
            switch sourceRows[row] {
            case .header(let s):
                let cell = AquaTables.labelCell(tableView, id: "sourceHeader")
                let emboss = NSShadow()
                emboss.shadowColor = NSColor.white.withAlphaComponent(0.9)
                emboss.shadowOffset = NSSize(width: 0, height: -1)
                emboss.shadowBlurRadius = 0
                cell.textField?.attributedStringValue = NSAttributedString(string: s, attributes: [
                    .font: Aqua.font(11, bold: true), .foregroundColor: Aqua.sidebarHeaderText, .shadow: emboss,
                ])
                return cell
            case .library:
                return sidebarCell(tableView, text: "Music", icon: .music)
            case .playlist(let p):
                return sidebarCell(tableView, text: p.name, icon: p.smart ? .smartPlaylist : .playlist)
            case .device(let d):
                var text = d.name
                if let free = d.freeSpace, let cap = d.capacity, cap > 0 {
                    text += "  (\(StatusFormat.size(free)) free of \(StatusFormat.size(cap)))"
                }
                return sidebarCell(tableView, text: text, icon: .ipod)
            }
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
            guard row < displayRows.count else { return nil }
            if case .group(let album) = displayRows[row] {
                let ident = NSUserInterfaceItemIdentifier("cell.albumGroup")
                let view = (tableView.makeView(withIdentifier: ident, owner: nil) as? AlbumGroupView) ?? {
                    let v = AlbumGroupView()
                    v.identifier = ident
                    return v
                }()
                view.configure(album, cache: artworkCache)
                return view
            }
            guard let id = tableColumn?.identifier.rawValue, let index = trackIndex(forRow: row) else { return nil }
            let t = rows[index]
            if id == "enabled" {
                let ident = NSUserInterfaceItemIdentifier("cell.enabled")
                let box = (tableView.makeView(withIdentifier: ident, owner: nil) as? AquaCheckbox) ?? {
                    let b = AquaCheckbox()
                    b.identifier = ident
                    b.target = self
                    b.action = #selector(enabledToggled(_:))
                    return b
                }()
                box.isOn = t.enabled
                return box
            }
            if id == "rating" {
                let ident = NSUserInterfaceItemIdentifier("cell.rating")
                let stars = (tableView.makeView(withIdentifier: ident, owner: nil) as? AquaRatingView) ?? {
                    let v = AquaRatingView()
                    v.identifier = ident
                    v.target = self
                    v.action = #selector(ratingChanged(_:))
                    return v
                }()
                stars.rating = t.rating
                stars.isEmphasized = tableView.isRowSelected(row) && tableView.window?.firstResponder === tableView
                return stars
            }
            let right = ["totalTime", "year", "trackNumber", "playCount"].contains(id)
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
            case "playCount": text = t.playCount > 0 ? String(t.playCount) : ""
            default: text = ""
            }
            cell.textField?.stringValue = text
            // The playing track is bold, as iTunes marked it.
            let isPlaying = t.persistentId == player.state?.track?.persistentId && player.state?.state != "stopped"
            cell.textField?.font = Aqua.font(11, bold: isPlaying)
            return cell
        case .none:
            return nil
        }
    }

    private func sidebarCell(_ table: NSTableView, text: String, icon: SidebarIcon) -> SidebarCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.sidebar")
        let cell = (table.makeView(withIdentifier: ident, owner: nil) as? SidebarCellView) ?? SidebarCellView(frame: .zero)
        cell.identifier = ident
        cell.label.stringValue = text
        cell.iconView.icon = icon
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let tag = Tag(rawValue: tableView.tag)
        if tag == .tracks, row < displayRows.count, case .group = displayRows[row] {
            return AquaTables.rowView(tableView, row: 0, striped: false, background: .white)
        }
        return AquaTables.rowView(tableView, row: row, striped: tag == .tracks,
                                  background: tag == .source ? Aqua.sidebarBackground : .white,
                                  selection: tag == .source ? .sidebar : .blue)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard Tag(rawValue: tableView.tag) == .tracks, row < displayRows.count else { return false }
        if case .group = displayRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if Tag(rawValue: tableView.tag) == .tracks, row < displayRows.count, case .group = displayRows[row] {
            return 66
        }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if Tag(rawValue: tableView.tag) == .tracks, row < displayRows.count, case .group = displayRows[row] {
            return false
        }
        if Tag(rawValue: tableView.tag) == .source {
            switch sourceRows[row] {
            case .header, .device: return false
            default: return true
            }
        }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if Tag(rawValue: table.tag) == .tracks {
            updateArtwork()
            return
        }
        guard !updatingUI else { return }
        let row = table.selectedRow
        switch Tag(rawValue: table.tag) {
        case .source:
            guard row >= 0 else { return }
            switch sourceRows[row] {
            case .library: controller.source = .library
            case .playlist(let p): controller.source = .playlist(p)
            case .header, .device: break
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
