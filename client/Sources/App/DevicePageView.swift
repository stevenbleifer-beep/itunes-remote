import Cocoa

/// The device page, laid out as iTunes 12.9.5 lays it out on the MacBook Pro:
/// the device's own picture, name and capacity badge at the top left, a
/// settings list under it, the pane on the right, and the capacity bar with
/// Sync and Done along the bottom.
///
/// Everything shown is read from iTunes, from its com.apple.iPod preferences,
/// or from the USB tree. iTunes' sync *settings* — sync the whole library,
/// convert to 192 kbps, sync only checked songs — live in the library
/// database and are exposed to nothing, so they are described rather than
/// drawn as switches that would do nothing.
@MainActor
final class DevicePageView: NSView {
    var onSync: () -> Void = {}
    var onEject: () -> Void = {}
    var onDone: () -> Void = {}
    /// Asks for the tracks in one of the device's playlists.
    var loadTracks: (String, @escaping ([DeviceTrack]) -> Void) -> Void = { _, done in done([]) }
    var loadImage: (@escaping (NSImage?) -> Void) -> Void = { done in done(nil) }

    private enum Row {
        case header(String)
        case summary
        case music
        /// A playlist on the device: its name and whether it is a special one.
        case content(String, SidebarIcon)
    }

    private var rows: [Row] = [.header("Settings"), .summary]
    private let nav = DeviceNavBar()
    private let header = DeviceHeaderView()
    private let list = NSTableView()
    private let listScroll = NSScrollView()
    private let summary = DeviceSummaryView()
    private let musicPane = DeviceMusicView()
    private let trackTable = SimpleTable(columns: [("Name", 300), ("Artist", 200), ("Album", 200), ("Time", 60)])
    private let capacity = CapacityBarView()
    private let syncButton = AquaPushButton(title: "Sync")
    private let doneButton = AquaPushButton(title: "Done", isDefault: true)
    private let statusLabel = NSTextField(labelWithString: "")
    private var detail: DeviceDetail?
    private var loadedPlaylist: String?
    /// Collapses to nothing for a device whose capacity iTunes cannot report,
    /// rather than leaving an empty band above the buttons.
    private lazy var capacityHeight = capacity.heightAnchor.constraint(equalToConstant: 24)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [nav as NSView, header, listScroll, summary, musicPane, trackTable.scrollView,
                  capacity, syncButton, doneButton, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        syncButton.target = self
        syncButton.action = #selector(sync(_:))
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        header.onEject = { [weak self] in self?.onEject() }
        nav.onBack = { [weak self] in self?.goBack() }
        nav.onForward = { [weak self] in self?.goForward() }

        list.headerView = nil
        list.backgroundColor = Aqua.sidebarBackground
        list.rowHeight = 22
        list.intercellSpacing = NSSize(width: 0, height: 0)
        list.gridStyleMask = []
        list.selectionHighlightStyle = .regular
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device")))
        list.dataSource = self
        list.delegate = self
        listScroll.documentView = list
        listScroll.drawsBackground = true
        listScroll.backgroundColor = Aqua.sidebarBackground
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .legacy
        listScroll.verticalScroller = AquaScroller()

        let pad: CGFloat = 14
        let sidebar: CGFloat = 210
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: trailingAnchor),
            nav.topAnchor.constraint(equalTo: topAnchor),
            nav.heightAnchor.constraint(equalToConstant: 36),

            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.topAnchor.constraint(equalTo: nav.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: sidebar),
            header.heightAnchor.constraint(equalToConstant: 72),

            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: sidebar),
            listScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The bar belongs to the content area, not the whole window:
            // iTunes starts it at the sidebar's right edge.
            capacity.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: pad),
            capacity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            capacityHeight,
            capacity.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -10),

            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            doneButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            syncButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            syncButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            // Lined up with the capacity bar above it, not with the window
            // edge: under the sidebar it read as a stray caption.
            statusLabel.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: syncButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
        ])
        for content in [summary as NSView, musicPane, trackTable.scrollView] {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: pad),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                content.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: pad),
                content.bottomAnchor.constraint(equalTo: capacity.topAnchor, constant: -12),
            ])
        }
        trackTable.scrollView.isHidden = true
        musicPane.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
        // The sidebar's own ground, and the hairline that separates it. It
        // stops below the navigation strip, which spans the whole width.
        let top = bounds.maxY - 36
        Aqua.sidebarBackground.setFill()
        NSRect(x: 0, y: 0, width: 210, height: top).fill()
        NSColor(white: 0.66, alpha: 1).setFill()
        NSRect(x: 210, y: 0, width: 1, height: top).fill()
    }

    // MARK: Navigation

    /// The panes visited on this page, so the arrows have somewhere to go.
    /// Stepping back past the first one leaves the device, as iTunes' does.
    private var history: [Int] = []
    private var historyIndex = -1

    private func record(_ row: Int) {
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == row { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(row)
        historyIndex = history.count - 1
        updateNav()
    }

    private func updateNav() {
        nav.canGoBack = true                      // the first step back leaves the device
        nav.canGoForward = historyIndex < history.count - 1
    }

    private func goBack() {
        guard historyIndex > 0 else {
            onDone()
            return
        }
        historyIndex -= 1
        select(history[historyIndex])
        updateNav()
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        select(history[historyIndex])
        updateNav()
    }

    /// Moves the list without pushing another history entry.
    private var selectingFromHistory = false

    private func select(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        selectingFromHistory = true
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectingFromHistory = false
        switch rows[row] {
        case .summary: showSummary()
        case .music: showMusicSettings()
        case .content(let name, _): showTracks(name)
        case .header: break
        }
    }

    @objc private func sync(_ sender: Any?) { onSync() }
    @objc private func done(_ sender: Any?) { onDone() }

    func setStatus(_ text: String) {
        readAt = nil
        statusLabel.stringValue = text
    }

    /// When iTunes last answered. Shown so it is plain that the page is being
    /// read live rather than frozen at whatever was true when it opened.
    private var readAt: Date?
    private var summaryLine = ""
    private var clock: Timer?

    func setRead(at date: Date) {
        readAt = date
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusLine() }
        }
        updateStatusLine()
    }

    private func updateStatusLine() {
        guard let at = readAt else { return }
        let seconds = Int(Date().timeIntervalSince(at))
        let age: String
        switch seconds {
        case ..<2: age = "just now"
        case ..<60: age = "\(seconds)s ago"
        default: age = "\(seconds / 60)m ago"
        }
        statusLabel.stringValue = summaryLine.isEmpty ? "Read from iTunes \(age)"
                                                      : "\(summaryLine), read from iTunes \(age)"
    }

    func setBusy(_ busy: Bool) {
        syncButton.isEnabled = !busy && (detail?.syncable ?? false)
        header.canEject = !busy && (detail?.itunesSource ?? false)
    }

    func show(_ d: DeviceDetail) {
        let firstLoad = detail?.name != d.name
        detail = d
        header.show(d)
        summary.show(d)
        if let sync = d.sync { musicPane.show(sync) }
        capacity.show(d)
        let hasBar = (d.capacity ?? 0) > 0
        capacity.isHidden = !hasBar
        capacityHeight.constant = hasBar ? 24 : 0
        var r: [Row] = [.header("Settings"), .summary]
        if d.sync != nil { r.append(.music) }
        if !d.categories.isEmpty || !d.playlists.isEmpty {
            r.append(.header("On My Device"))
            for c in d.categories where c.trackCount > 0 {
                r.append(.content(c.name, DevicePageView.icon(for: c.name)))
            }
            for p in d.playlists {
                r.append(.content(p.name, .playlist))
            }
        }
        rows = r
        list.reloadData()
        nav.title = d.name
        if firstLoad || list.selectedRow < 0 {
            history = []
            historyIndex = -1
            // Come back to the pane last looked at, as long as it still exists.
            let wanted = UserDefaults.standard.integer(forKey: "devicePane")
            let row = (wanted > 0 && wanted < rows.count) ? wanted : 1
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            select(row)
            updateNav()
            loadImage { [weak self] image in self?.header.image = image }
        }
        syncButton.isEnabled = d.syncable
        header.canEject = d.itunesSource
        if let reason = d.unavailableReason {
            summaryLine = reason
        } else if let n = d.trackCount {
            summaryLine = "\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) items on \(d.name)"
        } else {
            summaryLine = ""
        }
        updateStatusLine()
    }

    /// The library's own playlists, artists, genres and albums, marked
    /// against what reached the device.
    func showMusicLibrary(playlists: [Playlist], artists: [String], genres: [String],
                          albums: [String], device: DeviceFacets) {
        musicPane.showLibrary(playlists: playlists, artists: artists, genres: genres,
                              albums: albums, device: device)
    }

    private static func icon(for category: String) -> SidebarIcon {
        switch category {
        case "Music": return .music
        case "Books", "Audiobooks": return .playlist
        default: return .playlist
        }
    }

    private func showSummary() {
        summary.isHidden = false
        musicPane.isHidden = true
        trackTable.scrollView.isHidden = true
    }

    private func showMusicSettings() {
        summary.isHidden = true
        musicPane.isHidden = false
        trackTable.scrollView.isHidden = true
    }

    private func showTracks(_ playlist: String) {
        summary.isHidden = true
        musicPane.isHidden = true
        trackTable.scrollView.isHidden = false
        guard loadedPlaylist != playlist else { return }
        loadedPlaylist = playlist
        trackTable.rows = [["Reading \(playlist) from the device…", "", "", ""]]
        loadTracks(playlist) { [weak self] tracks in
            guard let self = self, self.loadedPlaylist == playlist else { return }
            self.trackTable.rows = tracks.map {
                [$0.name, $0.artist, $0.album, StatusFormat.duration($0.totalTime)]
            }
            if tracks.isEmpty {
                self.trackTable.rows = [["Nothing in \(playlist) on this device.", "", "", ""]]
            }
        }
    }
}

