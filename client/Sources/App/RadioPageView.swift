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
    /// Mark these as favorites, or unmark them when they all are.
    var onToggleFavorite: ([RadioStation]) -> Void = { _ in }
    var onRemove: ([RadioStation]) -> Void = { _ in }
    var onPopular: () -> Void = {}
    /// Stop the station and leave the radio.
    var onStop: () -> Void = {}
    /// The Style or Country menu changed.
    var onFilterChanged: () -> Void = {}
    /// Stations iTunes over there has refused, so the Plays On column can
    /// say so. Set by the window.
    var refusedOverThere: Set<String> = [] { didSet { table.reloadData() } }
    /// The names for the Plays On column: iTunes' Mac, and this one.
    var overThereName = "iTunes"

    static let styles = ["alternative", "ambient", "blues", "chillout", "christian", "classic rock", "classical", "comedy",
                         "country", "dance", "disco", "electronic", "folk", "funk", "gospel", "hip hop", "house", "indie",
                         "jazz", "kids", "latin", "lofi", "metal", "news", "oldies", "pop", "public radio", "punk",
                         "r&b", "reggae", "rock", "salsa", "smooth jazz", "soul", "sports", "talk", "techno", "world",
                         "60s", "70s", "80s", "90s", "00s"]
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var countries: [RadioCountry] = []

    /// What the menus have fixed.
    var filter: RadioFilter {
        var f = RadioFilter()
        if stylePopup.indexOfSelectedItem > 0 { f.tag = stylePopup.titleOfSelectedItem }
        if countryPopup.indexOfSelectedItem > 0, let c = countryPopup.selectedItem?.representedObject as? RadioCountry {
            f.countryCode = c.code
            f.countryName = c.name
        }
        return f
    }

    /// Sets the menus from outside (the `--radio-filter` test flag).
    func setFilter(tag: String?, countryCode: String?) {
        if let t = tag, let i = RadioPageView.styles.firstIndex(of: t) { stylePopup.selectItem(at: i + 1) } else { stylePopup.selectItem(at: 0) }
        if let c = countryCode, let i = countries.firstIndex(where: { $0.code == c.uppercased() }) { countryPopup.selectItem(at: i + 1) }
        else { countryPopup.selectItem(at: 0) }
        onFilterChanged()
    }

    func setCountries(_ list: [RadioCountry]) {
        countries = list
        let keep = (countryPopup.selectedItem?.representedObject as? RadioCountry)?.code
        countryPopup.removeAllItems()
        countryPopup.addItem(withTitle: "Any Country")
        for c in list {
            countryPopup.addItem(withTitle: c.name)
            countryPopup.lastItem?.representedObject = c
        }
        if let k = keep, let i = list.firstIndex(where: { $0.code == k }) { countryPopup.selectItem(at: i + 1) }
    }

    /// What the table shows, with the model's reason where it gave one.
    private(set) var stations: [RadioStation] = []
    private var why: [String: String] = [:]
    /// The favorites page is on show.
    private(set) var favoritesOpen = false
    /// Which stations are favorites, for the heart column and the button.
    var favorites: Set<String> = [] { didSet { table.reloadData(); updateButtons() } }
    /// The listening history on show: when each station was last played.
    private(set) var historyOpen = false
    private var played: [String: String] = [:]
    var playingUUID: String? { didSet { if playingUUID != oldValue { table.reloadData(); updateButtons() } } }

    let table = AquaTableView()
    let field = NSTextField()
    private let map = MKMapView()
    private let tableScroll = NSScrollView()
    private let searchButton = AquaPushButton(title: "Search")
    private let clearButton = AquaPushButton(title: "Clear")
    private let resetButton = AquaPushButton(title: "Reset")
    private let askButton = AquaPushButton(title: "Ask", isDefault: true)
    private let popularButton = AquaPushButton(title: "Popular")
    private let playButton = AquaPushButton(title: "Play")
    private let stopButton = AquaPushButton(title: "Stop")
    private let removeButton = AquaPushButton(title: "Remove")
    private let favoriteButton = AquaPushButton(title: "Favorite")
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
        /// Placed by its stated town or country, not by the directory's coordinates.
        let approximate: Bool
        init(_ s: RadioStation, at c: CLLocationCoordinate2D, approximate: Bool) {
            uuid = s.uuid
            coordinate = c
            title = s.name
            subtitle = approximate ? "near \(s.place)" : s.place
            self.approximate = approximate
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [heading as NSView, field, clearButton, stylePopup, countryPopup, resetButton, searchButton, askButton, popularButton, noteLabel, split, statusLabel, playButton, stopButton, favoriteButton, removeButton] {
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
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        clearButton.target = self
        clearButton.action = #selector(clearSearch(_:))
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite(_:))
        resetButton.target = self
        resetButton.action = #selector(resetFilters(_:))

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
        // Station and Why take the spare width; the rest keep theirs, and
        // Stream and Listeners cannot be squeezed to two letters.
        for (id, title, width, min, right, stretch) in [
            ("fav", "♥", 24.0, 24.0, false, false), ("name", "Station", 190.0, 120.0, false, true), ("place", "Where", 130.0, 80.0, false, false),
            ("tags", "Style", 160.0, 80.0, false, false), ("quality", "Stream", 80.0, 80.0, true, false),
            ("clicks", "Listeners", 66.0, 66.0, true, false), ("plays", "Plays On", 96.0, 80.0, false, false),
            ("why", "Why", 170.0, 100.0, false, true), ("played", "Played", 150.0, 110.0, false, false),
        ] as [(String, String, CGFloat, CGFloat, Bool, Bool)] {
            let c = AquaTables.column(id, title: title, width: width, min: min, sortable: false, rightAligned: right)
            c.resizingMask = stretch ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        AquaTables.style(table, rowHeight: 18, header: true)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
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
        split.delegate = self
        leftPane.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        rightPane.frame = NSRect(x: 461, y: 0, width: 600, height: 400)
        split.addSubview(leftPane)
        split.addSubview(rightPane)

        // Style and country: fixed for every search until changed back.
        for popup in [stylePopup, countryPopup] {
            popup.font = Aqua.font(11)
            popup.controlSize = .small
            popup.target = self
            popup.action = #selector(filterChanged(_:))
        }
        stylePopup.addItem(withTitle: "Any Style")
        stylePopup.addItems(withTitles: RadioPageView.styles)
        countryPopup.addItem(withTitle: "Any Country")

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),

            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            field.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            field.heightAnchor.constraint(equalToConstant: 22),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            clearButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            stylePopup.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 10),
            stylePopup.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            stylePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 112),
            stylePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            countryPopup.leadingAnchor.constraint(equalTo: stylePopup.trailingAnchor, constant: 4),
            countryPopup.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            countryPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 132),
            countryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            resetButton.leadingAnchor.constraint(equalTo: countryPopup.trailingAnchor, constant: 2),
            resetButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            searchButton.leadingAnchor.constraint(equalTo: resetButton.trailingAnchor, constant: 10),
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

            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad + 4),
            stopButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 4),
            playButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: 2),
            playButton.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            favoriteButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: 2),
            favoriteButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: 2),
            removeButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad + 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // In a narrow window the menus give way before the field does.
        stylePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countryPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stylePopup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        countryPopup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        for b in [searchButton, askButton, popularButton, playButton, stopButton, removeButton, clearButton, resetButton, favoriteButton] {
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

    /// The map's share of the width. The divider keeps its proportion when
    /// the window is resized, so the map grows and shrinks with it, and a
    /// drag of the divider sets a new proportion that is remembered.
    private var mapFraction: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "radioMapFraction")
        return saved > 0 ? CGFloat(saved) : 0.42
    }()
    private var resizingWithWindow = false

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let w = splitView.bounds.width, h = splitView.bounds.height, d = splitView.dividerThickness
        var left = round(w * mapFraction)
        left = min(max(240, left), max(240, w - 420 - d))
        resizingWithWindow = true
        leftPane.frame = NSRect(x: 0, y: 0, width: left, height: h)
        rightPane.frame = NSRect(x: left + d, y: 0, width: max(0, w - left - d), height: h)
        resizingWithWindow = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Not from the window: the divider was dragged. Keep that proportion.
        guard !resizingWithWindow, split.bounds.width > 0 else { return }
        let f = leftPane.frame.width / split.bounds.width
        guard f > 0.1, f < 0.9, abs(f - mapFraction) > 0.001 else { return }
        mapFraction = f
        UserDefaults.standard.set(Double(f), forKey: "radioMapFraction")
    }

    // MARK: Showing stations

    /// Search results, or a picked set with reasons.
    func show(_ stations: [RadioStation], why: [String: String] = [:], note: String, heading title: String) {
        self.stations = stations
        self.why = why
        favoritesOpen = false
        historyOpen = false
        played = [:]
        heading.stringValue = title
        noteLabel.stringValue = note
        removeButton.isHidden = true
        reloadAll()
    }

    func show(history: [RadioPlay]) {
        stations = history.map { $0.station }
        why = [:]
        favoritesOpen = false
        historyOpen = true
        played = Dictionary(history.map { ($0.station.uuid, RadioHistory.when($0.date) + ($0.plays > 1 ? " · \($0.plays) times" : "")) },
                            uniquingKeysWith: { a, _ in a })
        heading.stringValue = "Recently Played"
        noteLabel.stringValue = history.isEmpty ? "Nothing yet. Every station you tune to is kept here, newest first."
            : "\(history.count) station\(history.count == 1 ? "" : "s") you have tuned to, newest first. Delete takes one off the history."
        removeButton.isHidden = false
        reloadAll()
    }

    func show(favorites: [RadioStation]) {
        stations = favorites
        why = [:]
        favoritesOpen = true
        historyOpen = false
        played = [:]
        heading.stringValue = "Favorites"
        noteLabel.stringValue = favorites.isEmpty ? "Nothing yet. Select a station and press Favorite, and it is kept here."
            : "\(favorites.count) favorite station\(favorites.count == 1 ? "" : "s"). Double-click to listen; Delete takes one off."
        removeButton.isHidden = false
        reloadAll()
    }

    private var showing = 0

    private func reloadAll() {
        // Why only when there is a why to show; Played only for the history.
        table.tableColumns.first { $0.identifier.rawValue == "why" }?.isHidden = why.isEmpty
        table.tableColumns.first { $0.identifier.rawValue == "played" }?.isHidden = !historyOpen
        table.sizeToFit()
        table.reloadData()
        showing += 1
        let generation = showing
        map.removeAnnotations(map.annotations)
        var pins: [StationAnnotation] = []
        var wanted: [String] = []
        for s in stations {
            if let lat = s.latitude, let long = s.longitude {
                pins.append(StationAnnotation(s, at: CLLocationCoordinate2D(latitude: lat, longitude: long), approximate: false))
            } else if let place = RadioGeocoder.query(for: s) {
                if let c = RadioGeocoder.shared.known(place) {
                    pins.append(StationAnnotation(s, at: c, approximate: true))
                } else {
                    wanted.append(place)
                }
            }
        }
        map.addAnnotations(pins)
        fit(pins)
        updateButtons()
        // The places not yet known come in one by one; each adds its pins.
        guard !wanted.isEmpty else { return }
        RadioGeocoder.shared.resolve(wanted) { [weak self] place, c in
            guard let self = self, self.showing == generation else { return }
            let more = self.stations.filter { !$0.hasLocation && RadioGeocoder.query(for: $0) == place }
                .map { StationAnnotation($0, at: c, approximate: true) }
            self.map.addAnnotations(more)
            self.fit(self.map.annotations.compactMap { $0 as? StationAnnotation })
        }
        updateButtons()
    }

    /// The map around the pins: the world when there are none, a region
    /// rather than a street when there is one.
    private func fit(_ pins: [StationAnnotation]) {
        if pins.isEmpty {
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25, longitude: 0),
                                             span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 200)), animated: true)
        } else if pins.count == 1 {
            map.setRegion(MKCoordinateRegion(center: pins[0].coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 8)), animated: true)
        } else {
            // showAnnotations puts the outermost pins on the edge; room for their labels.
            var rect = MKMapRect.null
            for pin in pins {
                let pt = MKMapPoint(pin.coordinate)
                rect = rect.union(MKMapRect(x: pt.x, y: pt.y, width: 0, height: 0))
            }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 50, left: 60, bottom: 50, right: 60), animated: true)
        }
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
        stopButton.isEnabled = playingUUID != nil
        removeButton.isEnabled = (favoritesOpen || historyOpen) && !table.selectedRowIndexes.isEmpty
        let sel = selectedStations
        favoriteButton.isEnabled = !sel.isEmpty
        favoriteButton.title = !sel.isEmpty && sel.allSatisfy { favorites.contains($0.uuid) } ? "Unfavorite" : "Favorite"
    }

    // MARK: Actions

    @objc private func search(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy else { return }
        if text.isEmpty { onPopular() } else { onSearch(text) }
    }

    @objc private func ask(_ sender: Any?) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        onAsk(text)
    }

    @objc private func popular(_ sender: Any?) { onPopular() }

    @objc private func stop(_ sender: Any?) { onStop() }

    /// Clear: the words go, the results go back to the menus' choice.
    @objc private func clearSearch(_ sender: Any?) {
        field.stringValue = ""
        onPopular()
    }

    /// Reset: both menus back to Any, and the results with them.
    @objc private func resetFilters(_ sender: Any?) {
        stylePopup.selectItem(at: 0)
        countryPopup.selectItem(at: 0)
        onFilterChanged()
    }

    @objc private func filterChanged(_ sender: Any?) { onFilterChanged() }

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

    @objc private func toggleFavorite(_ sender: Any?) {
        let sel = selectedStations
        guard !sel.isEmpty else { return }
        onToggleFavorite(sel)
    }

    @objc private func remove(_ sender: Any?) { removeSelection() }

    func removeSelection() {
        let sel = selectedStations
        guard favoritesOpen || historyOpen, !sel.isEmpty else { return }
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
        case "fav": text = favorites.contains(s.uuid) ? "♥" : ""
        case "name": text = s.name
        case "place": text = s.place
        case "tags": text = s.tagLine
        case "quality": text = s.quality
        case "clicks": text = s.clicks > 0 ? s.clicks.formatted() : ""
        case "plays": text = s.playableByITunes && !refusedOverThere.contains(s.uuid) ? overThereName : "This Mac"
        case "why": text = why[s.uuid] ?? ""
        case "played": text = played[s.uuid] ?? ""
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
        view.markerTintColor = pin.uuid == playingUUID ? NSColor.systemGreen
            : (pin.approximate ? NSColor(srgbRed: 0.45, green: 0.55, blue: 0.70, alpha: 1) : Aqua.accent)
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
