import Cocoa
import MapKit

/// The radio page: a search line along the top, the world on the left with
/// a pin per station, the stations on the right, and the buttons along the
/// bottom — the device and curator pages' grey and white.
///
/// Double-click a station to hear it; Return does the same. Pins and rows
/// select each other. Stations are added to the app's own lists, which sit
/// under RADIO in the sidebar.
@MainActor
final class RadioPageView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, MKMapViewDelegate {
    var onSearch: (String) -> Void = { _ in }
    var onAsk: (String) -> Void = { _ in }
    var onPlay: (RadioStation) -> Void = { _ in }
    /// Add these stations to the list with this id, or to a new one (nil).
    var onAdd: ([RadioStation], String?) -> Void = { _, _ in }
    var onRemove: ([RadioStation]) -> Void = { _ in }
    var onPopular: () -> Void = {}

    /// What the table shows, with the model's reason where it gave one.
    private(set) var stations: [RadioStation] = []
    private var why: [String: String] = [:]
    /// The list on show, when it is one of the saved ones.
    private(set) var listId: String?
    var playingUUID: String? { didSet { if playingUUID != oldValue { table.reloadData() } } }
    /// The saved lists, for the Add to menu.
    var lists: [RadioList] = [] { didSet { rebuildAddMenu() } }

    let table = AquaTableView()
    let field = NSTextField()
    private let map = MKMapView()
    private let tableScroll = NSScrollView()
    private let searchButton = AquaPushButton(title: "Search")
    private let askButton = AquaPushButton(title: "Ask", isDefault: true)
    private let popularButton = AquaPushButton(title: "Popular")
    private let playButton = AquaPushButton(title: "Play")
    private let removeButton = AquaPushButton(title: "Remove")
    private let addPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let heading = NSTextField(labelWithString: "Radio")
    private let statusLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let leftPane = NSView()
    private let rightPane = NSView()

    private var busy = false
    private var busySince: Date?
    private var busyText = ""
    private var busyTimer: Timer?
    var modelLine = "" { didSet { if !busy { statusLabel.stringValue = modelLine } } }