extension DevicePageView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = AquaTables.labelCell(tableView, id: "deviceHeader")
            let emboss = NSShadow()
            emboss.shadowColor = NSColor.white.withAlphaComponent(0.9)
            emboss.shadowOffset = NSSize(width: 0, height: -1)
            emboss.shadowBlurRadius = 0
            cell.textField?.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: Aqua.font(11, bold: true), .foregroundColor: Aqua.sidebarHeaderText, .shadow: emboss,
            ])
            return cell
        case .summary:
            return DevicePageView.sidebarCell(tableView, text: "Summary", icon: .smartPlaylist)
        case .music:
            return DevicePageView.sidebarCell(tableView, text: "Music", icon: .music)
        case .content(let name, let icon):
            return DevicePageView.sidebarCell(tableView, text: name, icon: icon)
        }
    }

    private static func sidebarCell(_ table: NSTableView, text: String, icon: SidebarIcon) -> SidebarCellView {
        let ident = NSUserInterfaceItemIdentifier("cell.deviceSidebar")
        let cell = (table.makeView(withIdentifier: ident, owner: nil) as? SidebarCellView) ?? {
            let v = SidebarCellView()
            v.identifier = ident
            return v
        }()
        cell.label.stringValue = text
        cell.iconView.icon = icon
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard list.selectedRow >= 0, list.selectedRow < rows.count else { return }
        if !selectingFromHistory {
            record(list.selectedRow)
            UserDefaults.standard.set(list.selectedRow, forKey: "devicePane")
        }
        switch rows[list.selectedRow] {
        case .summary: showSummary()
        case .music: showMusicSettings()
        case .content(let name, _): showTracks(name)
        case .header: break
        }
    }
}

