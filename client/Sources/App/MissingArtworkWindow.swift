import Cocoa

/// File ▸ Find Missing Artwork…: every album the library has no cover for,
/// and a way to fill them in from the iTunes Store's catalogue.
///
/// "Find Cover" looks one album up and shows what came back, so the
/// listener can page through the matches and pick; "Find All" walks the
/// whole list and takes a match only when the artist and album names agree.
/// The picture is written to every song of the album through the daemon,
/// the same way the Info sheet does it.
///
/// This is the one place the app talks to anything but the other Mac: the
/// artist and album names go to Apple's search service, and the window
/// says so.
@MainActor
final class MissingArtworkWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static let W: CGFloat = 760, H: CGFloat = 520

    struct Candidate {
        let artist: String
        let album: String
        let imageURL: URL
        var image: NSImage?
    }

    let window: NSWindow
    private let content: ChromeView
    private let api: APIClient
    /// Covers changed for these track ids: the owner forgets its caches.
    var onArtworkSet: ([String]) -> Void = { _ in }

    private let titleLabel = NSTextField(labelWithString: "Albums Without Artwork")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let table = AquaTableView()
    private let scroll = NSScrollView()
    private let well = ArtworkWell()
    private let matchLabel = NSTextField(labelWithString: "")
    private let prevButton = AquaPushButton(title: "‹")
    private let nextButton = AquaPushButton(title: "›")
    private let findButton = AquaPushButton(title: "Find Cover", isDefault: true)
    private let useButton = AquaPushButton(title: "Use This Cover")
    private let findAllButton = AquaPushButton(title: "Find All")
    private let stopButton = AquaPushButton(title: "Stop")
    private let closeButton = AquaPushButton(title: "Close")
    private let statusLabel = NSTextField(labelWithString: "")

    private var albums: [AlbumEntry] = []
    private var status: [String: String] = [:]
    private var candidates: [Candidate] = []
    private var candidateIndex = 0
    private var candidatesFor: String?
    private var busy = false
    private var stopRequested = false
    private var loaded = false

    init(api: APIClient) {
        self.api = api
        content = ChromeView(frame: NSRect(x: 0, y: 0, width: MissingArtworkWindow.W, height: MissingArtworkWindow.H))
        content.gradientTop = NSColor(white: 0.93, alpha: 1)
        content.gradientBottom = NSColor(white: 0.88, alpha: 1)
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Missing Artwork"
        window.contentView = content
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        build()
    }

    private static func key(_ a: AlbumEntry) -> String { a.artist.lowercased() + "\u{1f}" + a.album.lowercased() }

    private func build() {
        let W = MissingArtworkWindow.W, H = MissingArtworkWindow.H
        titleLabel.font = Aqua.font(15, bold: true)
        titleLabel.textColor = NSColor(white: 0.2, alpha: 1)
        titleLabel.frame = NSRect(x: 24, y: H - 46, width: W - 48, height: 22)
        content.addSubview(titleLabel)

        bodyLabel.font = Aqua.font(11)
        bodyLabel.textColor = NSColor(white: 0.3, alpha: 1)
        bodyLabel.stringValue = "Covers come from the iTunes Store's catalogue: the artist and album names of each album you look up "
            + "are sent to Apple's search service, and nothing else leaves this Mac. Find All takes a match only when both names agree."
        bodyLabel.frame = NSRect(x: 24, y: H - 92, width: W - 48, height: 40)
        content.addSubview(bodyLabel)

        table.rowHeight = 18
        table.allowsMultipleSelection = false
        table.addTableColumn(AquaTables.column("album", title: "Album", width: 200, min: 100))
        table.addTableColumn(AquaTables.column("artist", title: "Artist", width: 150, min: 80))
        table.addTableColumn(AquaTables.column("status", title: "Status", width: 110, min: 60))
        AquaTables.style(table, rowHeight: 18, header: true)
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.verticalScroller = AquaScroller()
        scroll.borderType = .bezelBorder
        scroll.frame = NSRect(x: 24, y: 64, width: 490, height: H - 92 - 76)
        content.addSubview(scroll)

        // The candidate cover, with a way to page through the matches.
        well.frame = NSRect(x: W - 24 - 200, y: H - 92 - 192, width: 200, height: 180)
        well.onImage = { [weak self] image in self?.dropped(image) }
        well.toolTip = "The cover found; drop a picture here to use your own instead"
        content.addSubview(well)
        matchLabel.font = Aqua.font(11)
        matchLabel.textColor = NSColor(white: 0.3, alpha: 1)
        matchLabel.alignment = .center
        matchLabel.lineBreakMode = .byTruncatingTail
        matchLabel.frame = NSRect(x: W - 24 - 200, y: well.frame.minY - 20, width: 200, height: 16)
        content.addSubview(matchLabel)
        let ps = prevButton.intrinsicContentSize
        prevButton.frame = NSRect(x: well.frame.minX, y: matchLabel.frame.minY - 30, width: 36, height: ps.height)
        nextButton.frame = NSRect(x: well.frame.maxX - 36, y: matchLabel.frame.minY - 30, width: 36, height: ps.height)
        prevButton.target = self; prevButton.action = #selector(previousCandidate)
        nextButton.target = self; nextButton.action = #selector(nextCandidate)
        content.addSubview(prevButton)
        content.addSubview(nextButton)

        findButton.target = self; findButton.action = #selector(findCover)
        useButton.target = self; useButton.action = #selector(useCover)
        findAllButton.target = self; findAllButton.action = #selector(findAll)
        stopButton.target = self; stopButton.action = #selector(stop)
        closeButton.target = self; closeButton.action = #selector(close)
        var y = prevButton.frame.minY - 40
        for b in [findButton, useButton, findAllButton, stopButton] {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: well.frame.midX - 80, y: y, width: 160, height: s.height)
            content.addSubview(b)
            y -= 30
        }
        let cs = closeButton.intrinsicContentSize
        closeButton.frame = NSRect(x: W - 24 - cs.width, y: 20, width: cs.width, height: cs.height)
        content.addSubview(closeButton)

        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.3, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 24, y: 36, width: 490, height: 16)
        content.addSubview(statusLabel)
        updateButtons()
    }

    // MARK: Showing

    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        if !loaded { reload() }
    }

    /// `--find-art "Artist|Album"` (and `--find-art-apply`): the lookup and
    /// the write, driven from the command line for testing, with what
    /// happened printed to stdout.
    var scripted: (album: String, apply: Bool)?

    private func runScript() {
        guard let script = scripted else { return }
        scripted = nil
        let parts = script.album.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count == 2, let i = albums.firstIndex(where: { $0.artist.lowercased() == parts[0] && $0.album.lowercased() == parts[1] }) else {
            print("find-art: album not in the missing list"); fflush(stdout); return
        }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
        let a = albums[i]
        Task { @MainActor in
            let found = await MissingArtworkWindow.search(a)
            print("find-art: \(found.count) found; " + found.prefix(3).map { "\($0.artist) / \($0.album) agrees=\(MissingArtworkWindow.agrees($0, a))" }.joined(separator: "; "))
            fflush(stdout)
            candidates = found
            candidateIndex = 0
            candidatesFor = MissingArtworkWindow.key(a)
            if !found.isEmpty { await showCandidate(0) }
            if script.apply, let match = found.first(where: { MissingArtworkWindow.agrees($0, a) }),
               let data = try? await MissingArtworkWindow.fetch(match.imageURL), let img = NSImage(data: data) {
                let result = await apply(img, to: a)
                print("find-art: " + result)
                fflush(stdout)
            }
            updateButtons()
        }
    }

    private func reload() {
        statusLabel.stringValue = "Reading the library…"
        Task { @MainActor in
            do {
                let list = try await api.albumList(filter: TrackFilter())
                albums = list.filter { !$0.hasArtwork && !$0.album.trimmingCharacters(in: .whitespaces).isEmpty }
                loaded = true
                table.reloadData()
                runScript()
                statusLabel.stringValue = albums.isEmpty ? "Every album has artwork."
                    : "\(albums.count) album\(albums.count == 1 ? "" : "s") without artwork. Select one and click Find Cover, or Find All."
            } catch {
                statusLabel.stringValue = "Could not read the library: \(error.localizedDescription)"
            }
            updateButtons()
        }
    }

    private var selected: AlbumEntry? {
        let r = table.selectedRow
        return r >= 0 && r < albums.count ? albums[r] : nil
    }

    private func updateButtons() {
        let sel = selected
        let haveCandidate = sel != nil && candidatesFor == sel.map(MissingArtworkWindow.key) && well.image != nil
        findButton.isEnabled = !busy && sel != nil
        useButton.isEnabled = !busy && haveCandidate
        findAllButton.isEnabled = !busy && !albums.isEmpty
        stopButton.isEnabled = busy
        prevButton.isEnabled = !busy && candidates.count > 1
        nextButton.isEnabled = !busy && candidates.count > 1
        closeButton.isEnabled = !busy
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { albums.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < albums.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let a = albums[row]
        let cell = AquaTables.labelCell(tableView, id: "missing")
        switch id {
        case "album": cell.textField?.stringValue = a.title
        case "artist": cell.textField?.stringValue = a.artistName
        default: cell.textField?.stringValue = status[MissingArtworkWindow.key(a)] ?? ""
        }
        cell.textField?.font = Aqua.font(11)
        cell.textField?.textColor = (status[MissingArtworkWindow.key(a)] ?? "").hasPrefix("Set") ? NSColor(white: 0.5, alpha: 1) : .controlTextColor
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AquaTables.rowView(tableView, row: row, striped: true, background: .white, selection: .blue)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let a = selected else { return }
        if candidatesFor != MissingArtworkWindow.key(a) {
            candidates = []
            candidateIndex = 0
            candidatesFor = nil
            well.image = nil
            matchLabel.stringValue = ""
        }
        updateButtons()
    }

    // MARK: Looking up

    @objc private func findCover() {
        guard let a = selected, !busy else { return }
        busy = true
        stopRequested = false
        updateButtons()
        statusLabel.stringValue = "Looking up “\(a.title)”…"
        Task { @MainActor in
            let found = await MissingArtworkWindow.search(a)
            busy = false
            candidates = found
            candidateIndex = 0
            candidatesFor = MissingArtworkWindow.key(a)
            if found.isEmpty {
                setStatus(a, "No match")
                well.image = nil
                matchLabel.stringValue = "Nothing found"
                statusLabel.stringValue = "The store has nothing under that name. Drop a picture on the well to use your own."
            } else {
                setStatus(a, "\(found.count) found")
                statusLabel.stringValue = "\(found.count) match\(found.count == 1 ? "" : "es"). Page through them and click Use This Cover."
                await showCandidate(0)
            }
            updateButtons()
        }
    }

    private func showCandidate(_ i: Int) async {
        guard i >= 0, i < candidates.count else { return }
        candidateIndex = i
        matchLabel.stringValue = "\(i + 1) of \(candidates.count): \(candidates[i].album) — \(candidates[i].artist)"
        if candidates[i].image == nil {
            well.image = nil
            if let data = try? await MissingArtworkWindow.fetch(candidates[i].imageURL), let img = NSImage(data: data) {
                candidates[i].image = img
            }
        }
        guard candidateIndex == i else { return }
        well.image = candidates[i].image
        updateButtons()
    }

    @objc private func previousCandidate() {
        guard !candidates.isEmpty else { return }
        Task { @MainActor in await showCandidate((candidateIndex - 1 + candidates.count) % candidates.count) }
    }

    @objc private func nextCandidate() {
        guard !candidates.isEmpty else { return }
        Task { @MainActor in await showCandidate((candidateIndex + 1) % candidates.count) }
    }

    /// A picture dropped on the well replaces whatever the store offered.
    private func dropped(_ image: NSImage) {
        guard let a = selected else { return }
        candidates = [Candidate(artist: a.artistName, album: a.title, imageURL: URL(fileURLWithPath: "/"), image: image)]
        candidateIndex = 0
        candidatesFor = MissingArtworkWindow.key(a)
        well.image = image
        matchLabel.stringValue = "Your picture"
        updateButtons()
    }

    @objc private func useCover() {
        guard let a = selected, let image = well.image, !busy else { return }
        busy = true
        updateButtons()
        Task { @MainActor in
            let result = await apply(image, to: a)
            busy = false
            statusLabel.stringValue = result
            updateButtons()
        }
    }

    /// Writes the picture to every song of the album. Returns a sentence.
    private func apply(_ image: NSImage, to a: AlbumEntry) async -> String {
        guard let data = InfoPanel.coverData(image) else { return "That picture could not be read." }
        do {
            let page = try await api.tracks(filter: TrackFilter(album: a.album), limit: 5000)
            let want = a.artist.lowercased()
            let ids = page.tracks.filter { $0.displayArtist.lowercased() == want && $0.album.lowercased() == a.album.lowercased() }
                .map { $0.persistentId }
            guard !ids.isEmpty else { return "No songs found for “\(a.title)”." }
            let r = try await api.setArtwork(ids: ids, image: data)
            api.dropCache()
            onArtworkSet(ids)
            setStatus(a, r.failed == 0 ? "Set (\(r.updated))" : "Set \(r.updated), \(r.failed) failed")
            return "Artwork set on \(r.updated) song\(r.updated == 1 ? "" : "s") of “\(a.title)”."
        } catch {
            setStatus(a, "Failed")
            return "Could not set the artwork: \(error.localizedDescription)"
        }
    }

    @objc private func findAll() {
        guard !busy, !albums.isEmpty else { return }
        busy = true
        stopRequested = false
        updateButtons()
        Task { @MainActor in
            var set = 0, unsure = 0, none = 0
            for (i, a) in albums.enumerated() {
                if stopRequested { break }
                let key = MissingArtworkWindow.key(a)
                if (status[key] ?? "").hasPrefix("Set") { continue }
                statusLabel.stringValue = "\(i + 1) of \(albums.count): looking up “\(a.title)”…"
                table.scrollRowToVisible(i)
                let found = await MissingArtworkWindow.search(a)
                if let match = found.first(where: { MissingArtworkWindow.agrees($0, a) }) {
                    if let data = try? await MissingArtworkWindow.fetch(match.imageURL), let img = NSImage(data: data) {
                        _ = await apply(img, to: a)
                        set += 1
                    } else {
                        setStatus(a, "Download failed")
                    }
                } else if found.isEmpty {
                    setStatus(a, "No match")
                    none += 1
                } else {
                    setStatus(a, "\(found.count) found, unsure")
                    unsure += 1
                }
                // Apple's search service throttles anyone who hurries.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            busy = false
            statusLabel.stringValue = (stopRequested ? "Stopped. " : "Done. ")
                + "\(set) set, \(unsure) with matches to check by hand, \(none) with nothing found."
            updateButtons()
        }
    }

    @objc private func stop() { stopRequested = true }
    @objc private func close() { window.orderOut(nil) }

    private func setStatus(_ a: AlbumEntry, _ text: String) {
        status[MissingArtworkWindow.key(a)] = text
        if let i = albums.firstIndex(of: a) {
            table.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: 2))
        }
    }

    // MARK: The store

    /// The store's albums under these names, best match first.
    static func search(_ a: AlbumEntry) async -> [Candidate] {
        let various = a.artist.isEmpty || a.artist.lowercased().contains("various")
        let term = various ? a.album : a.artist + " " + a.album
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "album"),
                            URLQueryItem(name: "limit", value: "8"), URLQueryItem(name: "term", value: term)]
        guard let url = comps.url, let data = try? await fetch(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        var out: [Candidate] = []
        for r in results {
            guard let art = r["artworkUrl100"] as? String,
                  let url = URL(string: art.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else { continue }
            out.append(Candidate(artist: r["artistName"] as? String ?? "", album: r["collectionName"] as? String ?? "",
                                 imageURL: url, image: nil))
        }
        // Exact-looking matches first.
        return out.sorted { agrees($0, a) && !agrees($1, a) }
    }

    /// Both names agree, allowing for punctuation, case and a store suffix
    /// like "(Deluxe Edition)".
    static func agrees(_ c: Candidate, _ a: AlbumEntry) -> Bool {
        // Exactly, once the store's own suffixes are gone: "Abbey Road (2019
        // Mix)" is Abbey Road, but "Cassadaga: A Companion" is not Cassadaga.
        let album = simplify(c.album), want = simplify(a.album)
        guard !want.isEmpty, album == want else { return false }
        if a.artist.isEmpty || a.artist.lowercased().contains("various") { return true }
        let artist = simplify(c.artist), wantArtist = simplify(a.artist)
        return artist == wantArtist || artist.contains(wantArtist) || wantArtist.contains(artist)
    }

    private static func simplify(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        if let i = t.firstIndex(of: "("), i != t.startIndex { t = String(t[..<i]) }
        if let i = t.firstIndex(of: "["), i != t.startIndex { t = String(t[..<i]) }
        t = t.replacingOccurrences(of: "&", with: "and")
        for suffix in [" - single", " - ep", " remastered", " remaster", " deluxe edition", " deluxe"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        t = t.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return t.split(separator: " ").joined(separator: " ")
    }

    static func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "store request failed")
        }
        return data
    }
}
