import Cocoa

/// The iTunes 10 main window: gray toolbar with transport, display panel and
/// search; source list and artwork on the left; genre/artist/album browser
/// over the track table on the right; status bar along the bottom.
@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSSplitViewDelegate {

    let controller = LibraryController()
    let player = PlayerController()
    let artworkCache = ArtworkCache()
    private let mediaKeys = MediaKeys()
    var snapshotPath: String?
    /// With --snapshot, open this device's Music pane before capturing.
    var snapshotDevice: String?
    /// With --snapshot-device: which display view to capture.
    var snapshotLCD: String?

    private enum Tag: Int { case source = 0, browser, tracks }

    private enum SourceRow {
        case header(String)
        case library
        case recentlyAdded
        case playlist(Playlist)
        case device(DeviceSource)
        case curator
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
    private let reconnectButton = AquaBevelButton(glyph: .reconnect)
    private let upNextButton = AquaBevelButton(glyph: .upNext)
    private let syncButton = AquaBevelButton(glyph: .sync)
    private let ejectButton = AquaBevelButton(glyph: .eject)
    /// Home or away, at the right end of the status bar.
    private let connectionBadge = AquaConnectionBadge()
    /// When iTunes last saved its library, beside the badge.
    private let libraryStamp = NSTextField(labelWithString: "")
    /// Makes the MacBook Pro look at the library file this instant.
    private let refreshButton = AquaBevelButton(glyph: .refresh)
    private var artworkHeight: NSLayoutConstraint?
    private var devices: [DeviceSource] = []
    private var deviceTimer: Timer?
    private var alertTimer: Timer?
    private var miniPlayer: MiniPlayerWindowController?
    private var columnMenu: NSMenu?
    private var sourceMenu: NSMenu?
    private let mainSplit = NSSplitView()
    /// Holds the browser-and-tracks split and the device page, one at a time.
    private let rightContainer = NSView()
    private let devicePage = DevicePageView()
    /// The curator's page, shown in place of the browser and track table.
    private let curatorPage = CuratorPageView()
    private let curator = CuratorEngine()
    private var curatorOpen = false
    private var curatorLibraryVersion: String?
    /// How deep each playlist sits in the folder tree, for the sidebar's indent.
    private var playlistDepth: [String: Int] = [:]
    private var collapsedFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedFolders") ?? [])
    /// The device whose page is showing, if any.
    private var openDevice: String?
    private var devicePageTimer: Timer?
    private var deviceReadInFlight = false
    private let rightSplit = NSSplitView()
    private let browserSplit = NSSplitView()
    /// Which browser panes are shown, in order. iTunes offered these five.
    private var browserFields: [String] = (UserDefaults.standard.array(forKey: "browserFields") as? [String])
        ?? ["genre", "artist", "album"]
    private var browserVisible = UserDefaults.standard.object(forKey: "browserVisible") as? Bool ?? true
    /// The height the user dragged the column browser to. Kept so switching to
    /// Cover Flow, Grid or Album List and back restores it instead of
    /// resetting to the default.
    private var browserHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "browserHeight")
        return saved >= 60 ? CGFloat(saved) : 150
    }()
    private var browserScrolls: [String: NSScrollView] = [:]
    private var browserTables: [String: NSTableView] = [:]
    private let sourceList = NSTableView()
    private let trackTable = AquaTableView()
    private let artworkView = ArtworkView()

    private var searchTimer: Timer?
    private var updatingUI = false
    private var keyMonitor: Any?
    private var artworkToken = 0
    private var addToPlaylistItem: NSMenuItem?
    private var removeFromPlaylistItem: NSMenuItem?
    private var addToIPodItem: NSMenuItem?
    private var removeFromIPodItem: NSMenuItem?
    /// The playlists that actually reach the iPod, so "add to the sync" can
    /// mean something concrete. iTunes keeps the sync selection to itself, but
    /// the playlists sitting on the device say which ones it is.
    private var syncedPlaylists: [DeviceSync.SyncedPlaylist] = []
    private var syncedDevice: String?

    // View mode
    enum ViewMode: Int {
        case list = 0, coverFlow = 1, albumList = 2, grid = 3
        /// Segment order in the switcher, as iTunes had it.
        static let segments: [ViewMode] = [.list, .albumList, .grid, .coverFlow]
        var segment: Int { ViewMode.segments.firstIndex(of: self) ?? 0 }
    }
    private(set) var viewMode: ViewMode = .list
    private let viewSwitcher = AquaSegmentedControl(glyphs: [.list, .albumList, .grid, .coverFlow])
    private let grid = AlbumGridView()
    private let gridScroll = NSScrollView()

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
    /// Development only: `--source recent` starts on Recently Added.
    var initialSource: String?
    /// Development only: `--curate TEXT` (repeatable) runs the curator on
    /// those turns in order, prints each list, optionally saves the last as
    /// `--curate-save NAME`, then snapshots or quits.
    var curateScript: [String] = []
    var curateSaveName: String?
    private var infoPanel: InfoPanel?          // held while its sheet is up
    private var namePrompt: NamePrompt?        // held while its sheet is up
    private var statusOverride: String?
    private var lastRememberedTrack: String?
    private var restoredLastTrack = false
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
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
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
        toolbar.actsAsTitleBar = true
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
        display.onPlayPause = { [weak self] in self?.player.playPause() }
        display.onAirPlay = { [weak self] sender in self?.showOutputMenu(sender) }
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
        // The field's own cancel button (and Return) send the action, not the
        // text-changed delegate call, so the filter stayed stuck on the old
        // text after the field went blank.
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
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
            (upNextButton, #selector(showUpNext(_:)), "Up Next"),
            (reconnectButton, #selector(reconnect(_:)), "Reconnect to the MacBook Pro and reload everything"),
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
        // Left of where the iPod's Sync and Eject buttons appear.
        connectionBadge.autoresizingMask = [.minXMargin]
        connectionBadge.toolTip = "Working out whether the MacBook Pro is on the local network."
        statusBar.addSubview(connectionBadge)
        libraryStamp.font = Aqua.font(11)
        libraryStamp.textColor = NSColor(white: 0.35, alpha: 1)
        libraryStamp.alignment = .right
        libraryStamp.lineBreakMode = .byClipping
        libraryStamp.autoresizingMask = [.minXMargin]
        statusBar.addSubview(libraryStamp)
        refreshButton.autoresizingMask = [.minXMargin]
        refreshButton.target = self
        refreshButton.action = #selector(refreshLibrary(_:))
        refreshButton.toolTip = "Check the MacBook Pro's library for changes now. Adds and deletes made in iTunes reach the app on their own within a minute or two; this does not wait."
        statusBar.addSubview(refreshButton)
        layoutStatusRight()

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

        rightContainer.frame = NSRect(x: 0, y: 0, width: mainSplit.bounds.width - 191, height: mainSplit.bounds.height)
        rightContainer.autoresizesSubviews = true
        rightSplit.frame = rightContainer.bounds
        rightSplit.autoresizingMask = [.width, .height]
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.delegate = self
        rightContainer.addSubview(rightSplit)
        curatorPage.frame = rightContainer.bounds
        curatorPage.autoresizingMask = [.width, .height]
        curatorPage.isHidden = true
        rightContainer.addSubview(curatorPage)
        wireCurator()
        devicePage.frame = mainSplit.frame
        devicePage.autoresizingMask = [.width, .height]
        devicePage.isHidden = true
        devicePage.onSync = { [weak self] in self?.syncOpenDevice() }
        devicePage.onPlanEdit = { [weak self] row, on in self?.editDevicePlan(row, on) }
        devicePage.onApplyPlan = { [weak self] in self?.applyDevicePlan() }
        devicePage.onEject = { [weak self] in self?.ejectOpenDevice() }
        devicePage.onDone = { [weak self] in
            self?.closeDevicePage()
            self?.selectSourceRow(forLibrary: true)
        }
        devicePage.loadTracks = { [weak self] playlist, done in
            guard let self = self, let name = self.openDevice, let api = self.controller.api else { done([]); return }
            Task { @MainActor in
                done((try? await api.deviceTracks(name, playlist: playlist, limit: 2000)) ?? [])
            }
        }
        devicePage.loadImage = { [weak self] done in
            guard let self = self, let name = self.openDevice, let api = self.controller.api else { done(nil); return }
            Task { @MainActor in
                done((try? await api.deviceImage(name, size: 128)) ?? nil)
            }
        }
        // The device page takes the whole window below the toolbar, the way
        // iTunes 12 gives a device the run of its content area.
        content.addSubview(devicePage)
        mainSplit.addArrangedSubview(rightContainer)
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
        coverFlow.dragIds = { [weak self] i in self?.albumTrackIds(at: i) ?? [] }
        coverFlow.onToggleFullStage = { [weak self] in self?.toggleFullStage() }
        coverFlow.imageProvider = { [weak self] pid, done in
            guard let self = self else { done(nil); return }
            self.artworkCache.image(for: pid, then: done)
        }
        coverFlow.knownMiss = { [weak self] pid in self?.artworkCache.isKnownMiss(pid) ?? false }
        topPane.addSubview(coverFlow)
        gridScroll.frame = topPane.bounds
        gridScroll.autoresizingMask = [.width, .height]
        gridScroll.hasVerticalScroller = true
        gridScroll.scrollerStyle = .legacy
        gridScroll.verticalScroller = AquaScroller()
        gridScroll.borderType = .lineBorder
        gridScroll.documentView = grid
        gridScroll.isHidden = true
        grid.onSelect = { [weak self] _ in self?.coverSelectionChanged() }
        grid.onOpen = { [weak self] i in self?.playAlbum(at: i) }
        grid.dragIds = { [weak self] i in self?.albumTrackIds(at: i) ?? [] }
        grid.imageProvider = { [weak self] pid, done in
            guard let self = self else { done(nil); return }
            self.artworkCache.image(for: pid, then: done)
        }
        grid.knownMiss = { [weak self] pid in self?.artworkCache.isKnownMiss(pid) ?? false }
        topPane.addSubview(gridScroll)
        rightSplit.addArrangedSubview(topPane)
        let trackScroll = scroll(for: trackTable)
        rightSplit.addArrangedSubview(trackScroll)
        rightSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        rebuildBrowserPanes()

        configureSourceList()
        configureTrackTable()
        mainSplit.adjustSubviews()
        window.initialFirstResponder = trackTable
        // The split view has no real height until the window is on screen, so
        // the divider position must be applied after the first layout pass —
        // including for List view, whose browser otherwise comes up collapsed.
        let saved = ViewMode(rawValue: UserDefaults.standard.integer(forKey: "viewMode")) ?? .list
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if saved == .list {
                self.applyBrowserVisibility()
            } else {
                self.setViewMode(saved, animated: false)
            }
        }
    }

    // MARK: View mode

    private func setViewMode(_ mode: ViewMode, animated: Bool = true) {
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "viewMode")
        viewSwitcher.selectedIndex = mode.segment
        let flow = mode == .coverFlow
        let isGrid = mode == .grid
        browserSplit.isHidden = flow || isGrid
        coverFlow.isHidden = !flow
        gridScroll.isHidden = !isGrid
        fullStage = false
        // Cover Flow and Grid need room; Album List hides the browser; List keeps it short.
        let total = rightSplit.bounds.height
        let top: CGFloat = (flow || isGrid) ? round(total * 0.62) : (mode == .albumList ? 0 : browserHeight)
        rightSplit.setPosition(top, ofDividerAt: 0)
        rightSplit.layoutSubtreeIfNeeded()
        trackTable.floatsGroupRows = false
        trackTable.gridStyleMask = mode == .albumList ? [] : [.solidVerticalGridLineMask]
        if mode == .list {
            albums = []
            refreshRows()
            window?.makeFirstResponder(trackTable)
        } else {
            // The browser's narrowing does not apply here; clear it.
            controller.clearBrowserSelections()
            loadAlbums()
            window?.makeFirstResponder(flow ? coverFlow : (isGrid ? grid : trackTable))
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
                switch viewMode {
                case .coverFlow: coverFlow.albums = list
                case .grid: grid.albums = list
                default: break
                }
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
    private var selectedAlbum: AlbumEntry? {
        switch viewMode {
        case .coverFlow: return albums.indices.contains(coverFlow.selectedIndex) ? albums[coverFlow.selectedIndex] : nil
        case .grid: return grid.selectedIndex.flatMap { albums.indices.contains($0) ? albums[$0] : nil }
        default: return nil
        }
    }

    private func refreshRows() {
        if viewMode == .coverFlow || viewMode == .grid {
            if let a = selectedAlbum {
                let artist = a.artist.lowercased()
                let album = a.album.lowercased()
                rows = controller.tracks.filter {
                    $0.displayArtist.lowercased() == artist && $0.album.lowercased() == album
                }
            } else {
                rows = []
            }
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
        if viewMode == .coverFlow { coverFlow.select(index, animated: false) }
        refreshRows()
        guard let first = rows.first else { return }
        startPlayback(first, playlist: controller.source.playlistId, context: rows)
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

    /// Brings the window back to the track that was playing when it last
    /// closed: selects it and scrolls it into view, without starting playback.
    private func restoreLastTrack() {
        guard !restoredLastTrack else { return }
        restoredLastTrack = true
        guard controller.source.isLibrary,
              let id = UserDefaults.standard.string(forKey: "lastTrackId"),
              let index = rows.firstIndex(where: { $0.persistentId == id }),
              let row = tableRow(forTrackIndex: index) else { return }
        trackTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Land it a little below the top rather than flush against the header.
        trackTable.scrollRowToVisible(min(rows.count - 1, row + 8))
        trackTable.scrollRowToVisible(row)
        let name = UserDefaults.standard.string(forKey: "lastTrackName") ?? rows[index].name
        flashStatus("Back where you left off: \(name)")
    }

    // MARK: Drag and drop

    /// Tracks dragged out of the track table carry their persistent IDs.
    static let trackDragType = NSPasteboard.PasteboardType("local.stevenbleifer.itunesremote.track")

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard Tag(rawValue: tableView.tag) == .tracks, row >= 0, row < displayRows.count else { return nil }
        let item = NSPasteboardItem()
        switch displayRows[row] {
        case .track(let index):
            item.setString(rows[index].persistentId, forType: MainWindowController.trackDragType)
            // A plain-text flavour too, so dropping into a text field or another
            // app gives something readable rather than nothing.
            item.setString(rows[index].name + " — " + rows[index].artist, forType: .string)
        case .group(let entry):
            // An album header in Album List drags the whole album.
            let ids = albumTrackIds(entry)
            guard !ids.isEmpty else { return nil }
            item.setString(ids.joined(separator: "\n"), forType: MainWindowController.trackDragType)
            item.setString(entry.title + " — " + entry.artistName, forType: .string)
        }
        return item
    }

    /// The tracks of one album, matched the way the album views match them.
    private func albumTrackIds(_ a: AlbumEntry) -> [String] {
        let artist = a.artist.lowercased(), album = a.album.lowercased()
        return controller.tracks.filter {
            $0.displayArtist.lowercased() == artist && $0.album.lowercased() == album
        }.map { $0.persistentId }
    }

    /// What a cover dragged out of Grid or Cover Flow carries.
    private func albumTrackIds(at index: Int) -> [String] {
        albums.indices.contains(index) ? albumTrackIds(albums[index]) : []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard Tag(rawValue: tableView.tag) == .source,
              info.draggingPasteboard.canReadItem(withDataConformingToTypes: [MainWindowController.trackDragType.rawValue]),
              row >= 0, row < sourceRows.count else { return [] }
        switch sourceRows[row] {
        case .playlist(let p) where !p.smart && !p.folder:
            tableView.setDropRow(row, dropOperation: .on)
            return .copy
        case .device:
            tableView.setDropRow(row, dropOperation: .on)
            return .copy
        default:
            // Smart playlists are defined by their rules; the library and
            // Recently Added already hold everything.
            return []
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard Tag(rawValue: tableView.tag) == .source, row >= 0, row < sourceRows.count else { return false }
        // One item per dragged row; an album header packs its tracks into one.
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).flatMap {
            ($0.string(forType: MainWindowController.trackDragType) ?? "")
                .split(separator: "\n").map(String.init)
        }
        guard !ids.isEmpty else { return false }
        switch sourceRows[row] {
        case .playlist(let p):
            addTracks(ids, toPlaylist: p)
            return true
        case .device(let d):
            copyTracks(ids, toDevice: d)
            return true
        default:
            return false
        }
    }

    private func addTracks(_ ids: [String], toPlaylist playlist: Playlist) {
        guard let api = controller.api else { return }
        flashStatus("Adding \(ids.count) track\(ids.count == 1 ? "" : "s") to \(playlist.name)…")
        Task { @MainActor in
            do {
                let change = try await api.addToPlaylist(playlist.persistentId, ids: ids)
                flashStatus(change.summary("Added") + " to \(playlist.name).")
                await reloadPlaylists()
                if controller.source.playlistId == playlist.persistentId { controller.reload() }
            } catch {
                flashStatus("Could not add to \(playlist.name): \(error.localizedDescription)")
            }
        }
    }

    private func copyTracks(_ ids: [String], toDevice device: DeviceSource) {
        guard let api = controller.api else { return }
        flashStatus("Copying \(ids.count) track\(ids.count == 1 ? "" : "s") to \(device.name)…")
        Task { @MainActor in
            do {
                let result = try await api.copyToDevice(device.name, ids: ids)
                if let reason = result.reason {
                    // iTunes refuses copies onto a device that syncs selected
                    // playlists. Say which setting, not just "it failed".
                    self.report(title: "\(device.name) does not accept dropped tracks", message: reason)
                    self.flashStatus("iTunes refused the copy.")
                } else if result.failed.isEmpty {
                    self.flashStatus("Copied \(result.added.count) to \(device.name).")
                } else {
                    self.flashStatus("Copied \(result.added.count) of \(ids.count); \(result.failed.count) failed.")
                }
            } catch {
                self.flashStatus("Could not copy to \(device.name): \(error.localizedDescription)")
            }
        }
    }

    /// A plain sheet for something the status line is too small to explain.
    private func report(title: String, message: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func configureSourceList() {
        sourceList.registerForDraggedTypes([MainWindowController.trackDragType])
        sourceList.tag = Tag.source.rawValue
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        c.resizingMask = .autoresizingMask
        sourceList.addTableColumn(c)
        AquaTables.style(sourceList, rowHeight: 20, background: Aqua.sidebarBackground, header: false)
        sourceList.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sourceList.dataSource = self
        sourceList.delegate = self
        // Shift- and command-click gather several playlists so one Delete, or
        // one drag, covers the lot. Only playlists join a multiple selection;
        // see selectionIndexesForProposedSelection below.
        sourceList.allowsMultipleSelection = true
        sourceList.enclosingScrollView?.backgroundColor = Aqua.sidebarBackground
        sourceList.target = self
        sourceList.doubleAction = #selector(sourceDoubleClicked(_:))

        let menu = NSMenu()
        menu.delegate = self
        sourceList.menu = menu
        sourceMenu = menu
    }

    /// Every optional column, in the order iTunes listed them.
    static let optionalColumns: [(String, String)] = [
        ("artist", "Artist"), ("album", "Album"), ("genre", "Genre"), ("rating", "Rating"),
        ("playCount", "Plays"), ("dateAdded", "Date Added"), ("year", "Year"),
        ("trackNumber", "Track #"), ("discNumber", "Disc #"), ("composer", "Composer"),
        ("grouping", "Grouping"), ("bpm", "BPM"), ("kind", "Kind"),
    ]

    private func hiddenColumns() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenColumns") ?? ["discNumber", "composer", "grouping", "bpm", "kind"])
    }

    private func applyColumnVisibility() {
        let hidden = hiddenColumns()
        for column in trackTable.tableColumns {
            let id = column.identifier.rawValue
            guard MainWindowController.optionalColumns.contains(where: { $0.0 == id }) else { continue }
            column.isHidden = hidden.contains(id)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var hidden = hiddenColumns()
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        UserDefaults.standard.set(Array(hidden), forKey: "hiddenColumns")
        applyColumnVisibility()
    }

    /// Built fresh whenever the header's menu or the View menu opens.
    func buildColumnMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // A playlist's own order carries meaning that no column reproduces, so
        // there has to be a way back to it after sorting by one.
        let sorted = !trackTable.sortDescriptors.isEmpty
        let backTo: String
        switch controller.source {
        case .playlist: backTo = "Restore Playlist Order"
        case .recentlyAdded: backTo = "Restore Newest First"
        case .library: backTo = "Restore Default Order"
        }
        let reset = NSMenuItem(title: backTo, action: sorted ? #selector(resetSort(_:)) : nil, keyEquivalent: "")
        reset.target = self
        reset.isEnabled = sorted
        reset.attributedTitle = NSAttributedString(string: backTo, attributes: [
            .font: Aqua.font(13),
            .foregroundColor: sorted ? NSColor.controlTextColor : NSColor.disabledControlTextColor,
        ])
        menu.addItem(reset)
        menu.addItem(.separator())

        let hidden = hiddenColumns()
        for (id, title) in MainWindowController.optionalColumns {
            let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = hidden.contains(id) ? .off : .on
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: Aqua.font(13)])
            menu.addItem(item)
        }
    }

    /// Drops the column sort and puts the list back the way the daemon
    /// delivers it — playlist order for a playlist, which is the order that
    /// cannot be reconstructed from any column.
    @objc func resetSort(_ sender: Any?) {
        trackTable.sortDescriptors = []
        controller.setSort(key: nil, ascending: true)
        // setSort only re-sorts what is in memory, and the original order is
        // gone once a column has reordered it, so ask for the list again.
        controller.reload()
        trackTable.headerView?.needsDisplay = true
        flashStatus("Sort cleared.")
    }

    private func configureTrackTable() {
        trackTable.tag = Tag.tracks.rawValue
        // Tracks can be dragged onto a playlist or onto the iPod in the
        // source list.
        trackTable.setDraggingSourceOperationMask(.copy, forLocal: true)
        trackTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        trackTable.isGroupRowProvider = { [weak self] row in
            guard let self = self, row < self.displayRows.count, case .group = self.displayRows[row] else { return false }
            return true
        }
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
        trackTable.addTableColumn(AquaTables.column("dateAdded", title: "Date Added", width: 96, min: 70))
        trackTable.addTableColumn(AquaTables.column("year", title: "Year", width: 48, min: 40, rightAligned: true))
        trackTable.addTableColumn(AquaTables.column("trackNumber", title: "Track #", width: 64, min: 40, rightAligned: true))
        AquaTables.style(trackTable, rowHeight: 18, header: true)
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        trackTable.headerView?.menu = headerMenu
        columnMenu = headerMenu
        applyColumnVisibility()
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
        for (title, sel) in [("Play Next", #selector(playNext(_:))), ("Add to Up Next", #selector(addToUpNext(_:)))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: Aqua.font(13)])
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from Playlist", action: #selector(removeFromPlaylist(_:)), keyEquivalent: "")
        remove.target = self
        remove.attributedTitle = NSAttributedString(string: "Remove from Playlist", attributes: [.font: Aqua.font(13)])
        menu.addItem(remove)
        removeFromPlaylistItem = remove
        menu.addItem(.separator())
        let addPod = NSMenuItem(title: "Add to iPod", action: nil, keyEquivalent: "")
        addPod.attributedTitle = NSAttributedString(string: "Add to iPod", attributes: [.font: Aqua.font(13)])
        addPod.submenu = NSMenu()
        menu.addItem(addPod)
        addToIPodItem = addPod
        let removePod = NSMenuItem(title: "Remove from iPod", action: nil, keyEquivalent: "")
        removePod.attributedTitle = NSAttributedString(string: "Remove from iPod", attributes: [.font: Aqua.font(13)])
        removePod.submenu = NSMenu()
        menu.addItem(removePod)
        removeFromIPodItem = removePod
        menu.delegate = self
        trackTable.menu = menu
    }

    // MARK: Controller wiring

    private func wireController() {
        controller.onPlaylistsChanged = { [weak self] in self?.reloadSourceList() }
        controller.onBrowserChanged = { [weak self] in self?.reloadBrowser() }
        controller.onTracksChanged = { [weak self] in
            guard let self = self else { return }
            // Every view but the plain list is driven by the album list, so it
            // has to be refetched whenever the track set changes.
            if self.viewMode == .list {
                self.refreshRows()
            } else {
                self.loadAlbums()
            }
            self.updateArtwork()
        }
        controller.onStatusChanged = { [weak self] in self?.updateStatus() }
        controller.onFirstLoad = { [weak self] in self?.firstLoadDone() }
        player.onChange = { [weak self] in self?.updatePlayerUI() }
        player.onOutputsChanged = { [weak self] in self?.updateAirPlayButton() }
        player.onError = { [weak self] message in self?.flashStatus(message) }
        player.onLocalTrackFinished = { [weak self] in self?.step(by: 1) }
        player.onRemoteTrackFinished = { [weak self] in self?.step(by: 1) }
        player.onSyncProgress = { [weak self] p in self?.showSyncProgress(p) }
        display.onCycleMode = { [weak self] mode in
            guard let self = self else { return }
            // Cycling by hand pins the choice; the automatic switch only
            // happens on a job starting or finishing. Once the job is over
            // and the song is back on screen, the arrows have done their job.
            self.syncViewPinned = true
            if mode == .player, self.player.syncProgress?.active != true {
                self.display.modes = [.player]
            }
        }
        // The Mac's media keys go to whichever app here is the "now playing"
        // app, so the app claims that role and forwards them on.
        mediaKeys.onTogglePlayPause = { [weak self] in self?.player.playPause() }
        mediaKeys.onPlay = { [weak self] in self?.player.playPause() }
        mediaKeys.onPause = { [weak self] in self?.player.playPause() }
        mediaKeys.onNext = { [weak self] in self?.step(by: 1) }
        mediaKeys.onPrevious = { [weak self] in self?.previousPressed() }
        mediaKeys.onSeek = { [weak self] seconds in self?.player.seek(to: seconds) }
        mediaKeys.start()
        updateStatus()
    }

    // MARK: Restarting iTunes

    /// For the iPod that is plugged in but never mounts and never shows up:
    /// iTunes 12.9.5 stops handling devices after an eject that timed out,
    /// and only a restart of iTunes clears it. Playback on the MacBook Pro
    /// stops; this Mac's playback carries on.
    @objc func restartITunes(_ sender: Any?) {
        guard let api = controller.api, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Restart iTunes on the MacBook Pro?"
        alert.informativeText = "Use this when the iPod is plugged in but never appears. Playback on the MacBook Pro stops; it takes about half a minute to come back."
        alert.addButton(withTitle: "Restart iTunes")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.flashStatus("Restarting iTunes on the MacBook Pro…")
            Task { @MainActor in
                do {
                    try await api.restartITunes()
                    self.flashStatus("iTunes restarted. Looking for the iPod…")
                    try? await Task.sleep(nanoseconds: 40_000_000_000)
                    self.loadDevices()
                    await self.player.refresh()
                } catch {
                    self.flashStatus("Restart failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Home or away

    /// Polling cadence. Away, every request crosses the tunnel, so the
    /// background readers slow down; the things you click stay immediate.
    private var deviceInterval: TimeInterval = 30
    private var alertInterval: TimeInterval = 5
    private(set) var away = false
    private var connectionMonitor: ConnectionMonitor?
    /// Where the API was pointed when it connected: the tunnel name.
    private var awayURL: URL?

    /// Probes the LAN name and switches the API between it and the tunnel
    /// name as the answer changes, so the app is on the fast path at home
    /// and still works everywhere else without touching a setting.
    func startConnectionMonitor(lanURL: URL, token: String) {
        let m = ConnectionMonitor(lanURL: lanURL, token: token)
        m.onChange = { [weak self] mode in self?.applyConnection(mode) }
        connectionMonitor = m
        m.start()
    }

    private func applyConnection(_ mode: ConnectionMonitor.Mode) {
        guard let api = controller.api, let monitor = connectionMonitor else { return }
        let isAway = mode == .away
        api.baseURL = isAway ? (awayURL ?? api.baseURL) : monitor.lanURL
        away = isAway
        player.away = isAway
        controller.versionInterval = isAway ? 60 : 15
        deviceInterval = isAway ? 90 : 30
        alertInterval = isAway ? 15 : 5
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: deviceInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadDevices() }
        }
        startAlertPolling()
        flashStatus(isAway ? "Away — connected through Tailscale."
                           : "Home — connected on the local network.")
        connectionBadge.link = monitor.link
        showConnectionBadge(isAway ? .away : .home, host: api.baseURL.host ?? "")
        // If the first load failed before the right host was known (Tailscale
        // off at home, say), ask again now that it is.
        if controller.info == nil { controller.connect(api) }
    }

    /// The right end of the status bar: the badge against the iPod buttons'
    /// space, the library stamp to its left. Both change width, so both are
    /// placed together whenever either changes.
    private func layoutStatusRight() {
        let W = statusBar.bounds.width
        let bs = connectionBadge.intrinsicContentSize
        connectionBadge.frame = NSRect(x: W - 84 - bs.width, y: 4, width: bs.width, height: bs.height)
        let sw = ceil((libraryStamp.stringValue as NSString).size(withAttributes: [.font: Aqua.font(11)]).width) + 4
        libraryStamp.frame = NSRect(x: connectionBadge.frame.minX - 16 - sw, y: 4, width: sw, height: 16)
        refreshButton.frame = NSRect(x: libraryStamp.frame.minX - 6 - 34, y: 2, width: 34, height: 20)
    }

    @objc private func refreshLibrary(_ sender: Any?) {
        guard controller.api != nil else { return }
        refreshButton.isEnabled = false
        statusOverride = "Asking the MacBook Pro to re-read its library…"
        updateStatus()
        Task { @MainActor in
            let reloaded = await controller.refreshNow()
            refreshButton.isEnabled = true
            statusOverride = nil
            if reloaded, let info = controller.info {
                flashStatus("Library re-read: \(info.trackCount.formatted()) songs.")
            } else if let info = controller.info, let written = MainWindowController.parseISO(info.xmlWrittenAt) {
                let f = DateFormatter()
                f.dateStyle = Calendar.current.isDateInToday(written) ? .none : .medium
                f.timeStyle = .short
                flashStatus("Nothing new — iTunes last saved its library at \(f.string(from: written)).")
            }
            updateLibraryStamp()
            if curatorOpen { loadCuratorLibrary() }
        }
    }

    private func showConnectionBadge(_ state: AquaConnectionBadge.State, host: String) {
        connectionBadge.state = state
        layoutStatusRight()
        switch state {
        case .connecting: connectionBadge.toolTip = "Working out whether the MacBook Pro is on the local network."
        case .home: connectionBadge.toolTip = "Connected on the local network: \(host)"
            + (connectionBadge.link.isEmpty ? "" : " over \(connectionBadge.link)") + ". Every request goes straight to the MacBook Pro."
        case .away: connectionBadge.toolTip = "Connected through the Tailscale tunnel: \(host). The local network did not answer; polling is slower."
        }
    }

    func connect(_ api: APIClient) {
        awayURL = api.baseURL
        controller.connect(api)
        player.api = api
        artworkCache.api = api
        artworkCache.clear()
        player.start()
        loadDevices()
        startAlertPolling()
        deviceTimer?.invalidate()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: deviceInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadDevices() }
        }
        // With one host configured there is nothing to probe: it is home.
        showConnectionBadge(.connecting, host: "")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.connectionMonitor == nil else { return }
            self.showConnectionBadge(.home, host: api.baseURL.host ?? "")
        }
    }

    // MARK: Devices

    // MARK: iTunes' own alerts

    /// The alert currently on screen here, so the same iTunes dialog is not
    /// presented twice, and a new one replaces it.
    private var shownAlert: ITunesAlert?
    private var alertSheet: NSAlert?
    private var alertPollInFlight = false

    private func startAlertPolling() {
        alertTimer?.invalidate()
        alertTimer = Timer.scheduledTimer(withTimeInterval: alertInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAlert() }
        }
    }

    /// iTunes runs headless on the MacBook Pro, so a modal dialog there stops
    /// everything and nobody sees it. Poll for one and show it here.
    private func pollAlert() {
        guard let api = controller.api, !alertPollInFlight else { return }
        alertPollInFlight = true
        Task { @MainActor in
            defer { self.alertPollInFlight = false }
            guard let result = try? await api.itunesAlert() else { return }
            guard let alert = result.alert else {
                // It went away — dismissed in iTunes, or by us.
                if self.shownAlert != nil { self.closeAlertSheet() }
                return
            }
            guard alert != self.shownAlert else { return }
            self.showITunesAlert(alert)
        }
    }

    private func closeAlertSheet() {
        shownAlert = nil
        if let window = window, let sheet = window.attachedSheet, alertSheet != nil {
            window.endSheet(sheet)
        }
        alertSheet = nil
    }

    private func showITunesAlert(_ alert: ITunesAlert) {
        guard let window = window else { return }
        closeAlertSheet()
        shownAlert = alert
        let sheet = NSAlert()
        sheet.messageText = "iTunes on the MacBook Pro is asking something"
        sheet.informativeText = alert.message.isEmpty
            ? "iTunes is showing a dialog with no text." : alert.message
        sheet.alertStyle = .warning
        // The dialog's own buttons, in its own order, so clicking one here
        // does exactly what clicking it there would.
        let buttons = alert.buttons.isEmpty ? ["OK"] : alert.buttons
        for title in buttons { sheet.addButton(withTitle: title) }
        sheet.addButton(withTitle: "Leave It")
        alertSheet = sheet
        sheet.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            self.alertSheet = nil
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < buttons.count, let api = self.controller.api else { return }
            let title = buttons[index]
            Task { @MainActor in
                do {
                    try await api.dismissITunesAlert(button: title)
                    self.flashStatus("Clicked “\(title)” in iTunes.")
                    self.shownAlert = nil
                } catch {
                    self.flashStatus("Could not click “\(title)”: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadDevices() {
        guard let api = controller.api else { return }
        Task { @MainActor in
            // /api/devices, not /api/sources: it also reports an iPhone or
            // iPad sitting on the USB bus that iTunes has not opened as a
            // source, so the device still gets a row and a page that explains
            // itself rather than silently not appearing.
            guard let list = try? await api.devices() else { return }
            if list != devices {
                devices = list
                reloadSourceList()
                if let open = openDevice, !list.contains(where: { $0.name == open }) {
                    closeDevicePage()
                    selectSourceRow(forLibrary: true)
                } else if openDevice != nil {
                    refreshDevicePage()
                }
            }
            let ipods = list.filter { $0.isIPod }
            syncButton.isHidden = ipods.isEmpty
            ejectButton.isHidden = ipods.isEmpty
            loadSyncedPlaylists()
        }
    }

    // MARK: Device page

    /// Selecting a device in the source list replaces the browser and track
    /// table with its page, the way iTunes did.
    private func openDevicePage(for device: DeviceSource) {
        openDevice = device.name
        devicePage.isHidden = false
        devicePage.frame = mainSplit.frame
        mainSplit.isHidden = true
        window?.makeFirstResponder(devicePage)
        devicePage.setStatus("Reading \(device.name) from iTunes…")
        devicePage.setBusy(true)
        refreshDevicePage()
        // Free space and item counts change while a sync runs, so keep
        // reading rather than showing whatever was true when the page opened.
        devicePageTimer?.invalidate()
        devicePageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevicePage() }
        }
    }

    private func closeDevicePage() {
        guard openDevice != nil else { return }
        openDevice = nil
        musicListsLoadedFor = nil
        devicePageTimer?.invalidate()
        devicePageTimer = nil
        devicePage.isHidden = true
        mainSplit.isHidden = false
    }

    /// The four lists on the Music pane. Fetched once per device: the device
    /// side costs iTunes about a second, and the library side is large.
    private var musicListsLoadedFor: String?

    private func loadDeviceMusicLists() {
        guard let name = openDevice, let api = controller.api, musicListsLoadedFor != name else { return }
        musicListsLoadedFor = name
        Task { @MainActor in
            async let facetsTask = api.deviceFacets(name)
            async let artistsTask = api.facet("artist", filter: TrackFilter())
            async let genresTask = api.facet("genre", filter: TrackFilter())
            async let albumsTask = api.albumList(filter: TrackFilter())
            // The plan is the app's own, so a device with none yet is normal
            // and must not stop the lists from being shown.
            async let planTask = try? api.syncPlan()
            guard let facets = try? await facetsTask,
                  let artists = try? await artistsTask,
                  let genres = try? await genresTask,
                  let albums = try? await albumsTask else {
                self.musicListsLoadedFor = nil          // let it try again
                return
            }
            let reply = await planTask
            guard self.openDevice == name else { return }
            self.devicePlan = reply?.plan
            self.devicePage.showMusicLibrary(
                playlists: self.controller.playlists,
                artists: artists.map { $0.name },
                genres: genres.map { $0.name },
                albums: albums,
                plan: reply?.plan,
                planCount: reply?.status?.trackCount,
                device: facets)
        }
    }

    /// The plan the Music pane is ticking, so a toggle knows which device it
    /// belongs to even if the iPod is unplugged mid-edit.
    private var devicePlan: SyncPlan?

    /// Records one tick. Nothing reaches iTunes until Apply.
    private func editDevicePlan(_ row: DeviceMusicView.Row, _ on: Bool) {
        guard let api = controller.api else { return }
        let device = devicePlan?.device
        Task { @MainActor in
            do {
                let reply = try await api.syncToggle(device: device, kind: row.kind.rawValue,
                                                     value: row.planValue, on: on)
                self.devicePlan = reply.plan ?? self.devicePlan
                self.devicePage.setPlanCount(reply.status?.trackCount)
                let n = reply.plan.map { p in
                    p.selections.playlist.count + p.selections.artist.count
                        + p.selections.albumartist.count + p.selections.genre.count
                        + p.selections.album.count
                } ?? 0
                self.devicePage.setStatus("\(on ? "Added" : "Removed") \(row.name). "
                    + "\(n) selections — press Apply to write them to iTunes.")
            } catch {
                // Put the tick back: the plan did not change.
                self.musicListsLoadedFor = nil
                self.loadDeviceMusicLists()
                self.devicePage.setStatus("Could not change \(row.name): \(error.localizedDescription)")
            }
        }
    }

    /// iTunes' Apply: writes the plan into the playlist the iPod syncs. This
    /// rewrites that one playlist and touches nothing else in the library.
    private func applyDevicePlan() {
        guard let api = controller.api else { return }
        let device = devicePlan?.device
        devicePage.setBusy(true)
        devicePage.setStatus("Writing the sync playlist in iTunes… this takes a few minutes for a large selection.")
        player.watchSync()
        Task { @MainActor in
            do {
                let reply = try await api.syncRebuild(device: device)
                self.devicePlan = reply.plan ?? self.devicePlan
                self.devicePage.setPlanCount(reply.status?.trackCount)
                self.devicePage.planApplied()
                let name = reply.plan?.playlistName ?? "the sync playlist"
                let n = reply.status?.playlistTrackCount ?? 0
                self.devicePage.setStatus("\(name) now holds "
                    + "\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal))"
                    + " tracks. Sync the iPod to send them.")
                self.flashStatus("Sync playlist updated.")
            } catch {
                self.devicePage.setStatus("Apply failed: \(error.localizedDescription)")
            }
            self.devicePage.setBusy(false)
        }
    }

    private func refreshDevicePage() {
        guard let name = openDevice, let api = controller.api, !deviceReadInFlight else { return }
        deviceReadInFlight = true
        Task { @MainActor in
            defer { self.deviceReadInFlight = false }
            do {
                let detail = try await api.deviceDetail(name)
                // The user may have moved on while iTunes was answering.
                guard self.openDevice == name else { return }
                self.devicePage.show(detail)
                self.devicePage.setRead(at: Date())
                self.loadDeviceMusicLists()
            } catch {
                guard self.openDevice == name else { return }
                self.devicePage.setStatus("Could not read \(name): \(error.localizedDescription)")
                self.devicePage.setBusy(false)
            }
        }
    }

    private func syncOpenDevice() {
        guard let name = openDevice, let api = controller.api else { return }
        devicePage.setBusy(true)
        devicePage.setStatus("Syncing \(name)…")
        player.watchSync()
        Task { @MainActor in
            do {
                try await api.syncSource(name)
                self.devicePage.setStatus("Sync started on \(name). iTunes reports no progress; the page will show the new totals once it finishes.")
                self.flashStatus("Sync started on \(name).")
            } catch {
                self.devicePage.setStatus("Sync failed: \(error.localizedDescription)")
            }
            self.devicePage.setBusy(false)
            self.refreshDevicePage()
        }
    }

    private func ejectOpenDevice() {
        guard let name = openDevice, let api = controller.api else { return }
        devicePage.setBusy(true)
        devicePage.setStatus("Ejecting \(name)…")
        // Stop reading the device: iTunes cannot unmount a volume this app is
        // still asking about, and reports that as "in use by another
        // application".
        stopDevicePolling()
        Task { @MainActor in
            do {
                try await api.ejectSource(name)
                self.flashStatus("Ejected \(name).")
                self.devices.removeAll { $0.name == name }
                self.closeDevicePage()
                self.reloadSourceList()
                self.selectSourceRow(forLibrary: true)
                self.syncButton.isHidden = self.devices.isEmpty
                self.ejectButton.isHidden = self.devices.isEmpty
            } catch {
                self.devicePage.setStatus("Eject failed: \(error.localizedDescription)")
                self.devicePage.setBusy(false)
                self.resumeDevicePolling()
            }
        }
    }

    /// Pauses the 15-second device refresh, so nothing touches the iPod
    /// while iTunes is trying to unmount it.
    private func stopDevicePolling() {
        devicePageTimer?.invalidate()
        devicePageTimer = nil
        deviceTimer?.invalidate()
        deviceTimer = nil
    }

    private func resumeDevicePolling() {
        if openDevice != nil, devicePageTimer == nil {
            devicePageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshDevicePage() }
            }
        }
        if deviceTimer == nil {
            deviceTimer = Timer.scheduledTimer(withTimeInterval: deviceInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.loadDevices() }
            }
        }
    }

    /// After ejecting there is no device row left to keep selected.
    private func selectSourceRow(forLibrary: Bool) {
        guard forLibrary else { return }
        for (i, row) in sourceRows.enumerated() {
            if case .library = row {
                updatingUI = true
                sourceList.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                updatingUI = false
                controller.source = .library
                return
            }
        }
    }

    // MARK: Curator

    private func wireCurator() {
        curatorPage.modelLine = "Powered by \(curator.model) on \(OllamaRuntime.shared.description) · library search: \(CuratorEngine.embedModel)"
        curatorPage.onAsk = { [weak self] text in Task { @MainActor in await self?.askCurator(text) } }
        curatorPage.onPlay = { [weak self] tracks, i in
            guard let self = self, i < tracks.count else { return }
            self.startPlayback(tracks[i], playlist: nil, context: tracks)
            self.playContextName = "Curator"
        }
        curatorPage.onSave = { [weak self] tracks, name in self?.saveCurated(tracks, suggestedName: name) }
        curatorPage.onNew = { [weak self] in self?.curator.reset() }
        curatorPage.onEdited = { [weak self] picks in self?.curator.setCurrent(picks) }
        curator.onStatus = { [weak self] s in self?.curatorPage.setStatus(s) }
        curator.onIndexProgress = { [weak self] done, total in
            guard let self = self else { return }
            if done < total {
                self.curatorPage.setIndexing("Indexing for search: \(done.formatted()) of \(total.formatted()) songs")
            } else {
                self.curatorPage.setIndexing(nil)
            }
        }
    }

    /// Selecting the curator in the sidebar swaps the browser and track
    /// table for its page; the sidebar and the player stay.
    private func openCuratorPage() {
        closeDevicePage()
        curatorOpen = true
        Task { @MainActor in
            _ = await OllamaRuntime.shared.ensureRunning()
            curatorPage.modelLine = "Powered by \(curator.model) on \(OllamaRuntime.shared.description) · library search: \(CuratorEngine.embedModel)"
        }
        rightSplit.isHidden = true
        curatorPage.isHidden = false
        curatorPage.focusField()
        loadCuratorLibrary()
    }

    private func closeCuratorPage() {
        guard curatorOpen else { return }
        curatorOpen = false
        curatorPage.isHidden = true
        rightSplit.isHidden = false
    }

    @objc func showCurator(_ sender: Any?) {
        guard let i = sourceRows.firstIndex(where: { if case .curator = $0 { return true }; return false }) else { return }
        sourceList.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The whole library, once per version of it, for the artist table and
    /// the search index. The read is cached, so after the Music list has
    /// loaded it costs nothing.
    private func loadCuratorLibrary() {
        guard let api = controller.api else { return }
        Task { @MainActor in
            do {
                let info = try await api.libraryInfo()
                guard info.contentVersion != curatorLibraryVersion else { return }
                let page = try await api.tracks(filter: TrackFilter())
                curatorLibraryVersion = info.contentVersion
                curator.setLibrary(page.tracks)
            } catch {
                curatorPage.note("Could not read the library: \(error.localizedDescription)")
            }
        }
    }

    private func askCurator(_ text: String) async {
        curatorPage.setBusy(true)
        curatorPage.say(listener: text)
        do {
            let reply = try await curator.ask(text)
            curatorPage.show(reply)
        } catch {
            curatorPage.note("Sorry — \(error.localizedDescription)")
        }
        curatorPage.setBusy(false)
    }

    /// The headless run behind `--curate`, for testing the curator and for
    /// screenshots with a real list on the page.
    private func runCurateScript() {
        window?.makeKeyAndOrderFront(nil)
        showCurator(nil)
        Task { @MainActor in
            var waited = 0
            while !curator.libraryLoaded && waited < 240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
            }
            for text in curateScript {
                print("> \(text)")
                await askCurator(text)
                for (i, p) in curatorPage.picks.enumerated() {
                    print("\(i + 1). \(p.track.artist) – \(p.track.name) (\(p.track.album)) [\(p.why)]")
                }
                print("--")
            }
            if let name = curateSaveName, let api = controller.api, !curatorPage.picks.isEmpty {
                do {
                    let playlist = try await api.createPlaylist(name: name, folder: "Curator")
                    let change = try await api.addToPlaylist(playlist.persistentId, ids: curatorPage.picks.map { $0.track.persistentId })
                    print("saved \(playlist.name) (\(playlist.persistentId)) parent=\(playlist.parentId ?? "-") added=\(change.changed)")
                    curatorPage.note("Saved as “\(playlist.name)” in the Curator folder, \(change.changed) songs.")
                    if let parent = playlist.parentId { collapsedFolders.remove(parent) }
                    await reloadPlaylists()
                } catch {
                    print("save failed: \(error)")
                }
            }
            // `--stay` leaves the window up and prints its number, so a real
            // screen capture can be taken of it: the offscreen snapshot
            // misses the text in layer-backed AppKit views on this page.
            if CommandLine.arguments.contains("--stay"), let w = window {
                print("window \(w.windowNumber)")
                fflush(stdout)
                return
            }
            if let path = snapshotPath, let content = window?.contentView {
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture(to: path, content: content)
            }
            exit(0)
        }
    }

    /// Saves the list as a real playlist, filed in the Curator folder so the
    /// model's lists never mix with the hand-made ones.
    private func saveCurated(_ tracks: [Track], suggestedName: String) {
        guard let window = window, let api = controller.api, !tracks.isEmpty else { return }
        let prompt = NamePrompt(title: "Save Playlist", prompt: "Name for the playlist (it goes in the Curator folder):",
                                placeholder: "Curated Playlist", acceptTitle: "Save",
                                initialValue: suggestedName.isEmpty ? nil : suggestedName)
        prompt.onAccept = { [weak self] name, done in
            Task { @MainActor in
                do {
                    let playlist = try await api.createPlaylist(name: name, folder: "Curator")
                    let change = try await api.addToPlaylist(playlist.persistentId, ids: tracks.map { $0.persistentId })
                    if let parent = playlist.parentId {
                        self?.collapsedFolders.remove(parent)
                        self?.saveCollapsedFolders()
                    }
                    self?.curatorPage.note("Saved as “\(playlist.name)” in the Curator folder, \(change.changed) songs.")
                    self?.flashStatus(change.summary("Added"))
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

    // MARK: Folders

    private func toggleFolder(_ pid: String) {
        if collapsedFolders.contains(pid) { collapsedFolders.remove(pid) } else { collapsedFolders.insert(pid) }
        saveCollapsedFolders()
        reloadSourceList()
    }

    private func saveCollapsedFolders() {
        UserDefaults.standard.set(Array(collapsedFolders), forKey: "collapsedFolders")
    }

    // MARK: Split view

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only the List view's divider is the browser's own height; the other
        // views set it themselves.
        guard (notification.object as? NSSplitView) === rightSplit,
              viewMode == .list, !browserSplit.isHidden else { return }
        let h = topPane.frame.height
        guard h >= 60, abs(h - browserHeight) > 0.5 else { return }
        browserHeight = h
        UserDefaults.standard.set(Double(h), forKey: "browserHeight")
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
        ejectButton.isEnabled = false
        flashStatus("Ejecting \(device.name)…")
        stopDevicePolling()
        Task { @MainActor in
            do {
                try await api.ejectSource(device.name)
                flashStatus("Ejected \(device.name).")
                devices = []
                reloadSourceList()
                syncButton.isHidden = true
                ejectButton.isHidden = true
            } catch {
                // The iPod is still there. Say why, put the row back, and
                // start reading it again.
                flashStatus("Eject failed: \(error.localizedDescription)")
                self.report(title: "Could not eject \(device.name)",
                            message: error.localizedDescription
                                + "\n\niTunes cannot unmount the iPod while anything on the MacBook Pro "
                                + "still has a file open on it. Try again in a few seconds; if it keeps "
                                + "failing, eject it from the Finder on that machine.")
                self.loadDevices()
            }
            self.ejectButton.isEnabled = true
            self.resumeDevicePolling()
        }
    }

    // MARK: Bottom bar

    /// Drops everything and asks the daemon again: library, playlists,
    /// devices, player and artwork. For when a request failed and the app is
    /// sitting on a stale or empty view.
    @objc private func reconnect(_ sender: Any?) {
        guard let api = controller.api else { return }
        reconnectButton.isEnabled = false
        flashStatus("Reconnecting to \(api.baseURL.host ?? "the MacBook Pro")…")
        artworkCache.clear()
        controller.connect(api)
        player.api = api
        player.start()
        loadDevices()
        startAlertPolling()
        if openDevice != nil { refreshDevicePage() }
        Task { @MainActor in
            // Give the reloads a moment, then say what actually happened
            // rather than claiming success straight away.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.reconnectButton.isEnabled = true
            if let e = self.controller.lastError {
                self.flashStatus("Still failing: \(e)")
            } else if self.controller.info != nil {
                self.flashStatus("Reconnected.")
            }
        }
    }

    @objc private func toggleShuffle(_ sender: Any?) {
        player.setShuffle(!player.shuffle)
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
                // iTunes 12.9.5 accepts `set enabled` without error and then
                // ignores it, so read the track back rather than trusting the
                // write. If it did not stick, put the box back.
                let fresh = try await api.track(track.persistentId)
                if fresh.enabled == on {
                    controller.setEnabled(track.persistentId, on)
                    refreshRows()
                } else {
                    sender.isOn = !on
                    flashStatus("iTunes 12.9.5 ignores checkbox changes made by script. Turn on Preferences > General > Show list checkboxes in iTunes, or change it there.")
                }
            } catch {
                sender.isOn = !on
                flashStatus("Could not change the checkbox: \(error.localizedDescription)")
            }
        }
    }

    private func reloadSourceList() {
        updatingUI = true
        sourceRows = [.header("LIBRARY"), .library, .recentlyAdded]
        if !devices.isEmpty {
            sourceRows.append(.header("DEVICES"))
            sourceRows += devices.map { .device($0) }
        }
        sourceRows.append(.header("CURATOR"))
        sourceRows.append(.curator)
        sourceRows.append(.header("PLAYLISTS"))
        // Playlists as a tree: a folder's playlists sit under it, stepped in,
        // and stay hidden while it is closed. The daemon lists them flat,
        // sorted by name, so each level keeps that order.
        let known = Set(controller.playlists.map { $0.persistentId })
        var children: [String: [Playlist]] = [:]
        for p in controller.playlists {
            let parent = p.parentId.flatMap { known.contains($0) ? $0 : nil } ?? ""
            children[parent, default: []].append(p)
        }
        // iTunes' XML lists playlists in its own order, folders first; each
        // level here is folders first and then by name, so a new one lands
        // where the eye expects it.
        for key in children.keys {
            children[key]?.sort { a, b in
                if a.folder != b.folder { return a.folder }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        playlistDepth = [:]
        func walk(_ parent: String, _ depth: Int) {
            for p in children[parent] ?? [] {
                sourceRows.append(.playlist(p))
                playlistDepth[p.persistentId] = depth
                if p.folder && !collapsedFolders.contains(p.persistentId) { walk(p.persistentId, depth + 1) }
            }
        }
        walk("", 0)
        sourceList.reloadData()
        var select = 1
        if initialSource == "curator" {
            initialSource = nil
            curatorOpen = true
        }
        if curatorOpen, let i = sourceRows.firstIndex(where: { if case .curator = $0 { return true }; return false }) {
            select = i
            if curatorPage.isHidden { openCuratorPage() }
        } else if controller.source == .recentlyAdded {
            select = 2
        } else if let current = controller.source.playlistId,
                  let i = sourceRows.firstIndex(where: { if case .playlist(let p) = $0 { return p.persistentId == current }; return false }) {
            select = i
        }
        if initialSource == "recent" {
            initialSource = nil
            select = 2
            updatingUI = false
            sourceList.selectRowIndexes(IndexSet(integer: select), byExtendingSelection: false)
            controller.source = .recentlyAdded
            return
        }
        if let wanted = initialSource, wanted.hasPrefix("device:") {
            let name = String(wanted.dropFirst("device:".count))
            for (i, row) in sourceRows.enumerated() {
                guard case .device(let d) = row else { continue }
                if name.isEmpty || d.name == name {
                    initialSource = nil
                    updatingUI = false
                    sourceList.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                    openDevicePage(for: d)
                    return
                }
            }
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
        for (field, table) in browserTables {
            let entries = controller.facet(field)
            table.reloadData()
            var row = 0
            if let s = controller.selection(field), let i = entries.firstIndex(where: { $0.name == s }) { row = i + 1 }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if row > 0 { table.scrollRowToVisible(row) }
        }
        updatingUI = false
    }

    private func updateStatus() {
        statusLabel.stringValue = statusOverride ?? controller.statusText
        updateLibraryStamp()
        updatePlayerUI()
    }

    /// "Library as of 3:41 PM": when iTunes last wrote the library the
    /// MacBook Pro is serving. Adds and deletes made in iTunes itself show
    /// up here a minute or two after they happen; edits made in this app
    /// are applied at once and do not wait for it.
    private func updateLibraryStamp() {
        guard let info = controller.info else {
            libraryStamp.stringValue = ""
            return
        }
        let written = MainWindowController.parseISO(info.xmlWrittenAt)
        let read = MainWindowController.parseISO(info.loadedAt)
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = written.map { Calendar.current.isDateInToday($0) } == true ? .none : .medium
        f.timeStyle = .short
        libraryStamp.stringValue = written.map { "Library as of \(f.string(from: $0))" } ?? ""
        layoutStatusRight()
        let full = DateFormatter()
        full.dateStyle = .medium
        full.timeStyle = .medium
        libraryStamp.toolTip = "iTunes last saved its library " + (written.map { full.string(from: $0) } ?? "?")
            + "; the MacBook Pro read it " + (read.map { full.string(from: $0) } ?? "?")
            + ". The daemon checks the file every 5 seconds and this app asks it every \(Int(controller.versionInterval)) seconds. Changes made from this app show at once."
    }

    static func parseISO(_ iso: String) -> Date? {
        if let d = isoParser.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
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
        panel.knownGenres = controller.facet("genre").map { $0.name }.filter { !$0.isEmpty }
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

    private func clickedPlaylist() -> Playlist? {
        let row = sourceList.clickedRow >= 0 ? sourceList.clickedRow : sourceList.selectedRow
        guard row >= 0, row < sourceRows.count, case .playlist(let p) = sourceRows[row] else { return nil }
        return p
    }

    /// Every playlist a command acts on: the whole selection when the click
    /// landed inside it, and just the clicked row when it landed outside —
    /// the rule the Finder and iTunes both use for right-clicking a list.
    private func targetPlaylists() -> [Playlist] {
        let clicked = sourceList.clickedRow
        let selected = sourceList.selectedRowIndexes
        let rowsToUse: IndexSet
        if clicked >= 0 && !selected.contains(clicked) {
            rowsToUse = IndexSet(integer: clicked)
        } else if selected.isEmpty && clicked >= 0 {
            rowsToUse = IndexSet(integer: clicked)
        } else {
            rowsToUse = selected
        }
        return rowsToUse.compactMap { row in
            guard row >= 0, row < sourceRows.count, case .playlist(let p) = sourceRows[row] else { return nil }
            return p
        }
    }

    /// Of those, the ones iTunes will let go of. Smart playlists are defined
    /// by their rules and are left alone.
    private func deletablePlaylists() -> [Playlist] {
        targetPlaylists().filter { !$0.smart }
    }

    func buildSourceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: Aqua.font(13),
                .foregroundColor: enabled ? NSColor.controlTextColor : NSColor.disabledControlTextColor,
            ])
            menu.addItem(item)
        }
        add("New Playlist…", #selector(newPlaylist(_:)))
        let playlist = clickedPlaylist()
        let editable = playlist != nil && !(playlist!.smart)
        let deletable = deletablePlaylists()
        menu.addItem(.separator())
        // Rename is one playlist at a time; deleting is not.
        add("Rename…", #selector(renamePlaylist(_:)), enabled: editable && deletable.count <= 1)
        let deleteTitle = deletable.count > 1 ? "Delete \(deletable.count) Playlists" : "Delete Playlist"
        add(deleteTitle, #selector(deletePlaylist(_:)), enabled: !deletable.isEmpty)
    }

    @objc func renamePlaylist(_ sender: Any?) {
        guard let playlist = clickedPlaylist(), let window = window, let api = controller.api else { return }
        let prompt = NamePrompt(title: "Rename Playlist", prompt: "New name for “\(playlist.name)”:",
                                placeholder: playlist.name, acceptTitle: "Rename")
        prompt.onAccept = { [weak self] name, done in
            Task { @MainActor in
                do {
                    let updated = try await api.renamePlaylist(playlist.persistentId, name: name)
                    self?.flashStatus("Renamed to \(updated.name).")
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

    @objc func deletePlaylist(_ sender: Any?) {
        let targets = deletablePlaylists()
        guard !targets.isEmpty, let window = window, let api = controller.api else { return }
        // Deleting is not undoable in iTunes, so confirm first — and name what
        // is going, since a shift-click can gather more than the eye expects.
        let songs = targets.reduce(0) { $0 + $1.count }
        let alert = NSAlert()
        if targets.count == 1 {
            alert.messageText = "Delete the playlist “\(targets[0].name)”?"
            alert.informativeText = "The playlist is removed from iTunes. Its \(songs) songs stay in your library."
        } else {
            alert.messageText = "Delete these \(targets.count) playlists?"
            let names = targets.prefix(12).map { "  •  \($0.name)" }.joined(separator: "\n")
            let more = targets.count > 12 ? "\n  …and \(targets.count - 12) more" : ""
            alert.informativeText = "\(names)\(more)\n\nThey are removed from iTunes. Their \(songs) songs stay in your library."
        }
        alert.addButton(withTitle: targets.count == 1 ? "Delete" : "Delete \(targets.count) Playlists")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                guard let self = self else { return }
                var deleted = 0
                var failure: String?
                for playlist in targets {
                    do {
                        try await api.deletePlaylist(playlist.persistentId)
                        deleted += 1
                        if self.controller.source.playlistId == playlist.persistentId {
                            self.controller.source = .library
                        }
                    } catch {
                        // Report the first failure but keep going, so one bad
                        // playlist does not strand the rest of the batch.
                        if failure == nil { failure = "\(playlist.name): \(error.localizedDescription)" }
                    }
                }
                if let failure = failure {
                    self.flashStatus("Deleted \(deleted) of \(targets.count). Failed on \(failure)")
                } else if deleted == 1 {
                    self.flashStatus("Deleted \(targets[0].name).")
                } else {
                    self.flashStatus("Deleted \(deleted) playlists.")
                }
                await self.reloadPlaylists()
            }
        }
    }

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
        guard let playlistId = controller.source.playlistId, let api = controller.api,
              let window = window else { return }
        let selected = selectedTracks
        let ids = selected.map { $0.persistentId }
        guard !ids.isEmpty else { return }
        let name = controller.source.displayName

        // iTunes asked before every playlist removal, and there is no undo on
        // the far end, so ask here too.
        let alert = NSAlert()
        if ids.count == 1 {
            alert.messageText = "Remove “\(selected[0].name)” from \(name)?"
        } else {
            alert.messageText = "Remove these \(ids.count) songs from \(name)?"
        }
        alert.informativeText = "The song\(ids.count == 1 ? "" : "s") stay\(ids.count == 1 ? "s" : "") in your library."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            Task { @MainActor in
                do {
                    let change = try await api.removeFromPlaylist(playlistId, ids: ids)
                    self.flashStatus(change.summary("Removed"))
                    await self.reloadPlaylists()
                    self.controller.reload()
                } catch {
                    self.flashStatus("Remove failed: \(error.localizedDescription)")
                }
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
        startPlayback(first, playlist: controller.source.playlistId, context: rows)
    }

    // MARK: Player UI

    @objc func toggleMiniPlayer(_ sender: Any?) {
        if let mini = miniPlayer, mini.window?.isVisible == true {
            mini.close()
            return
        }
        let mini = miniPlayer ?? MiniPlayerWindowController(player: player)
        mini.onRestore = { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
        mini.onStep = { [weak self] delta in
            if delta < 0 { self?.previousPressed() } else { self?.step(by: delta) }
        }
        mini.onAirPlay = { [weak self] sender in self?.showOutputMenu(sender) }
        miniPlayer = mini
        mini.update()
        if mini.window?.frame.origin == .zero {
            mini.window?.center()
        }
        mini.showWindow(nil)
        mini.window?.makeKeyAndOrderFront(nil)
        window?.orderOut(nil)
    }

    private func updatePlayerUI() {
        miniPlayer?.update()
        let state = player.state
        let playing = state?.isPlaying ?? false
        playButton.glyph = playing ? .pause : .play
        display.isPlaying = playing
        display.airPlayActive = player.nonComputerOutputSelected

        if let t = state?.track, state?.state != "stopped" {
            // Remember it, so the next launch can bring us back to it.
            if t.persistentId != lastRememberedTrack {
                lastRememberedTrack = t.persistentId
                UserDefaults.standard.set(t.persistentId, forKey: "lastTrackId")
                UserDefaults.standard.set(t.name, forKey: "lastTrackName")
            }
            display.duration = t.duration
            display.position = player.displayPosition
            display.primary = t.name
            var parts = [t.artist, t.album].filter { !$0.isEmpty }
            // In local mode the audio comes out of this Mac while iTunes on
            // the MacBook Pro sits paused on whatever it had. Two players,
            // two volumes — say which one this is, or the two windows look
            // like they have simply fallen out of sync.
            if player.mode == .local { parts.append("on this Mac") }
            else if let out = player.selectedOutputName { parts.append("on \(out)") }
            display.secondary = parts.joined(separator: " — ")
        } else {
            display.duration = nil
            display.primary = controller.source.displayName
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
        let stopped = state?.track == nil || state?.state == "stopped"
        // The bold row used to be drawn only when a row happened to be
        // redrawn, so it stuck to the previous song, or a song that had
        // finished, until something else scrolled it. Move it deliberately.
        let boldId = stopped ? nil : state?.track?.persistentId
        if boldId != lastBoldId {
            let moved = [lastBoldId, boldId].compactMap { $0 }
            lastBoldId = boldId
            reloadRows(forTrackIds: moved)
            if upNextPanel?.panel.isVisible == true { refreshUpNext() }
        }
        // The speaker beside the source the music is coming from. iTunes
        // reports the playlist it is playing from; when it reports none —
        // which it does for a one-item queue — fall back to whatever the app
        // last started playback from.
        let nowPlaylist = stopped ? nil : (state?.playlist?.persistentId ?? startedFromPlaylistId)
        if nowPlaylist != playingPlaylistId {
            playingPlaylistId = nowPlaylist
            let visible = sourceList.rows(in: sourceList.visibleRect)
            sourceList.reloadData(forRowIndexes: IndexSet(integersIn: Range(visible) ?? 0..<0),
                                  columnIndexes: IndexSet(integer: 0))
        }
        mediaKeys.publish(title: state?.track?.name, artist: state?.track?.artist,
                          album: state?.track?.album, duration: state?.track?.duration,
                          elapsed: player.displayPosition, playing: playing, stopped: stopped)
        shuffleButton.isOn = state?.shuffle ?? false
        let mode = state?.repeatMode ?? "off"
        repeatButton.glyph = mode == "one" ? .repeatOne : .repeatAll
        repeatButton.isOn = mode != "off"
        let up = player.itunesRunning
        for b in [previousButton, playButton, nextButton] { b.isEnabled = up }
        airPlayButton.isEnabled = up
        updateArtwork()
    }

    /// Every place the window starts a song. Remembers the source so the
    /// sidebar can mark it, since iTunes reports no playlist for the one-item
    /// queue that `play <track>` creates.
    ///
    /// `context` is the list Next and Previous step through from here on: a
    /// snapshot, not the live `rows`. Stepping used to read whatever list was
    /// on screen, so once you clicked away from the album you had started —
    /// another cover, a browser column, the sidebar — the playing song was no
    /// longer in it and Next fell through to iTunes' own Next, which carried
    /// on through the *playlist* iTunes had last been told to play inside.
    /// Pass nil to keep the current context (a queued or searched song).
    private func startPlayback(_ track: Track, playlist: String?, context: [Track]? = nil) {
        if let list = context {
            playContext = list
            playContextPlaylist = playlist
            playContextName = controller.source.displayName
            shuffleHistory.removeAll()
        }
        startedFromPlaylistId = playlist
        player.play(track, playlist: playlist)
    }

    /// The list playback continues through, fixed when it started.
    private var playContext: [Track] = []
    private var playContextPlaylist: String?
    private var playContextName: String?

    // MARK: Up Next

    /// Songs queued ahead of the list. `play <track>` gives iTunes a one-item
    /// queue, so the app has always decided what follows; this is the part of
    /// that decision the user gets to make directly.
    private var upNext: [Track] = []
    private var upNextPanel: UpNextPanel?

    @objc func showUpNext(_ sender: Any?) {
        let p = upNextPanel ?? makeUpNextPanel()
        upNextPanel = p
        refreshUpNext()
        p.show(near: window)
    }

    private func makeUpNextPanel() -> UpNextPanel {
        let p = UpNextPanel()
        p.onQueueChanged = { [weak self] q in
            self?.upNext = q
            self?.refreshUpNext()
        }
        p.onPlayQueued = { [weak self] i in
            guard let self = self, i < self.upNext.count else { return }
            let track = self.upNext[i]
            // Playing something from further down the queue consumes what was
            // ahead of it, the way skipping forward would have.
            self.upNext.removeFirst(i + 1)
            self.startPlayback(track, playlist: self.controller.source.playlistId)
            self.refreshUpNext()
        }
        p.onPlayUpcoming = { [weak self] i in
            guard let self = self else { return }
            let coming = self.upcomingTracks()
            let list = self.playContext.isEmpty ? self.rows : self.playContext
            guard i < coming.count,
                  let j = list.firstIndex(where: { $0.persistentId == coming[i].persistentId })
            else { return }
            self.playInContext(j)
        }
        return p
    }

    /// What the current list would play after the current song, ignoring the
    /// manual queue. Shuffle picks at random each time, so there is no honest
    /// order to show for it.
    private func upcomingTracks(limit: Int = 100) -> [Track] {
        guard !(player.state?.shuffle ?? false) else { return [] }
        let list = playContext.isEmpty ? rows : playContext
        guard let playing = player.state?.track?.persistentId,
              let i = list.firstIndex(where: { $0.persistentId == playing }) else {
            return Array(list.prefix(limit))
        }
        return Array(list.dropFirst(i + 1).prefix(limit))
    }

    private func refreshUpNext() {
        let shuffling = player.state?.shuffle ?? false
        upNextPanel?.update(queue: upNext,
                            upcoming: upcomingTracks(),
                            sourceName: shuffling ? "" : (playContextName ?? controller.source.displayName))
        upNextButton.isOn = !upNext.isEmpty
    }

    /// Puts songs at the front of the queue, or on the end of it.
    @objc func playNext(_ sender: Any?) {
        let picked = selectedTracks
        guard !picked.isEmpty else { return }
        upNext.insert(contentsOf: picked, at: 0)
        refreshUpNext()
        flashStatus(picked.count == 1 ? "Playing “\(picked[0].name)” next."
                                      : "\(picked.count) songs playing next.")
    }

    @objc func addToUpNext(_ sender: Any?) {
        let picked = selectedTracks
        guard !picked.isEmpty else { return }
        upNext.append(contentsOf: picked)
        refreshUpNext()
        flashStatus(picked.count == 1 ? "Added “\(picked[0].name)” to Up Next."
                                      : "Added \(picked.count) songs to Up Next.")
    }

    private var lastBoldId: String?
    /// The playlist the current song is playing from, marked in the sidebar.
    private var playingPlaylistId: String?
    /// What the app itself last asked to play from, for when iTunes reports
    /// no playlist of its own.
    private var startedFromPlaylistId: String?

    // MARK: Sync progress on the LCD

    private var syncViewPinned = false
    private var syncViewTimer: Timer?

    /// Puts the daemon's current write on the display. A job starting flips
    /// the display to the sync view; five seconds after it ends the view goes
    /// away again, unless the arrows were used by hand in between.
    private func showSyncProgress(_ p: SyncProgress) {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        let tracks = p.tracks.map { n.string(from: NSNumber(value: $0)) ?? "\($0)" }
        let label = p.label ?? "iPod"
        if p.active {
            syncViewTimer?.invalidate()
            syncViewTimer = nil
            if p.kind == "rebuild" {
                display.syncTitle = "Writing the sync playlist for “\(label)”…"
                display.syncDetail = "\(p.done ?? 0) of \(p.total ?? 0) selections"
                    + (tracks.map { " — \($0) tracks so far" } ?? "")
            } else {
                display.syncTitle = "Syncing “\(label)”…"
                display.syncDetail = tracks.map { "\($0) songs on the iPod" } ?? "Waiting for iTunes"
            }
            display.syncFraction = p.fraction
            let wasOffered = display.modes.contains(.sync)
            display.modes = [.player, .sync]
            if !wasOffered {
                syncViewPinned = false
                display.mode = .sync
            }
        } else {
            if let e = p.error {
                display.syncTitle = "Sync stopped"
                display.syncDetail = e
            } else if p.kind == "rebuild" {
                display.syncTitle = "Sync playlist written"
                display.syncDetail = tracks.map { "\($0) tracks — sync the iPod to send them" } ?? "Done"
            } else {
                display.syncTitle = "Sync finished"
                display.syncDetail = tracks.map { "\($0) songs on “\(label)”" } ?? "Done"
            }
            display.syncFraction = 1
            guard display.modes.contains(.sync) else { return }
            syncViewTimer?.invalidate()
            syncViewTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    // Someone who cycled to the finished sync view keeps it
                    // until they cycle away; everyone else gets the song back.
                    if self.syncViewPinned && self.display.mode == .sync { return }
                    self.display.mode = .player
                    self.display.modes = [.player]
                }
            }
        }
    }

    /// Redraws just the rows for these tracks.
    private func reloadRows(forTrackIds ids: [String]) {
        guard !ids.isEmpty, trackTable.numberOfColumns > 0 else { return }
        var set = IndexSet()
        for (i, t) in rows.enumerated() where ids.contains(t.persistentId) {
            if let r = tableRow(forTrackIndex: i) { set.insert(r) }
        }
        guard !set.isEmpty else { return }
        trackTable.reloadData(forRowIndexes: set, columnIndexes: IndexSet(integersIn: 0..<trackTable.numberOfColumns))
    }

    /// The Window menu's mini player item shows a tick while the mini player
    /// is up, so it reads as the switch it is.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMiniPlayer(_:)) {
            item.state = (miniPlayer?.window?.isVisible == true) ? .on : .off
        }
        return true
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
        // In local mode the audio is coming from this Mac, so none of iTunes'
        // own outputs is the live one — show them all unchecked and let the
        // check sit on "Play on This Mac".
        let local = player.mode == .local
        for output in player.outputs {
            let item = NSMenuItem(title: output.name, action: #selector(outputPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = output.name
            item.state = (!local && output.selected) ? .on : .off
            item.isEnabled = output.available
            item.toolTip = "Play through \(output.name) only. ⌘-click to add it to the speakers already playing."
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
        // Picking a speaker used to add it to the set, so the HomePod came up
        // ticked beside Computer while iTunes kept playing through Computer.
        // iTunes' own popup routes to the one you pick; ⌘-click builds a set.
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            player.toggleOutput(name)
        } else {
            player.selectOnly(name)
        }
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
        if !curateScript.isEmpty {
            runCurateScript()
            return
        }
        if snapshotPath == nil {
            restoreLastTrack()
            return
        }
        guard let path = snapshotPath, let content = window?.contentView else { return }
        window?.makeKeyAndOrderFront(nil)
        if let want = snapshotDevice {
            // The Music pane's four lists arrive from four separate requests,
            // so give them time rather than capturing an empty pane.
            Task { @MainActor in
                if let d = self.devices.first(where: { $0.name == want }) {
                    self.openDevicePage(for: d)
                    self.devicePage.showMusicPane()
                }
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                if let lcd = self.snapshotLCD {
                    self.display.mode = lcd == "sync" ? .sync : .player
                }
                self.capture(to: path, content: content)
            }
            return
        }
        trackTable.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        window?.makeFirstResponder(trackTable)
        capture(to: path, content: content)
    }

    private func capture(to path: String, content: NSView) {
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
    @objc func previousTrack(_ sender: Any?) { previousPressed() }

    /// iTunes' rewind: a few seconds into a song it starts the song again, and
    /// pressed again within those first seconds it goes back a track.
    func previousPressed() {
        if player.state?.track != nil, player.state?.state != "stopped", player.displayPosition > 3 {
            player.seek(to: 0)
            return
        }
        step(by: -1)
    }

    /// iTunes 12 treats `play <track>` as a one-item queue, so its own
    /// `next track` stops playback instead of advancing. Step through the list
    /// the user is actually looking at instead, which is also what they expect
    /// after a search, a browser filter, or a column sort.
    /// Rows already played in this shuffle run, newest last, so Previous can
    /// walk back through them and Next avoids an immediate repeat.
    private var shuffleHistory: [Int] = []

    /// Steps to the next or previous track, honouring shuffle and repeat.
    ///
    /// iTunes cannot do this for us. Its app-level `shuffle enabled` and
    /// `song repeat` accept a write and then have no effect on playback; the
    /// properties that actually govern it live on the current playlist and are
    /// read-only (-10006). Since `play <track>` gives iTunes a one-item queue,
    /// this app already owns the queue in both remote and local mode — so
    /// shuffle and repeat are implemented here, where they genuinely work.
    private func step(by delta: Int) {
        // Anything explicitly queued plays before the list carries on.
        if delta > 0, !upNext.isEmpty {
            let track = upNext.removeFirst()
            startPlayback(track, playlist: controller.source.playlistId)
            refreshUpNext()
            return
        }
        let list = playContext.isEmpty ? rows : playContext
        guard let playing = player.state?.track?.persistentId,
              let i = list.firstIndex(where: { $0.persistentId == playing }) else {
            // Nothing of ours is playing (iTunes was started from its own
            // window, say). Start the list on screen from the top rather
            // than handing the step to iTunes, whose queue is whatever it
            // was last told to play inside.
            if let first = rows.first { startPlayback(first, playlist: controller.source.playlistId, context: rows) }
            return
        }
        let mode = player.state?.repeatMode ?? "off"
        // Repeat One holds on the same track, whichever way you step.
        if mode == "one" {
            playInContext(i)
            return
        }
        guard let j = nextIndex(from: i, in: list, delta: delta,
                                shuffle: player.state?.shuffle ?? false,
                                repeatAll: mode == "all") else { return }
        playInContext(j)
    }

    /// Plays an entry of the current context and highlights it if the
    /// window happens to be showing it.
    private func playInContext(_ index: Int) {
        let list = playContext.isEmpty ? rows : playContext
        guard index >= 0, index < list.count else { return }
        let track = list[index]
        startPlayback(track, playlist: playContext.isEmpty ? controller.source.playlistId : playContextPlaylist)
        if let i = rows.firstIndex(where: { $0.persistentId == track.persistentId }),
           let r = tableRow(forTrackIndex: i) {
            trackTable.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            trackTable.scrollRowToVisible(r)
        }
    }

    private func nextIndex(from i: Int, in list: [Track], delta: Int, shuffle: Bool, repeatAll: Bool) -> Int? {
        guard list.count > 1 else { return repeatAll ? i : nil }
        guard shuffle else {
            let j = i + delta
            if j >= 0 && j < list.count { return j }
            guard repeatAll else { return nil }
            return j < 0 ? list.count - 1 : 0
        }
        if delta < 0 {
            // Walk back through what shuffle actually played.
            while let previous = shuffleHistory.popLast() {
                if previous != i && previous < list.count { return previous }
            }
            return nil
        }
        shuffleHistory.append(i)
        // Don't repeat anything from the recent past until the pool runs dry.
        let window = min(list.count - 1, 50)
        let recent = Set(shuffleHistory.suffix(window) + [i])
        let pool = list.indices.filter { !recent.contains($0) }
        if let pick = pool.randomElement() { return pick }
        // Everything's been played: start over if repeating, else stop.
        guard repeatAll else { return nil }
        shuffleHistory.removeAll()
        return list.indices.filter { $0 != i }.randomElement()
    }

    private func playRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        startPlayback(rows[index], playlist: controller.source.playlistId, context: rows)
        if let r = tableRow(forTrackIndex: index) {
            trackTable.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            trackTable.scrollRowToVisible(r)
        }
    }

    @objc private func trackDoubleClicked(_ sender: Any?) {
        guard let i = trackIndex(forRow: trackTable.clickedRow) else { return }
        startPlayback(rows[i], playlist: controller.source.playlistId, context: rows)
    }

    @objc private func sourceDoubleClicked(_ sender: Any?) {
        let row = sourceList.clickedRow
        guard row >= 0, row < sourceRows.count else { return }
        if case .playlist(let p) = sourceRows[row], p.folder {
            toggleFolder(p.persistentId)
            return
        }
        if case .playlist(let p) = sourceRows[row], let first = rows.first {
            startPlayback(first, playlist: p.persistentId, context: rows)
        }
    }

    private var clickMonitor: Any?

    private func installKeyMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self = self, let popup = self.searchPopup, popup.isVisible,
               event.window !== popup.panel {
                let inField = event.window === self.window
                    && self.searchField.frame.contains(self.searchField.superview?.convert(event.locationInWindow, from: nil) ?? .zero)
                if !inField { popup.hide() }
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            // Space toggles playback unless a text field has focus.
            if event.charactersIgnoringModifiers == " ",
               !(self.window?.firstResponder is NSText) {
                self.player.playPause()
                return nil
            }
            if let popup = self.searchPopup, popup.isVisible, self.searchHasFocus {
                switch event.keyCode {
                case 125: popup.moveSelection(by: 1); return nil     // down
                case 126: popup.moveSelection(by: -1); return nil    // up
                case 36, 76: popup.activateSelection(); return nil   // return
                case 53: popup.hide(); return nil                    // escape
                default: break
                }
            }
            if event.charactersIgnoringModifiers == "i", event.modifierFlags.contains(.command) {
                self.showGetInfo(nil)
                return nil
            }
            if event.keyCode == 36, self.window?.firstResponder === self.trackTable {   // Return
                self.trackDoubleClickedFromSelection()
                return nil
            }
            // The curator's list: Delete drops songs, Return plays the selection.
            if self.curatorOpen, self.window?.firstResponder === self.curatorPage.table {
                if event.keyCode == 51 || event.keyCode == 117 { self.curatorPage.deleteSelection(); return nil }
                if event.keyCode == 36 { self.curatorPage.playSelection(); return nil }
            }
            // Delete and forward-delete act on whichever list has focus, on the
            // whole selection. Both paths confirm first.
            if event.keyCode == 51 || event.keyCode == 117 {
                if self.window?.firstResponder === self.sourceList, !self.deletablePlaylists().isEmpty {
                    self.deletePlaylist(nil)
                    return nil
                }
                if self.window?.firstResponder === self.trackTable,
                   self.controller.source.playlistId != nil, !self.selectedTracks.isEmpty {
                    self.removeFromPlaylist(nil)
                    return nil
                }
                if self.window?.firstResponder === self.trackTable, !self.selectedTracks.isEmpty {
                    // In Music and Recently Added there is no playlist to
                    // remove from, and this app never deletes from the library.
                    self.flashStatus("Select a playlist to remove songs from — Music holds the whole library.")
                    return nil
                }
            }
            return event
        }
    }

    private func trackDoubleClickedFromSelection() {
        guard let i = trackIndex(forRow: trackTable.selectedRow) else { return }
        startPlayback(rows[i], playlist: controller.source.playlistId, context: rows)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === columnMenu {
            buildColumnMenu(menu)
            return
        }
        if menu === sourceMenu {
            buildSourceMenu(menu)
            return
        }
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
        buildIPodMenus()
    }

    /// The two iPod submenus. Adding a track to a playlist the iPod syncs is
    /// what "add it to the sync" actually means here — iTunes' own checkbox
    /// list lives in its library database and cannot be set from outside.
    private func buildIPodMenus() {
        let haveDevice = syncedDevice != nil && !syncedPlaylists.isEmpty
        addToIPodItem?.isHidden = !haveDevice
        removeFromIPodItem?.isHidden = !haveDevice
        guard haveDevice else { return }
        let editable = syncedPlaylists.filter { !$0.smart }
        func build(_ action: Selector) -> NSMenu {
            let m = NSMenu()
            if editable.isEmpty {
                let none = NSMenuItem(title: "The iPod syncs only smart playlists", action: nil, keyEquivalent: "")
                none.isEnabled = false
                m.addItem(none)
                return m
            }
            for p in editable {
                let title = "\(p.name)  (\(p.deviceCount))"
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = p.playlistId
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: Aqua.font(13)])
                m.addItem(item)
            }
            return m
        }
        addToIPodItem?.submenu = build(#selector(addToIPodPicked(_:)))
        removeFromIPodItem?.submenu = build(#selector(removeFromIPodPicked(_:)))
        addToIPodItem?.isEnabled = !selectedTracks.isEmpty
        removeFromIPodItem?.isEnabled = !selectedTracks.isEmpty
    }

    @objc private func addToIPodPicked(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String, let api = controller.api else { return }
        let ids = selectedTracks.map { $0.persistentId }
        guard !ids.isEmpty else { return }
        let name = syncedPlaylists.first { $0.playlistId == playlistId }?.name ?? "the playlist"
        Task { @MainActor in
            do {
                let change = try await api.addToPlaylist(playlistId, ids: ids)
                flashStatus("\(change.summary("Added")) to \(name). Sync the iPod to copy them across.")
                await reloadPlaylists()
                if controller.source.playlistId == playlistId { controller.reload() }
            } catch {
                flashStatus("Could not add to \(name): \(error.localizedDescription)")
            }
        }
    }

    @objc private func removeFromIPodPicked(_ sender: NSMenuItem) {
        guard let playlistId = sender.representedObject as? String, let api = controller.api else { return }
        let ids = selectedTracks.map { $0.persistentId }
        guard !ids.isEmpty else { return }
        let name = syncedPlaylists.first { $0.playlistId == playlistId }?.name ?? "the playlist"
        Task { @MainActor in
            do {
                let change = try await api.removeFromPlaylist(playlistId, ids: ids)
                flashStatus("\(change.summary("Removed")) from \(name). Sync the iPod to take them off it.")
                await reloadPlaylists()
                if controller.source.playlistId == playlistId { controller.reload() }
            } catch {
                flashStatus("Could not remove from \(name): \(error.localizedDescription)")
            }
        }
    }

    /// Reads which playlists reach the iPod, once per device change. The call
    /// costs about a second of iTunes' time, so it is not on the 30-second
    /// device poll.
    private func loadSyncedPlaylists() {
        guard let api = controller.api,
              let device = devices.first(where: { $0.isIPod && ($0.itunesSource ?? true) }) else {
            syncedDevice = nil
            syncedPlaylists = []
            return
        }
        guard device.name != syncedDevice else { return }
        Task { @MainActor in
            guard let detail = try? await api.deviceDetail(device.name), let sync = detail.sync else { return }
            self.syncedDevice = device.name
            self.syncedPlaylists = sync.playlists
        }
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        searchTimer?.invalidate()
        let text = searchField.stringValue
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.controller.searchText = text
                self?.suggest(text)
            }
        }
        if text.isEmpty { searchPopup?.hide() }
    }

    @objc private func searchFieldAction(_ sender: Any?) {
        searchTimer?.invalidate()
        let text = searchField.stringValue
        controller.searchText = text
        if text.isEmpty { searchPopup?.hide() } else { suggest(text) }
    }

    @objc func focusSearch(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    /// The field lost focus: the suggestions go with it.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        searchPopup?.hide()
    }

    // MARK: Search suggestions

    private var searchPopup: SearchPopup?
    private var suggestGeneration = 0

    /// True while the search field is being typed into.
    private var searchHasFocus: Bool {
        (window?.firstResponder as? NSTextView)?.delegate === searchField
    }

    /// Asks the daemon for the top artists, albums and songs matching the
    /// text, across the whole library rather than just the list on screen,
    /// and drops them under the field.
    private func suggest(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let api = controller.api else { searchPopup?.hide(); return }
        suggestGeneration += 1
        let gen = suggestGeneration
        let filter = TrackFilter(q: q)
        Task { @MainActor in
            async let artists = api.facet("artist", filter: filter)
            async let albums = api.albumList(filter: filter)
            async let songs = api.tracks(filter: filter, limit: 6)
            // Stale if the field has moved on since this was asked for. That,
            // not keyboard focus, is what decides whether to show it: focus
            // is what routes the arrow keys, and the field may have lost it
            // to a click without the text changing.
            guard let a = try? await artists, let al = try? await albums, let s = try? await songs,
                  gen == suggestGeneration,
                  searchField.stringValue.trimmingCharacters(in: .whitespaces) == q else { return }
            let popup = searchPopup ?? makeSearchPopup()
            searchPopup = popup
            popup.update(artists: a, albums: al, songs: s.tracks, below: searchField)
        }
    }

    private func makeSearchPopup() -> SearchPopup {
        let p = SearchPopup()
        p.onPick = { [weak self] pick in
            guard let self = self else { return }
            switch pick {
            case .artist(let name):
                self.showInLibrary(artist: name, album: nil)
            case .album(let a):
                self.showInLibrary(artist: a.artist, album: a.album)
            case .song(let t):
                self.startPlayback(t, playlist: nil)
                self.flashStatus("Playing “\(t.name)”.")
            }
        }
        return p
    }

    /// Clears the search and narrows the library to one artist, or one
    /// album, through the column browser — the same state clicking there
    /// would have produced.
    private func showInLibrary(artist: String, album: String?) {
        searchField.stringValue = ""
        searchTimer?.invalidate()
        controller.searchText = ""
        closeDevicePage()
        if controller.source != .library { controller.source = .library }
        controller.select(nil, in: "genre")
        controller.select(artist, in: "artist")
        controller.select(album, in: "album")
        window?.makeFirstResponder(trackTable)
    }

    // MARK: Column browser

    static let browserTitles = ["genre": "Genres", "artist": "Artists", "album": "Albums",
                                "composer": "Composers", "grouping": "Groupings"]
    static let browserOrder = ["genre", "artist", "album", "composer", "grouping"]

    private func rebuildBrowserPanes() {
        for view in browserSplit.arrangedSubviews { browserSplit.removeArrangedSubview(view); view.removeFromSuperview() }
        browserScrolls.removeAll()
        browserTables.removeAll()
        let fields = MainWindowController.browserOrder.filter { browserFields.contains($0) }
        let width = max(1, browserSplit.bounds.width / CGFloat(max(1, fields.count)))
        for field in fields {
            let table = NSTableView()
            table.tag = Tag.browser.rawValue
            table.identifier = NSUserInterfaceItemIdentifier(field)
            let column = AquaTables.column(field, title: MainWindowController.browserTitles[field] ?? field,
                                           width: 200, sortable: false)
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            AquaTables.style(table, rowHeight: 18, header: true)
            table.gridStyleMask = []
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            let scroll = self.scroll(for: table)
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 150)
            browserSplit.addArrangedSubview(scroll)
            browserScrolls[field] = scroll
            browserTables[field] = table
        }
        browserSplit.adjustSubviews()
        applyBrowserVisibility()
    }

    private func applyBrowserVisibility() {
        let showBrowser = browserVisible && viewMode == .list
        browserSplit.isHidden = !showBrowser
        if viewMode == .list {
            rightSplit.setPosition(showBrowser ? browserHeight : 0, ofDividerAt: 0)
        }
    }

    /// The View menu's four view items, tagged 0 to 3 in switcher order.
    @objc func pickViewMode(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < ViewMode.segments.count else { return }
        setViewMode(ViewMode.segments[sender.tag])
    }

    @objc func toggleColumnBrowser(_ sender: Any?) {
        guard viewMode == .list else {
            flashStatus("The column browser is only shown in List view.")
            return
        }
        browserVisible.toggle()
        UserDefaults.standard.set(browserVisible, forKey: "browserVisible")
        applyBrowserVisibility()
    }

    @objc private func toggleBrowserField(_ sender: NSMenuItem) {
        guard let field = sender.representedObject as? String else { return }
        if browserFields.contains(field) {
            guard browserFields.count > 1 else { return }
            browserFields.removeAll { $0 == field }
        } else {
            browserFields.append(field)
        }
        UserDefaults.standard.set(browserFields, forKey: "browserFields")
        rebuildBrowserPanes()
        controller.setBrowserFields(browserFields)
        controller.reload()
    }

    /// The View menu's browser submenu, built fresh each time it opens.
    func buildBrowserMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: browserVisible ? "Hide Column Browser" : "Show Column Browser",
                                action: #selector(toggleColumnBrowser(_:)), keyEquivalent: "b")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        for field in MainWindowController.browserOrder {
            let item = NSMenuItem(title: MainWindowController.browserTitles[field] ?? field,
                                  action: #selector(toggleBrowserField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field
            item.state = browserFields.contains(field) ? .on : .off
            item.attributedTitle = NSAttributedString(string: MainWindowController.browserTitles[field] ?? field,
                                                      attributes: [.font: Aqua.font(13)])
            menu.addItem(item)
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch Tag(rawValue: tableView.tag) {
        case .source: return sourceRows.count
        case .browser:
            guard let field = tableView.identifier?.rawValue else { return 0 }
            return controller.facet(field).count + 1
        case .tracks: return displayRows.count
        case .none: return 0
        }
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    /// "9/2/26" from the daemon's ISO timestamp.
    static func shortDate(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        var date = isoParser.date(from: iso)
        if date == nil {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            date = plain.date(from: iso)
        }
        guard let d = date else { return "" }
        return shortFormatter.string(from: d)
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
            case .recentlyAdded:
                return sidebarCell(tableView, text: "Recently Added", icon: .recent)
            case .playlist(let p):
                let icon: SidebarIcon = p.persistentId == playingPlaylistId
                    ? .speaker : (p.folder ? .folder : (p.smart ? .smartPlaylist : .playlist))
                let cell = sidebarCell(tableView, text: p.name, icon: icon)
                cell.indent = CGFloat(playlistDepth[p.persistentId] ?? 0) * 14
                if p.folder {
                    cell.disclosure = !collapsedFolders.contains(p.persistentId)
                    let pid = p.persistentId
                    cell.onToggle = { [weak self] in self?.toggleFolder(pid) }
                }
                return cell
            case .curator:
                return sidebarCell(tableView, text: "Playlist Curator", icon: .curator)
            case .device(let d):
                var text = d.name
                if let free = d.freeSpace, let cap = d.capacity, cap > 0 {
                    text += "  (\(StatusFormat.size(free)) free of \(StatusFormat.size(cap)))"
                }
                return sidebarCell(tableView, text: text, icon: .ipod)
            }
        case .browser:
            guard let field = tableView.identifier?.rawValue else { return nil }
            let cell = AquaTables.labelCell(tableView, id: "facet")
            let noun = (MainWindowController.browserTitles[field] ?? field)
            cell.textField?.stringValue = facetText(controller.facet(field), row: row,
                                                    noun: String(noun.dropLast()))
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
                box.toolTip = "Include this track when playing straight through, and when syncing. iTunes 12.9.5 may ignore changes made from here."
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
            case "dateAdded": text = MainWindowController.shortDate(t.dateAdded)
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
        cell.indent = 0
        cell.disclosure = nil
        cell.onToggle = nil
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
            case .header: return false
            default: return true
            }
        }
        return true
    }

    /// Sanitises what a shift- or command-click is about to select in the
    /// sidebar. Extending a selection is only meaningful across playlists, so
    /// a range dragged over "PLAYLISTS", Music or the iPod keeps the playlists
    /// and drops the rest. A single click still selects anything.
    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard Tag(rawValue: tableView.tag) == .source, proposed.count > 1 else { return proposed }
        let playlists = proposed.filteredIndexSet { row in
            guard row >= 0, row < sourceRows.count else { return false }
            if case .playlist = sourceRows[row] { return true }
            return false
        }
        // Nothing selectable in the range: leave the selection alone rather
        // than clearing it out from under the user.
        return playlists.isEmpty ? tableView.selectedRowIndexes : playlists
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
            // A multiple selection is a batch to act on, not a place to go:
            // keep showing whatever is already open rather than loading the
            // lowest-numbered playlist of the group.
            guard table.selectedRowIndexes.count == 1 else { return }
            switch sourceRows[row] {
            case .library: closeDevicePage(); closeCuratorPage(); controller.source = .library
            case .recentlyAdded: closeDevicePage(); closeCuratorPage(); controller.source = .recentlyAdded
            case .playlist(let p): closeDevicePage(); closeCuratorPage(); controller.source = .playlist(p)
            case .device(let d): closeCuratorPage(); openDevicePage(for: d)
            case .curator: openCuratorPage()
            case .header: break
            }
        case .browser:
            guard let field = table.identifier?.rawValue else { return }
            let entries = controller.facet(field)
            controller.select(row > 0 && row - 1 < entries.count ? entries[row - 1].name : nil, in: field)
        default:
            break
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard Tag(rawValue: tableView.tag) == .tracks else { return }
        let d = tableView.sortDescriptors.first
        controller.setSort(key: d?.key, ascending: d?.ascending ?? true)
        // The triangle lives in the header cells, which do not repaint on
        // their own when the descriptor moves to another column.
        tableView.headerView?.needsDisplay = true
    }
}