// MARK: - Header

/// The device's picture, its name, the capacity badge and the eject button,
/// in the corner iTunes puts them.
final class DeviceHeaderView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onEject: () -> Void = {}
    var canEject = false { didSet { needsDisplay = true } }
    private var title = ""
    private var badge = ""

    private var ejectRect: NSRect {
        NSRect(x: bounds.maxX - 26, y: bounds.maxY - 34, width: 18, height: 18)
    }

    func show(_ d: DeviceDetail) {
        title = d.name
        // iTunes shows the marketing size on the badge, not the formatted
        // capacity: a 160 GB iPod formats to 148.87 GB.
        badge = d.capacity.map { DeviceFormat.marketingSize($0) } ?? ""
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard canEject, ejectRect.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) else { return }
        onEject()
    }

    override func draw(_ dirtyRect: NSRect) {
        Aqua.sidebarBackground.setFill()
        bounds.fill()
        let side: CGFloat = 46
        let box = NSRect(x: 12, y: bounds.midY - side / 2, width: side, height: side)
        if let image = image {
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            DeviceSummaryView.drawIPod(in: box)
        }
        let left = box.maxX + 10
        (title as NSString).draw(at: NSPoint(x: left, y: bounds.maxY - 30), withAttributes: [
            .font: Aqua.font(13, bold: true), .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        if !badge.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Aqua.font(10), .foregroundColor: NSColor(white: 0.30, alpha: 1),
            ]
            let size = (badge as NSString).size(withAttributes: attrs)
            let r = NSRect(x: left, y: bounds.maxY - 50, width: size.width + 12, height: 15)
            let pill = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor(white: 1, alpha: 0.75).setFill()
            pill.fill()
            NSColor(white: 0.62, alpha: 1).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            (badge as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.minY + 1), withAttributes: attrs)
        }
        guard canEject else { return }
        let e = ejectRect
        let color = NSColor(white: 0.28, alpha: 1)
        color.setFill()
        let t = NSBezierPath()
        t.move(to: NSPoint(x: e.midX - 6, y: e.midY - 1))
        t.line(to: NSPoint(x: e.midX + 6, y: e.midY - 1))
        t.line(to: NSPoint(x: e.midX, y: e.midY + 5))
        t.close()
        t.fill()
        NSRect(x: e.midX - 6, y: e.midY - 5, width: 12, height: 2).fill()
    }
}

// MARK: - Summary

/// iTunes' Summary pane: the identity box, then Options.
final class DeviceSummaryView: NSView {
    private var title = ""
    private var left: [(String, String)] = []
    private var softwareVersion: String?
    private var options: [(String, Bool?, String)] = []
    private var optionsTitle = "Options"
    private var note = ""

    func show(_ d: DeviceDetail) {
        title = d.name
        var l: [(String, String)] = []
        if let cap = d.capacity { l.append(("Capacity:", DeviceFormat.size(cap))) }
        if let s = d.deviceSerialNumber ?? d.serialNumber { l.append(("Serial Number:", s)) }
        if let f = d.formatName { l.append(("Format:", f)) }
        if let c = d.connection { l.append(("Connection:", c)) }
        if let n = d.useCount { l.append(("Times connected:", String(n))) }
        left = l
        softwareVersion = d.softwareVersion
        if let reason = d.unavailableReason {
            options = []
            note = reason + "\n\nThis is everything the USB bus can say about it. Open iTunes "
                + "on the MacBook Pro with the device connected, and the rest of this page fills in."
        } else {
            // Every option from iTunes' own Summary pane, in its order. A tick
            // is a value actually established; a dash is one iTunes keeps to
            // itself. None of them is a switch, because none can be set.
            var o: [(String, Bool?, String)] = [
                ("Open iTunes when this iPod is connected", nil, ""),
                ("Sync only checked songs and videos", nil, ""),
            ]
            if let c = d.sync?.convert {
                o.append(("Convert higher bit rate songs to \(c.kbps) kbps AAC", true,
                          "\(c.atCap) of \(c.sampled) sampled tracks sit exactly at \(c.kbps) kbps, and none above it"))
            } else {
                o.append(("Convert higher bit rate songs to AAC", nil, ""))
            }
            o.append(("Manually manage music and videos", nil,
                      "iTunes refuses tracks dropped on a device unless this is on"))
            o.append(("Enable disk use", d.diskUse, d.mountPoint.map { "mounted at \($0)" } ?? ""))
            options = o
            note = "A dash means iTunes keeps that setting in its library database, where nothing "
                + "outside iTunes can read or change it — its window reports no accessible "
                + "controls either. The ticked ones were established from the device itself. "
                + "Change any of them in iTunes on the MacBook Pro."
        }
        optionsTitle = d.unavailableReason == nil ? "Options" : "Why this page is short"
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var y = bounds.maxY
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(19), .foregroundColor: NSColor(white: 0.10, alpha: 1),
        ]
        y -= 26
        (title as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: titleAttrs)

