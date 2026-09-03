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
        /// A playlist on the device: its name and whether it is a special one.
        case content(String, SidebarIcon)
    }

    private var rows: [Row] = [.header("Settings"), .summary]
    private let header = DeviceHeaderView()
    private let list = NSTableView()
    private let listScroll = NSScrollView()
    private let summary = DeviceSummaryView()
    private let trackTable = SimpleTable(columns: [("Name", 300), ("Artist", 200), ("Album", 200), ("Time", 60)])
    private let capacity = CapacityBarView()
    private let syncButton = AquaPushButton(title: "Sync")
    private let doneButton = AquaPushButton(title: "Done", isDefault: true)
    private let statusLabel = NSTextField(labelWithString: "")
    private var detail: DeviceDetail?
    private var loadedPlaylist: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [header as NSView, listScroll, summary, trackTable.scrollView,
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
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.widthAnchor.constraint(equalToConstant: sidebar),
            header.heightAnchor.constraint(equalToConstant: 72),

            listScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: sidebar),
            listScroll.bottomAnchor.constraint(equalTo: capacity.topAnchor, constant: -10),

            capacity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            capacity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            capacity.heightAnchor.constraint(equalToConstant: 24),
            capacity.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -10),

            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            doneButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            syncButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            syncButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: syncButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
        ])
        for content in [summary as NSView, trackTable.scrollView] {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: pad),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                content.topAnchor.constraint(equalTo: topAnchor, constant: pad),
                content.bottomAnchor.constraint(equalTo: capacity.topAnchor, constant: -12),
            ])
        }
        trackTable.scrollView.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
        // The sidebar's own ground, and the hairline that separates it.
        Aqua.sidebarBackground.setFill()
        NSRect(x: 0, y: 0, width: 210, height: bounds.height).fill()
        NSColor(white: 0.66, alpha: 1).setFill()
        NSRect(x: 210, y: 0, width: 1, height: bounds.height).fill()
    }

    @objc private func sync(_ sender: Any?) { onSync() }
    @objc private func done(_ sender: Any?) { onDone() }

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    func setBusy(_ busy: Bool) {
        syncButton.isEnabled = !busy && (detail?.syncable ?? false)
        header.canEject = !busy && (detail?.itunesSource ?? false)
    }

    func show(_ d: DeviceDetail) {
        let firstLoad = detail?.name != d.name
        detail = d
        header.show(d)
        summary.show(d)
        capacity.show(d)
        var r: [Row] = [.header("Settings"), .summary]
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
        if firstLoad || list.selectedRow < 0 {
            list.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            showSummary()
            loadImage { [weak self] image in self?.header.image = image }
        }
        syncButton.isEnabled = d.syncable
        header.canEject = d.itunesSource
        if let reason = d.unavailableReason {
            statusLabel.stringValue = reason
        } else if let n = d.trackCount {
            statusLabel.stringValue = "\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) items on \(d.name)"
        } else {
            statusLabel.stringValue = ""
        }
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
        trackTable.scrollView.isHidden = true
    }

    private func showTracks(_ playlist: String) {
        summary.isHidden = true
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
        switch rows[list.selectedRow] {
        case .summary: showSummary()
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
    private var options: [(String, Bool?)] = []
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
        options = [("Enable disk use", d.diskUse)]
        note = "iTunes keeps its other sync settings — whole library or selected playlists, "
            + "convert higher bit rate songs, sync only checked songs — inside its library "
            + "database, where nothing outside iTunes can read or change them. Set those in "
            + "iTunes on the MacBook Pro."
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
        ("Options" as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: [
            .font: Aqua.font(15), .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ])
        y -= 10
        let optH = CGFloat(options.count) * 22 + 68
        let obox = NSRect(x: 0, y: y - optH, width: bounds.width, height: optH)
        DeviceSummaryView.drawBox(obox)
        var oy = obox.maxY - 28
        for (name, value) in options {
            DeviceSummaryView.drawTick(at: NSPoint(x: obox.minX + 20, y: oy + 5), on: value == true)
            (name as NSString).draw(at: NSPoint(x: obox.minX + 38, y: oy), withAttributes: valueAttrs)
            oy -= 22
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        (note as NSString).draw(in: NSRect(x: obox.minX + 20, y: obox.minY + 8,
                                           width: obox.width - 40, height: oy - obox.minY),
                                withAttributes: [.font: Aqua.font(11),
                                                 .foregroundColor: NSColor(white: 0.40, alpha: 1),
                                                 .paragraphStyle: para])
    }

    static func drawBox(_ r: NSRect) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor(white: 0.925, alpha: 1).setFill()
        box.fill()
        NSColor(white: 0.78, alpha: 1).setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    /// A read-only tick: this reflects iTunes' state, it does not set it.
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
                    (text as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.midY - size.height / 2),
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
