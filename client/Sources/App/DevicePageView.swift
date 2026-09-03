import Cocoa

/// The device page, as iTunes 10 showed it when you picked an iPod in the
/// source list: tabs across the top, a summary panel, the capacity bar along
/// the bottom, and Sync and Eject.
///
/// Every figure on this page is read from iTunes or from the USB tree. There
/// is no tab here that iTunes cannot actually answer: the sync *settings*
/// (sync whole library, sync selected playlists, convert bit rate) are not in
/// iTunes' scripting dictionary, so they are not shown as controls that would
/// do nothing.
@MainActor
final class DevicePageView: NSView {
    var onSync: () -> Void = {}
    var onEject: () -> Void = {}

    private let tabs = DeviceTabBar(titles: ["Summary", "Music", "Playlists"])
    private let summary = DeviceSummaryView()
    private let categoryTable = SimpleTable(columns: [("On this device", 260), ("Items", 90), ("Size", 110)])
    private let playlistTable = SimpleTable(columns: [("Playlist", 360), ("Items", 90)])
    private let capacity = CapacityBarView()
    private let syncButton = AquaPushButton(title: "Sync")
    private let ejectButton = AquaPushButton(title: "Eject")
    private let statusLabel = NSTextField(labelWithString: "")
    private var detail: DeviceDetail?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [tabs as NSView, summary, categoryTable.scrollView, playlistTable.scrollView,
                  capacity, syncButton, ejectButton, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        syncButton.target = self
        syncButton.action = #selector(sync(_:))
        syncButton.isDefault = true
        ejectButton.target = self
        ejectButton.action = #selector(eject(_:))
        tabs.selectedIndex = min(2, max(0, UserDefaults.standard.integer(forKey: "deviceTab")))
        tabs.onChange = { [weak self] i in
            UserDefaults.standard.set(i, forKey: "deviceTab")
            self?.applyTab()
        }

        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            capacity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            capacity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            capacity.heightAnchor.constraint(equalToConstant: 58),
            capacity.bottomAnchor.constraint(equalTo: syncButton.topAnchor, constant: -10),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            ejectButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            syncButton.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -8),
            syncButton.centerYAnchor.constraint(equalTo: ejectButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: syncButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: ejectButton.centerYAnchor),
        ])
        for content in [summary as NSView, categoryTable.scrollView, playlistTable.scrollView] {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
                content.bottomAnchor.constraint(equalTo: capacity.topAnchor, constant: -12),
            ])
        }
        applyTab()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // The same light sheet iTunes put behind a device page.
        NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!
            .draw(in: bounds, angle: -90)
    }

    private func applyTab() {
        summary.isHidden = tabs.selectedIndex != 0
        categoryTable.scrollView.isHidden = tabs.selectedIndex != 1
        playlistTable.scrollView.isHidden = tabs.selectedIndex != 2
    }

    @objc private func sync(_ sender: Any?) { onSync() }
    @objc private func eject(_ sender: Any?) { onEject() }

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    func setBusy(_ busy: Bool) {
        syncButton.isEnabled = !busy && (detail?.syncable ?? false)
        ejectButton.isEnabled = !busy && (detail?.itunesSource ?? false)
    }

    func show(_ d: DeviceDetail) {
        detail = d
        summary.show(d)
        capacity.show(d)
        categoryTable.rows = d.categories.map {
            [$0.name, NumberFormatter.localizedString(from: NSNumber(value: $0.trackCount), number: .decimal),
             $0.bytes > 0 ? StatusFormat.size($0.bytes) : "—"]
        }
        playlistTable.rows = d.playlists.map {
            [$0.name, NumberFormatter.localizedString(from: NSNumber(value: $0.count), number: .decimal)]
        }
        syncButton.isEnabled = d.syncable
        ejectButton.isEnabled = d.itunesSource
        if let reason = d.unavailableReason {
            statusLabel.stringValue = reason
        } else if let n = d.trackCount {
            statusLabel.stringValue = "\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)) items on \(d.name)"
        } else {
            statusLabel.stringValue = ""
        }
    }
}