        // Identity box: fields on the left, software version on the right.
        y -= 14
        let boxH = max(CGFloat(left.count) * 20 + 24, 92)
        let box = NSRect(x: 0, y: y - boxH, width: bounds.width, height: boxH)
        DeviceSummaryView.drawBox(box)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(12, bold: true), .foregroundColor: NSColor(white: 0.20, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(12), .foregroundColor: NSColor(white: 0.20, alpha: 1),
        ]
        var fy = box.maxY - 28
        for (name, value) in left {
            let w = (name as NSString).size(withAttributes: labelAttrs).width
            (name as NSString).draw(at: NSPoint(x: box.minX + 18, y: fy), withAttributes: labelAttrs)
            (value as NSString).draw(at: NSPoint(x: box.minX + 18 + w + 6, y: fy), withAttributes: valueAttrs)
            fy -= 20
        }
        let rx = box.minX + max(300, box.width * 0.52)
        if let v = softwareVersion {
            ("Software Version \(v)" as NSString).draw(at: NSPoint(x: rx, y: box.maxY - 28), withAttributes: labelAttrs)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            ("Read from iTunes' own record of this device. iTunes checks for iPod software updates itself." as NSString)
                .draw(in: NSRect(x: rx, y: box.minY + 10, width: box.maxX - rx - 18, height: box.maxY - 52 - box.minY),
                      withAttributes: [.font: Aqua.font(11), .foregroundColor: NSColor(white: 0.35, alpha: 1),
                                       .paragraphStyle: para])
        }

        // Options box.
        y = box.minY - 24
        (optionsTitle as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: [
            .font: Aqua.font(15), .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        y -= 10
        let noteHeight = DeviceSummaryView.height(of: note, width: bounds.width - 40)
        let optH = CGFloat(options.count) * 22 + noteHeight + 34
        let obox = NSRect(x: 0, y: y - optH, width: bounds.width, height: optH)
        DeviceSummaryView.drawBox(obox)
        var oy = obox.maxY - 28
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(11), .foregroundColor: NSColor(white: 0.50, alpha: 1),
        ]
        for (name, value, detail) in options {
            DeviceSummaryView.drawMark(at: NSPoint(x: obox.minX + 20, y: oy + 5), value: value)
            let attrs = value == nil ? [NSAttributedString.Key.font: Aqua.font(12),
                                        .foregroundColor: NSColor(white: 0.45, alpha: 1)] : valueAttrs
            (name as NSString).draw(at: NSPoint(x: obox.minX + 38, y: oy), withAttributes: attrs)
            if !detail.isEmpty {
                let w = (name as NSString).size(withAttributes: attrs).width
                ("— " + detail as NSString).draw(at: NSPoint(x: obox.minX + 44 + w, y: oy + 1),
                                                 withAttributes: dimAttrs)
            }
            oy -= 22
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        (note as NSString).draw(in: NSRect(x: obox.minX + 20, y: obox.minY + 12,
                                           width: obox.width - 40, height: noteHeight),
                                withAttributes: [.font: Aqua.font(11),
                                                 .foregroundColor: NSColor(white: 0.40, alpha: 1),
                                                 .paragraphStyle: para])
    }

    /// How tall the note runs at this width, so its box is never too short.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: Aqua.font(11), .paragraphStyle: para]
        let r = (text as NSString).boundingRect(
            with: NSSize(width: width, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        return ceil(r.height) + 4
    }

    static func drawBox(_ r: NSRect) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor(white: 0.925, alpha: 1).setFill()
        box.fill()
        NSColor(white: 0.78, alpha: 1).setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    /// A read-only mark: tick for established, empty for established-off, a
    /// dash for a setting iTunes does not expose. It reflects iTunes' state
    /// and never sets it, so it is drawn rather than being a control.
    static func drawMark(at p: NSPoint, value: Bool?) {
        guard let value = value else {
            NSColor(white: 0.55, alpha: 1).setFill()
            NSRect(x: p.x - 5, y: p.y - 1, width: 10, height: 1.6).fill()
            return
        }
        drawTick(at: p, on: value)
    }

    static func drawTick(at p: NSPoint, on: Bool) {
        let box = NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        NSColor(white: on ? 0.99 : 0.94, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard on else { return }
        let tick = NSBezierPath()
        tick.lineWidth = 1.8
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round
        tick.move(to: NSPoint(x: box.minX + 2.6, y: box.midY))
        tick.line(to: NSPoint(x: box.minX + 5, y: box.minY + 2.8))
        tick.line(to: NSPoint(x: box.maxX - 2.2, y: box.maxY - 2))
        Aqua.accent.setStroke()
        tick.stroke()
    }

    /// A small iPod, drawn, for when the daemon has no picture for the device.
    static func drawIPod(in rect: NSRect) {
        let w = rect.width * 0.62
        let body = NSRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
        let path = NSBezierPath(roundedRect: body, xRadius: w * 0.10, yRadius: w * 0.10)
        NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.14, alpha: 1))!
            .draw(in: path, angle: -90)
        NSColor(white: 0.08, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let screen = NSRect(x: body.minX + w * 0.11, y: body.midY + body.height * 0.06,
                            width: w * 0.78, height: body.height * 0.36)
        NSColor(white: 0.06, alpha: 1).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2).fill()
        let wheelR = w * 0.34
        let cy = body.minY + body.height * 0.24
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.midX - wheelR, y: cy - wheelR, width: wheelR * 2, height: wheelR * 2)).fill()
        let hubR = wheelR * 0.40
        NSColor(white: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: body.midX - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2)).fill()
    }
}