    final class StationAnnotation: NSObject, MKAnnotation {
        let uuid: String
        let coordinate: CLLocationCoordinate2D
        let title: String?
        let subtitle: String?
        init(_ s: RadioStation) {
            uuid = s.uuid
            coordinate = CLLocationCoordinate2D(latitude: s.latitude ?? 0, longitude: s.longitude ?? 0)
            title = s.name
            subtitle = s.place
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [heading as NSView, field, searchButton, askButton, popularButton, noteLabel, split, statusLabel, playButton, addPopup, removeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        heading.font = Aqua.font(13, bold: true)
        heading.textColor = Theme.ink(0.25)
        heading.lineBreakMode = .byTruncatingTail

        field.font = Aqua.font(13)
        field.bezelStyle = .squareBezel
        field.placeholderString = "Search stations, or ask — “late-night jazz somewhere in Portugal”"
        field.target = self
        field.action = #selector(ask(_:))
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        searchButton.target = self
        searchButton.action = #selector(search(_:))
        askButton.target = self
        askButton.action = #selector(ask(_:))
        popularButton.target = self
        popularButton.action = #selector(popular(_:))
        playButton.target = self
        playButton.action = #selector(play(_:))
        removeButton.target = self
        removeButton.action = #selector(remove(_:))

        noteLabel.font = Aqua.font(11)
        noteLabel.textColor = Theme.ink(0.35)
        noteLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = Theme.ink(0.35)
        statusLabel.lineBreakMode = .byTruncatingTail

        // The world.
        map.delegate = self
        map.mapType = .mutedStandard
        map.showsZoomControls = true
        map.showsCompass = false
        map.isPitchEnabled = false
        map.wantsLayer = true
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 0),
                                         span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 200)), animated: false)
        map.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(map)
        NSLayoutConstraint.activate([
            map.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            map.topAnchor.constraint(equalTo: leftPane.topAnchor),
            map.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
        ])

        // The stations.
        for (id, title, width, right) in [
            ("name", "Station", 200.0, false), ("place", "Where", 150.0, false), ("tags", "Style", 170.0, false),
            ("quality", "Stream", 74.0, true), ("clicks", "Listeners", 62.0, true), ("why", "Why", 180.0, false),
        ] as [(String, String, CGFloat, Bool)] {
            table.addTableColumn(AquaTables.column(id, title: title, width: width, min: 40, sortable: false, rightAligned: right))
        }
        AquaTables.style(table, rowHeight: 18, header: true)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = Theme.scrollerStyle
        tableScroll.verticalScroller = AquaScroller()
        tableScroll.borderType = .bezelBorder
        tableScroll.autohidesScrollers = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(tableScroll)
        NSLayoutConstraint.activate([
            tableScroll.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: rightPane.topAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "radioSplit"
        split.delegate = self
        leftPane.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        rightPane.frame = NSRect(x: 461, y: 0, width: 600, height: 400)
        split.addSubview(leftPane)
        split.addSubview(rightPane)

        addPopup.font = Aqua.font(11)
        addPopup.controlSize = .small
        rebuildAddMenu()

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            field.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            field.heightAnchor.constraint(equalToConstant: 22),
            field.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -2),
            searchButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            askButton.leadingAnchor.constraint(equalTo: searchButton.trailingAnchor, constant: 2),
            askButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            popularButton.leadingAnchor.constraint(equalTo: askButton.trailingAnchor, constant: 2),
            popularButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            popularButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad + 4),

            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 2),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            noteLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),

            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            split.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            split.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 6),
            split.bottomAnchor.constraint(equalTo: playButton.topAnchor, constant: -8),

            playButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad + 4),
            playButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 4),
            addPopup.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -6),
            addPopup.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            addPopup.widthAnchor.constraint(equalToConstant: 150),
            removeButton.trailingAnchor.constraint(equalTo: addPopup.leadingAnchor, constant: -2),
            removeButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [searchButton, askButton, popularButton, playButton, removeButton] {
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        updateButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.ink(0.96).setFill()
        bounds.fill()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let w = splitView.bounds.width, h = splitView.bounds.height, d = splitView.dividerThickness
        var left = leftPane.frame.width
        if left < 200 { left = round(w * 0.42) }
        left = min(max(240, left), max(240, w - 420 - d))
        leftPane.frame = NSRect(x: 0, y: 0, width: left, height: h)
        rightPane.frame = NSRect(x: left + d, y: 0, width: max(0, w - left - d), height: h)
    }

    // MARK: Showing stations

    /// Search results, or a picked set with reasons.
    func show(_ stations: [RadioStation], why: [String: String] = [:], note: String, heading title: String) {
        self.stations = stations
        self.why = why
        listId = nil
        heading.stringValue = title
        noteLabel.stringValue = note
        removeButton.isHidden = true
        reloadAll()
    }

    func show(list: RadioList) {
        stations = list.stations
        why = [:]
        listId = list.id
        heading.stringValue = list.name
        noteLabel.stringValue = list.stations.isEmpty ? "Nothing here yet. Search or ask, pick some stations, and add them to “\(list.name)”."
            : "\(list.stations.count) station\(list.stations.count == 1 ? "" : "s"). Double-click to listen; Delete takes one off the list."
        removeButton.isHidden = false
        reloadAll()
    }

    /// The stations on show as a list keep up with an edit elsewhere.
    func refresh(list: RadioList) {
        guard listId == list.id else { return }
        show(list: list)
    }

    private func reloadAll() {
        table.reloadData()
        map.removeAnnotations(map.annotations)
        let pins = stations.filter { $0.hasLocation }.map { StationAnnotation($0) }
        map.addAnnotations(pins)
        if pins.count == 1 {
            // One pin: a region, not a street.
            map.setRegion(MKCoordinateRegion(center: pins[0].coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 8)), animated: true)
        } else if !pins.isEmpty {
            map.showAnnotations(pins, animated: true)
        }
        updateButtons()
    }

    var selectedStations: [RadioStation] {
        table.selectedRowIndexes.compactMap { $0 < stations.count ? stations[$0] : nil }
    }

    func focusField() { window?.makeFirstResponder(field) }

    func setBusy(_ on: Bool) {
        busy = on
        field.isEnabled = !on
        askButton.isEnabled = !on
        searchButton.isEnabled = !on
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
        }
        updateButtons()
    }

    func setStatus(_ text: String) {
        busyText = text
        tick()
    }

    func note(_ text: String) { noteLabel.stringValue = text }

    private func tick() {
        guard busy, let since = busySince else { return }
        statusLabel.stringValue = "\(busyText) \(Int(Date().timeIntervalSince(since))) s"
    }

    private func updateButtons() {
        playButton.isEnabled = !stations.isEmpty
        addPopup.isEnabled = !stations.isEmpty
        removeButton.isEnabled = listId != nil && !table.selectedRowIndexes.isEmpty
    }

    private func rebuildAddMenu() {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "Add to List", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)   // a pull-down shows its first item as the title
        for l in lists {
            let item = NSMenuItem(title: l.name, action: #selector(addToList(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = l.id
            menu.addItem(item)
        }
        if !lists.isEmpty { menu.addItem(.separator()) }
        let new = NSMenuItem(title: "New List…", action: #selector(addToNewList(_:)), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        addPopup.menu = menu
    }

    // MARK: Actions

    /// The selection, or everything on show when nothing is selected.
    private var actionable: [RadioStation] {
        let sel = selectedStations
        return sel.isEmpty ? stations : sel
    }

    @objc private func search(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        onSearch(text)
    }

    @objc private func ask(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        onAsk(text)
    }

    @objc private func popular(_ sender: Any?) { onPopular() }

    @objc private func play(_ sender: Any?) {
        if let s = selectedStations.first ?? stations.first { onPlay(s) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < stations.count else { return }
        onPlay(stations[row])
    }

    func playSelection() {
        if let s = selectedStations.first { onPlay(s) }
    }

    @objc private func addToList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onAdd(actionable, id)
    }

    @objc private func addToNewList(_ sender: Any?) { onAdd(actionable, nil) }

    @objc private func remove(_ sender: Any?) { removeSelection() }

    func removeSelection() {
        let sel = selectedStations
        guard listId != nil, !sel.isEmpty else { return }
        onRemove(sel)
    }

    /// The station after (or before) the one playing, for Next and Previous.
    func neighbour(of uuid: String, step: Int) -> RadioStation? {
        guard let i = stations.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        let j = i + step
        return j >= 0 && j < stations.count ? stations[j] : nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { stations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < stations.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let s = stations[row]
        let right = id == "quality" || id == "clicks"
        let cell = AquaTables.labelCell(tableView, id: id, rightAligned: right)
        let text: String
        switch id {
        case "name": text = s.name
        case "place": text = s.place
        case "tags": text = s.tagLine
        case "quality": text = s.quality
        case "clicks": text = s.clicks > 0 ? s.clicks.formatted() : ""
        case "why": text = why[s.uuid] ?? ""
        default: text = ""
        }
        cell.textField?.stringValue = text
        cell.textField?.font = Aqua.font(11, bold: s.uuid == playingUUID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        // The pin follows the row.
        if let s = selectedStations.first, s.hasLocation,
           let pin = map.annotations.first(where: { ($0 as? StationAnnotation)?.uuid == s.uuid }) {
            map.selectAnnotation(pin, animated: true)
        }
    }

    // MARK: Map

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let pin = annotation as? StationAnnotation else { return nil }
        let id = "station"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
        view.annotation = pin
        view.markerTintColor = pin.uuid == playingUUID ? NSColor.systemGreen : Aqua.accent
        view.glyphText = "♪"
        view.canShowCallout = true
        view.displayPriority = .required
        view.clusteringIdentifier = nil
        return view
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let pin = view.annotation as? StationAnnotation,
              let row = stations.firstIndex(where: { $0.uuid == pin.uuid }) else { return }
        guard !table.selectedRowIndexes.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}