// MARK: - Tabs

/// Text tabs in the iTunes 10 capsule, the selected one pressed in.
final class DeviceTabBar: NSView {
    let titles: [String]
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onChange: (Int) -> Void = { _ in }
    private var widths: [CGFloat] = []

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        widths = titles.map { max(74, ($0 as NSString).size(withAttributes: [.font: Aqua.font(12, bold: true)]).width + 32) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(0, +) + 2, height: 24)
    }

    private func frame(of i: Int) -> NSRect {
        let x = widths[0..<i].reduce(0, +) + 1
        return NSRect(x: x, y: 1, width: widths[i], height: bounds.height - 2)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in titles.indices where frame(of: i).contains(p) {
            if i != selectedIndex {
                selectedIndex = i
                onChange(i)
            }
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds.insetBy(dx: 0.5, dy: 1.5)
        let capsule = NSBezierPath(roundedRect: outer, xRadius: 4, yRadius: 4)
        NSGradient(starting: NSColor(white: 0.99, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))!
            .draw(in: capsule, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()
        for i in titles.indices {
            let r = frame(of: i)
            if i == selectedIndex {
                NSGradient(starting: NSColor(white: 0.60, alpha: 1), ending: NSColor(white: 0.74, alpha: 1))!
                    .draw(in: r, angle: -90)
            }
            if i > 0 {
                NSColor(white: 0.55, alpha: 1).setFill()
                NSRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let emboss = NSShadow()
            emboss.shadowColor = (i == selectedIndex ? NSColor.black : NSColor.white).withAlphaComponent(0.6)
            emboss.shadowOffset = NSSize(width: 0, height: i == selectedIndex ? -1 : -1)
            emboss.shadowBlurRadius = 0
            let text = titles[i] as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Aqua.font(12, bold: i == selectedIndex),
                .foregroundColor: i == selectedIndex ? NSColor.white : NSColor(white: 0.20, alpha: 1),
                .paragraphStyle: style, .shadow: emboss,
            ]
            let h = text.size(withAttributes: attrs).height
            text.draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.45, alpha: 1).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
    }
}

// MARK: - Summary

/// The device icon and its identity fields, laid out as iTunes 10's Summary.
final class DeviceSummaryView: NSView {
    private var fields: [(String, String)] = []
    private var title = ""
    private var subtitle = ""

    func show(_ d: DeviceDetail) {
        title = d.name
        subtitle = [d.productName, d.kind == d.productName ? nil : d.kind]
            .compactMap { $0 }.joined(separator: " · ")
        var f: [(String, String)] = []
        if let cap = d.capacity { f.append(("Capacity", StatusFormat.size(cap))) }
        if let free = d.freeSpace { f.append(("Free space", StatusFormat.size(free))) }
        if let n = d.trackCount {
            f.append(("Items", NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)))
        }
        if let s = d.serialNumber { f.append(("Serial number", s)) }
        if let c = d.connection { f.append(("Connection", c)) }
        if let fs = d.fileSystem { f.append(("Format", fs)) }
        if let m = d.mountPoint { f.append(("Mounted at", m)) }
        fields = f
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let panelH = CGFloat(fields.count) * 19 + 96
        let panel = NSRect(x: 0, y: bounds.maxY - panelH, width: bounds.width, height: panelH)
        let box = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSGradient(starting: NSColor(white: 1.0, alpha: 0.95), ending: NSColor(white: 0.96, alpha: 0.95))!
            .draw(in: box, angle: -90)
        NSColor(white: 0.72, alpha: 1).setStroke()
        box.lineWidth = 1
        box.stroke()

        let iconSide: CGFloat = 96
        let iconRect = NSRect(x: 20, y: panel.maxY - iconSide - 16, width: iconSide, height: iconSide)
        DeviceSummaryView.drawIPod(in: iconRect)
        let left = iconRect.maxX + 20
        var y = panel.maxY - 18
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(20, bold: true), .foregroundColor: NSColor(white: 0.12, alpha: 1),
        ]
        let th = (title as NSString).size(withAttributes: titleAttrs).height
        y -= th
        (title as NSString).draw(at: NSPoint(x: left, y: y), withAttributes: titleAttrs)
        if !subtitle.isEmpty {
            let sub: [NSAttributedString.Key: Any] = [
                .font: Aqua.font(12), .foregroundColor: NSColor(white: 0.42, alpha: 1),
            ]
            y -= 18
            (subtitle as NSString).draw(at: NSPoint(x: left, y: y), withAttributes: sub)
        }
        y -= 16
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(11, bold: true), .foregroundColor: NSColor(white: 0.38, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: Aqua.font(11), .foregroundColor: NSColor(white: 0.10, alpha: 1),
        ]
        let labelWidth: CGFloat = 108
        for (name, value) in fields {
            y -= 19
            guard y > 0 else { break }
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            var la = labelAttrs
            la[.paragraphStyle] = style
            (name as NSString).draw(in: NSRect(x: left, y: y, width: labelWidth, height: 16), withAttributes: la)
            (value as NSString).draw(at: NSPoint(x: left + labelWidth + 12, y: y), withAttributes: valueAttrs)
        }
    }

    /// A small iPod, drawn: white body, screen, click wheel.
    static func drawIPod(in rect: NSRect) {
        let w = rect.width * 0.62
        let body = NSRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height)
        let path = NSBezierPath(roundedRect: body, xRadius: w * 0.10, yRadius: w * 0.10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSGradient(starting: NSColor(white: 1.0, alpha: 1), ending: NSColor(white: 0.82, alpha: 1))!
            .draw(in: path, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.58, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let screen = NSRect(x: body.minX + w * 0.11, y: body.midY + body.height * 0.06,
                            width: w * 0.78, height: body.height * 0.36)
        let sp = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)
        NSGradient(starting: NSColor(srgbRed: 0.28, green: 0.42, blue: 0.56, alpha: 1),
                   ending: NSColor(srgbRed: 0.62, green: 0.76, blue: 0.88, alpha: 1))!
            .draw(in: sp, angle: -90)
        NSColor(white: 0.45, alpha: 1).setStroke()
        sp.lineWidth = 1
        sp.stroke()
        let wheelR = w * 0.34
        let cy = body.minY + body.height * 0.24
        let wheel = NSBezierPath(ovalIn: NSRect(x: body.midX - wheelR, y: cy - wheelR, width: wheelR * 2, height: wheelR * 2))
        NSGradient(starting: NSColor(white: 0.94, alpha: 1), ending: NSColor(white: 0.80, alpha: 1))!
            .draw(in: wheel, angle: -90)
        NSColor(white: 0.62, alpha: 1).setStroke()
        wheel.lineWidth = 1
        wheel.stroke()
        let hubR = wheelR * 0.40
        let hub = NSBezierPath(ovalIn: NSRect(x: body.midX - hubR, y: cy - hubR, width: hubR * 2, height: hubR * 2))
        NSColor(white: 0.99, alpha: 1).setFill()
        hub.fill()
        NSColor(white: 0.68, alpha: 1).setStroke()
        hub.lineWidth = 1
        hub.stroke()
    }
}