// MARK: - Capacity bar

/// iTunes' capacity bar: one band per media kind with its name written inside,
/// and the free space named in the empty part.
final class CapacityBarView: NSView {
    private struct Band {
        let label: String
        let bytes: Int
        let color: NSColor
        let dark: Bool
    }
    private var bands: [Band] = []
    private var capacity = 0
    private var freeLabel = ""

    private static let colors: [String: NSColor] = [
        "Music": NSColor(srgbRed: 0.94, green: 0.55, blue: 0.44, alpha: 1),
        "Movies": NSColor(srgbRed: 0.44, green: 0.66, blue: 0.86, alpha: 1),
        "TV Shows": NSColor(srgbRed: 0.66, green: 0.55, blue: 0.82, alpha: 1),
        "Podcasts": NSColor(srgbRed: 0.50, green: 0.75, blue: 0.55, alpha: 1),
        "Books": NSColor(srgbRed: 0.80, green: 0.66, blue: 0.44, alpha: 1),
        "Audiobooks": NSColor(srgbRed: 0.86, green: 0.74, blue: 0.36, alpha: 1),
        "Tones": NSColor(srgbRed: 0.55, green: 0.78, blue: 0.60, alpha: 1),
    ]
    private static let otherColor = NSColor(srgbRed: 0.96, green: 0.79, blue: 0.26, alpha: 1)
    private static let freeColor = NSColor(white: 0.91, alpha: 1)

    func show(_ d: DeviceDetail) {
        capacity = d.capacity ?? 0
        var b: [Band] = []
        for c in d.categories where c.bytes > 0 {
            // iTunes calls the music band "Audio".
            let label = c.name == "Music" ? "Audio" : c.name
            b.append(Band(label: label, bytes: c.bytes,
                          color: CapacityBarView.colors[c.name] ?? CapacityBarView.otherColor, dark: false))
        }
        if let other = d.otherBytes, other > 0 {
            b.append(Band(label: "Other", bytes: other, color: CapacityBarView.otherColor, dark: false))
        }
        if let free = d.freeSpace, free > 0 {
            b.append(Band(label: "", bytes: free, color: CapacityBarView.freeColor, dark: true))
            freeLabel = "\(DeviceFormat.size(free)) Free"
        } else {
            freeLabel = ""
        }
        bands = b
        toolTip = bands.filter { !$0.label.isEmpty }
            .map { "\($0.label)  \(DeviceFormat.size($0.bytes))" }
            .joined(separator: "\n")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard capacity > 0, !bands.isEmpty else { return }
        let bar = bounds.insetBy(dx: 0.5, dy: 0.5)
        let clip = NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        var x = bar.minX
        for band in bands {
            // A band under a pixel wide still gets a hairline, so a small
            // category never silently disappears.
            let w = max(1, bar.width * CGFloat(band.bytes) / CGFloat(capacity))
            let r = NSRect(x: x, y: bar.minY, width: w, height: bar.height)
            band.color.setFill()
            r.fill()
            let text = band.dark ? freeLabel : band.label
            if !text.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Aqua.font(11),
                    .foregroundColor: band.dark ? NSColor(white: 0.30, alpha: 1) : NSColor(white: 0.16, alpha: 1),
                ]
                let size = (text as NSString).size(withAttributes: attrs)
                if size.width + 12 < w {
                    // The free-space figure is centred in the grey it is
                    // describing; a media band is labelled from its left edge,
                    // the way iTunes labels them.
                    let x = band.dark ? r.midX - size.width / 2 : r.minX + 6
                    (text as NSString).draw(at: NSPoint(x: x, y: r.midY - size.height / 2),
                                            withAttributes: attrs)
                }
            }
            x += w
            if x < bar.maxX {
                NSColor(white: 1, alpha: 0.6).setFill()
                NSRect(x: x - 0.5, y: bar.minY, width: 1, height: bar.height).fill()
            }
        }
        NSGradient(starting: NSColor(white: 1, alpha: 0.30), ending: NSColor(white: 1, alpha: 0.0))!
            .draw(in: NSRect(x: bar.minX, y: bar.midY, width: bar.width, height: bar.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.58, alpha: 1).setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }
}

// MARK: - Units

enum DeviceFormat {
    /// iTunes writes device sizes in binary units but labels them GB: a
    /// 159,839,977,472-byte iPod reads as "148.87 GB" on its Summary pane.
    static func size(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1073741824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1048576
        return String(format: "%.1f MB", mb)
    }

    /// The size printed on the box, which is what iTunes puts on the badge.
    static func marketingSize(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_000_000_000
        for step in [8, 16, 20, 30, 32, 40, 60, 64, 80, 120, 128, 160, 256, 512] {
            if abs(gb - Double(step)) / Double(step) < 0.08 { return "\(step)GB" }
        }
        return String(format: "%.0fGB", gb)
    }
}

// MARK: - A small read-only table

/// A plain string grid. The device's content lists are read-only, so they
/// need none of the track table's machinery.
@MainActor
final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scrollView = NSScrollView()
    var rows: [[String]] = [] { didSet { table.reloadData() } }

    init(columns: [(String, CGFloat)]) {
        super.init()
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 18
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = Aqua.gridLine
        table.headerView = NSTableHeaderView()
        for (i, col) in columns.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            c.title = col.0
            c.width = col.1
            c.headerCell.font = Aqua.font(11)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = AquaScroller()
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue,
              let i = Int(id.dropFirst()), row < rows.count, i < rows[row].count else { return nil }
        let cell = AquaTables.labelCell(tableView, id: "simple")
        cell.textField?.font = Aqua.font(11)
        cell.textField?.stringValue = rows[row][i]
        cell.textField?.alignment = i == rows[row].count - 1 ? .right : .left
        return cell
    }
}


// MARK: - Navigation strip

/// iTunes 12's back and forward arrows with the device's name on a pill
/// between them. Back at the first pane leaves the device, as iTunes' does.
final class DeviceNavBar: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var canGoBack = true { didSet { needsDisplay = true } }
    var canGoForward = false { didSet { needsDisplay = true } }
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    private var pressed: Int?

    private func arrowRect(_ i: Int) -> NSRect {
        NSRect(x: 12 + CGFloat(i) * 27, y: bounds.midY - 10, width: 25, height: 20)
    }

    private var pillRect: NSRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: Aqua.font(12, bold: true)]
        let w = max(70, (title as NSString).size(withAttributes: attrs).width + 22)
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - 10, width: w, height: 19)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0...1 where arrowRect(i).contains(p) {
            guard i == 0 ? canGoBack : canGoForward else { return }
            pressed = i
            needsDisplay = true
            while true {
                guard let e = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
                if e.type == .leftMouseUp {
                    let up = arrowRect(i).contains(convert(e.locationInWindow, from: nil))
                    pressed = nil
                    needsDisplay = true
                    if up { i == 0 ? onBack() : onForward() }
                    return
                }
            }
            pressed = nil
            needsDisplay = true
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(white: 0.94, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))!
            .draw(in: bounds, angle: -90)
        NSColor(white: 0.68, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        for i in 0...1 {
            let r = arrowRect(i)
            let enabled = i == 0 ? canGoBack : canGoForward
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if pressed == i {
                NSGradient(starting: NSColor(white: 0.66, alpha: 1), ending: NSColor(white: 0.78, alpha: 1))!
                    .draw(in: path, angle: -90)
            } else {
                NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.87, alpha: 1))!
                    .draw(in: path, angle: -90)
            }
            NSColor(white: 0.52, alpha: 1).setStroke()
            path.lineWidth = 1
            path.stroke()
            (enabled ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.66, alpha: 1)).setFill()
            let a = NSBezierPath()
            let cx = r.midX, cy = r.midY, d: CGFloat = i == 0 ? 1 : -1
            a.move(to: NSPoint(x: cx + 2.5 * d, y: cy + 4.5))
            a.line(to: NSPoint(x: cx - 2.5 * d, y: cy))
            a.line(to: NSPoint(x: cx + 2.5 * d, y: cy - 4.5))
            a.close()
            a.fill()
        }

        guard !title.isEmpty else { return }
        let r = pillRect
        let pill = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.60, blue: 0.92, alpha: 1),
                   ending: NSColor(srgbRed: 0.16, green: 0.45, blue: 0.86, alpha: 1))!
            .draw(in: pill, angle: -90)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (title as NSString).draw(in: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 16), withAttributes: [
            .font: Aqua.font(12, bold: true), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
    }
}

// MARK: - Music settings

/// iTunes' Music pane, laid out as iTunes lays it out: the Sync Music header
/// and song count, the source options, and the four lists of Playlists,
/// Artists, Genres and Albums with a search field over them.
///
/// The marks are read, not set. iTunes keeps its sync selection in its library
/// database — not in the scripting dictionary, not in any preference file, and
/// not in the accessibility tree, since iTunes 12.9.5's window reports no UI
/// elements at all. So a mark here means "this reached the iPod", which is
/// readable and is what the selection produced. The pane says so above the
/// lists rather than offering switches that could not take.
@MainActor
final class DeviceMusicView: NSView {
    /// Adds or removes the tracks of one list row from the sync.
    var onEdit: (DeviceMusicView.Row, Bool) -> Void = { _, _ in }