// MARK: - Capacity bar

/// iTunes' capacity bar: one coloured band per media kind, free space at the
/// right, and a legend underneath. Bands under a pixel wide are still drawn as
/// a hairline so a small category does not silently vanish.
final class CapacityBarView: NSView {
    private struct Band {
        let label: String
        let bytes: Int
        let color: NSColor
    }
    private var bands: [Band] = []
    private var capacity = 0

    private static let colors: [String: NSColor] = [
        "Music": NSColor(srgbRed: 0.96, green: 0.68, blue: 0.17, alpha: 1),
        "Movies": NSColor(srgbRed: 0.51, green: 0.36, blue: 0.78, alpha: 1),
        "TV Shows": NSColor(srgbRed: 0.92, green: 0.31, blue: 0.52, alpha: 1),
        "Podcasts": NSColor(srgbRed: 0.19, green: 0.66, blue: 0.60, alpha: 1),
        "Books": NSColor(srgbRed: 0.62, green: 0.45, blue: 0.36, alpha: 1),
        "Audiobooks": NSColor(srgbRed: 0.99, green: 0.80, blue: 0.20, alpha: 1),
        "Tones": NSColor(srgbRed: 0.40, green: 0.73, blue: 0.42, alpha: 1),
        "Purchased Music": NSColor(srgbRed: 0.36, green: 0.60, blue: 0.86, alpha: 1),
    ]
    private static let otherColor = NSColor(srgbRed: 0.69, green: 0.75, blue: 0.79, alpha: 1)
    private static let freeColor = NSColor(white: 0.98, alpha: 1)