    struct Row {
        enum Kind { case playlist, artist, genre, album }
        let kind: Kind
        let name: String
        /// Set for playlists, so a change can be made without a name lookup.
        let playlistId: String?
        let onDevice: Bool
    }

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let heading = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let optionsBox = SyncOptionsBox()
    private let caveat = NSTextField(labelWithString: "")
    private let lists: [CheckListView] = [
        CheckListView(title: "Playlists"), CheckListView(title: "Artists on iPod"),
        CheckListView(title: "Genres on iPod"), CheckListView(title: "Albums on iPod"),
    ]
    private var sync: DeviceSync?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = AquaScroller()
        scroll.drawsBackground = false
        doc.wantsLayer = false
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        heading.font = Aqua.font(19)
        heading.stringValue = "Sync Music"
        count.font = Aqua.font(15)
        count.textColor = NSColor(white: 0.35, alpha: 1)
        caveat.font = Aqua.font(11)
        caveat.textColor = NSColor(white: 0.42, alpha: 1)
        caveat.lineBreakMode = .byWordWrapping
        caveat.maximumNumberOfLines = 2
        caveat.stringValue = "Playlists shows what syncs to the iPod. The Artists, Genres and Albums "
            + "lists show what is on the iPod — a Beatles album can be there through a synced "
            + "playlist even when the Beatles artist itself was never ticked. iTunes keeps its own "
            + "artist/album/genre selection in its library database, which nothing outside iTunes can "
            + "read. Use Add to iPod on a track to change what syncs."
        search.placeholderString = "Search"
        search.controlSize = .small
        search.font = Aqua.font(11)
        search.target = self
        search.action = #selector(searchChanged(_:))
        for v in [heading, count, search, optionsBox, caveat] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(v)
        }
        for (i, l) in lists.enumerated() {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.onToggle = { [weak self] row in self?.toggle(row) }
            // Playlists is the one true selection list; the other three report
            // what is actually on the device.
            l.onlyOnDevice = i != 0
            doc.addSubview(l)
        }
        doc.translatesAutoresizingMaskIntoConstraints = false
        let listH: CGFloat = 260
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),

            heading.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            heading.topAnchor.constraint(equalTo: doc.topAnchor, constant: 2),
            count.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 10),
            count.lastBaselineAnchor.constraint(equalTo: heading.lastBaselineAnchor),
            search.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            search.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            search.widthAnchor.constraint(equalToConstant: 190),

            optionsBox.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            optionsBox.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            optionsBox.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            optionsBox.heightAnchor.constraint(equalToConstant: 96),

            caveat.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            caveat.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            caveat.topAnchor.constraint(equalTo: optionsBox.bottomAnchor, constant: 10),
        ])
        // Two columns of two, as iTunes arranges them.
        let mid = doc.leadingAnchor.anchorWithOffset(to: doc.trailingAnchor)
        _ = mid
        for (i, l) in lists.enumerated() {
            let left = i % 2 == 0
            let topAnchor: NSLayoutYAxisAnchor = i < 2 ? caveat.bottomAnchor : lists[i - 2].bottomAnchor
            NSLayoutConstraint.activate([
                l.topAnchor.constraint(equalTo: topAnchor, constant: 14),
                l.heightAnchor.constraint(equalToConstant: listH),
                left ? l.leadingAnchor.constraint(equalTo: doc.leadingAnchor)
                     : l.leadingAnchor.constraint(equalTo: doc.centerXAnchor, constant: 8),
                left ? l.trailingAnchor.constraint(equalTo: doc.centerXAnchor, constant: -8)
                     : l.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -16),
            ])
        }
        lists[3].bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func searchChanged(_ sender: Any?) {
        let text = search.stringValue
        for l in lists { l.filter = text }
    }

    private func toggle(_ row: Row) {
        onEdit(row, !row.onDevice)
    }

    func show(_ sync: DeviceSync) {
        self.sync = sync
        let n = NumberFormatter.localizedString(from: NSNumber(value: sync.songsOnDevice), number: .decimal)
        count.stringValue = "\(n) songs"
        optionsBox.wholeLibrary = sync.syncsWholeLibrary
        // The four lists are populated by showLibrary, which has the full
        // library plus the device marks. show() only refreshes the header and
        // options, so a 15-second device refresh never drops the playlists
        // that are not yet on the iPod.
    }

    /// The library's own lists, marked against what is on the device.
    func showLibrary(playlists: [Playlist], artists: [String], genres: [String], albums: [String],
                     device: DeviceFacets) {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        let onDeviceArtists = Set(device.artists.map(key))
        let onDeviceGenres = Set(device.genres.map(key))
        let onDeviceAlbums = Set(device.albums.map(key))
        let syncedNames = Set((sync?.playlists ?? []).map { key($0.name) })
        lists[0].rows = playlists.map {
            Row(kind: .playlist, name: $0.name, playlistId: $0.persistentId,
                onDevice: syncedNames.contains(key($0.name)))
        }
        lists[1].rows = artists.map {
            Row(kind: .artist, name: $0, playlistId: nil, onDevice: onDeviceArtists.contains(key($0)))
        }
        lists[2].rows = genres.map {
            Row(kind: .genre, name: $0, playlistId: nil, onDevice: onDeviceGenres.contains(key($0)))
        }
        lists[3].rows = albums.map {
            Row(kind: .album, name: $0, playlistId: nil, onDevice: onDeviceAlbums.contains(key($0)))
        }
    }
}

/// The box under the Sync Music heading: the two source choices and the two
/// extra switches, drawn as the read-only marks they are.
final class SyncOptionsBox: NSView {
    var wholeLibrary = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        DeviceSummaryView.drawBox(bounds)
        let text: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(12), .foregroundColor: NSColor(white: 0.16, alpha: 1),
        ]
        let dim: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(12), .foregroundColor: NSColor(white: 0.50, alpha: 1),
        ]
        // One rhythm for all four rows, each mark centred on its text line.
        let rowH: CGFloat = 21
        let markX = bounds.minX + 22
        let textX = bounds.minX + 38
        let top = bounds.maxY - 20
        func line(_ i: Int) -> CGFloat { top - CGFloat(i) * rowH }
        func drawRow(_ i: Int, _ label: String, attrs: [NSAttributedString.Key: Any],
                     mark: (NSPoint) -> Void) {
            let y = line(i)
            mark(NSPoint(x: markX, y: y + 6))
            (label as NSString).draw(at: NSPoint(x: textX, y: y), withAttributes: attrs)
        }
        drawRow(0, "Entire music library", attrs: text) {
            SyncOptionsBox.radio(at: $0, on: wholeLibrary)
        }
        drawRow(1, "Selected playlists, artists, albums, and genres", attrs: text) {
            SyncOptionsBox.radio(at: $0, on: !wholeLibrary)
        }
        // iTunes draws these two as checkboxes. This remote cannot read or set
        // them, so they are drawn disabled — present, but plainly not live.
        drawRow(2, "Include videos", attrs: dim) {
            SyncOptionsBox.disabledCheck(at: $0)
        }
        drawRow(3, "Automatically fill free space with songs", attrs: dim) {
            SyncOptionsBox.disabledCheck(at: $0)
        }
    }

    /// A greyed, empty checkbox: the control exists in iTunes but cannot be
    /// touched from here.
    static func disabledCheck(at p: NSPoint) {
        let r = NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        NSColor(white: 0.93, alpha: 1).setFill()
        box.fill()
        NSColor(white: 0.68, alpha: 1).setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    static func radio(at p: NSPoint, on: Bool) {
        let r = NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        NSColor(white: on ? 0.99 : 0.95, alpha: 1).setFill()
        ring.fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        ring.lineWidth = 1
        ring.stroke()
        guard on else { return }
        Aqua.accent.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 3.5, dy: 3.5)).fill()
    }
}

/// One of the four boxed lists, with a title above it and a mark per row.
@MainActor
final class CheckListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [DeviceMusicView.Row] = [] { didSet { applyFilter() } }
    var filter = "" { didSet { applyFilter() } }
    var onToggle: (DeviceMusicView.Row) -> Void = { _ in }
    /// When set, only rows that are on the device are listed — for the lists
    /// that report contents rather than a selection iTunes won't reveal.
    var onlyOnDevice = false { didSet { applyFilter() } }
    var title: String = "" { didSet { titleLabel.stringValue = title } }

    private let titleLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var shown: [DeviceMusicView.Row] = []

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = Aqua.font(15)
        titleLabel.textColor = NSColor(white: 0.12, alpha: 1)
        table.headerView = nil
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = AquaScroller()
        scroll.borderType = .bezelBorder
        for v in [titleLabel, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyFilter() {
        var base = onlyOnDevice ? rows.filter { $0.onDevice } : rows
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !f.isEmpty { base = base.filter { $0.name.lowercased().contains(f) } }
        shown = base
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let ident = NSUserInterfaceItemIdentifier("cell.checkRow")
        let cell = (tableView.makeView(withIdentifier: ident, owner: nil) as? CheckRowView) ?? {
            let v = CheckRowView()
            v.identifier = ident
            return v
        }()
        cell.configure(shown[row])
        return cell
    }
}

/// A row: the mark, then the name. The mark is drawn rather than being a
/// control, because nothing outside iTunes can change what it reports.
final class CheckRowView: NSView {
    private var name = ""
    private var onDevice = false

    func configure(_ row: DeviceMusicView.Row) {
        name = row.name
        onDevice = row.onDevice
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DeviceSummaryView.drawMark(at: NSPoint(x: 12, y: bounds.midY), value: onDevice ? true : false)
        (name as NSString).draw(in: NSRect(x: 26, y: bounds.midY - 8, width: bounds.width - 32, height: 16),
                                withAttributes: [
                                    .font: Aqua.font(12),
                                    .foregroundColor: onDevice ? NSColor(white: 0.12, alpha: 1)
                                                               : NSColor(white: 0.42, alpha: 1),
                                ])
    }
}