    func show(_ d: DeviceDetail) {
        capacity = d.capacity ?? 0
        var b: [Band] = []
        for c in d.categories where c.bytes > 0 {
            b.append(Band(label: c.name, bytes: c.bytes,
                          color: CapacityBarView.colors[c.name] ?? CapacityBarView.otherColor))
        }
        if let other = d.otherBytes, other > 0 {
            b.append(Band(label: "Other", bytes: other, color: CapacityBarView.otherColor))
        }
        if let free = d.freeSpace, free > 0 {
            b.append(Band(label: "Free", bytes: free, color: CapacityBarView.freeColor))
        }
        bands = b
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard capacity > 0, !bands.isEmpty else { return }
        let barH: CGFloat = 20
        let bar = NSRect(x: 0, y: bounds.maxY - barH - 2, width: bounds.width, height: barH)
        let clip = NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        var x = bar.minX
        for band in bands {
            let w = max(1, bar.width * CGFloat(band.bytes) / CGFloat(capacity))
            let r = NSRect(x: x, y: bar.minY, width: w, height: bar.height)
            NSGradient(starting: band.color.blended(withFraction: 0.28, of: .white) ?? band.color,
                       ending: band.color)!.draw(in: r, angle: -90)
            x += w
            if x < bar.maxX {
                NSColor(white: 1, alpha: 0.55).setFill()
                NSRect(x: x - 0.5, y: bar.minY, width: 1, height: bar.height).fill()
            }
        }
        // A gloss across the top half, so the bar reads like iTunes' did.
        NSGradient(starting: NSColor(white: 1, alpha: 0.42), ending: NSColor(white: 1, alpha: 0.02))!
            .draw(in: NSRect(x: bar.minX, y: bar.midY, width: bar.width, height: bar.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.52, alpha: 1).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        // Legend.
        var lx = bar.minX
        let ly = bar.minY - 22
        for band in bands {
            let swatch = NSRect(x: lx, y: ly + 3, width: 10, height: 10)
            let sp = NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2)
            band.color.setFill()
            sp.fill()
            NSColor(white: 0.45, alpha: 1).setStroke()
            sp.lineWidth = 1
            sp.stroke()
            let text = "\(band.label)  \(StatusFormat.size(band.bytes))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Aqua.font(11), .foregroundColor: NSColor(white: 0.25, alpha: 1),
            ]
            let w = text.size(withAttributes: attrs).width
            text.draw(at: NSPoint(x: swatch.maxX + 5, y: ly), withAttributes: attrs)
            lx = swatch.maxX + 5 + w + 18
            if lx > bounds.maxX - 60 { break }
        }
    }
}

// MARK: - A small read-only table

/// A plain string-grid table. The device page's two list tabs are read-only,
/// so they need none of the track table's machinery.
@MainActor
final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let scrollView = NSScrollView()
    var rows: [[String]] = [] { didSet { table.reloadData() } }

    init(columns: [(String, CGFloat)]) {
        super.init()
        table.usesAlternatingRowBackgroundColors = true
        // Let the name column take the slack; the count and size columns keep
        // their widths at the right, as iTunes' device lists did.
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
        cell.textField?.alignment = i == 0 ? .left : .right
        return cell
    }
}
