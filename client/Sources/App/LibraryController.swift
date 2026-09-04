import Foundation

enum Source: Equatable {
    case library
    case recentlyAdded
    case playlist(Playlist)

    static func == (a: Source, b: Source) -> Bool {
        switch (a, b) {
        case (.library, .library), (.recentlyAdded, .recentlyAdded): return true
        case let (.playlist(x), .playlist(y)): return x.persistentId == y.persistentId
        default: return false
        }
    }

    var playlistId: String? {
        if case let .playlist(p) = self { return p.persistentId }
        return nil
    }

    /// How many of the newest items Recently Added shows.
    var recentLimit: Int { self == .recentlyAdded ? 600 : 0 }

    var isLibrary: Bool { if case .library = self { return true }; return false }

    var displayName: String {
        switch self {
        case .library: return "Music"
        case .recentlyAdded: return "Recently Added"
        case .playlist(let p): return p.name
        }
    }
}

/// Everything the window shows, and the fetches that keep it current. The
/// browser panes cascade: genre narrows artists, artist narrows albums, and
/// all three narrow the track list. Every change bumps a generation counter
/// so a slow response for an old state is thrown away.
@MainActor
final class LibraryController {
    var api: APIClient?

    private(set) var info: LibraryInfo?
    private(set) var playlists: [Playlist] = []
    /// Facet values per browser field, and which value each pane has chosen.
    private(set) var facets: [String: [FacetEntry]] = [:]
    private(set) var selections: [String: String] = [:]
    private(set) var browserFields: [String] = ["genre", "artist", "album"]
    private(set) var tracks: [Track] = []
    private(set) var totalTime = 0
    private(set) var totalSize = 0
    private(set) var loading = false
    private(set) var lastError: String?

    var source: Source = .library { didSet { if source != oldValue { resetBrowser(); reload() } } }
    var searchText: String = "" { didSet { if searchText != oldValue { reload() } } }
    func setBrowserFields(_ fields: [String]) {
        browserFields = fields
        for key in selections.keys where !fields.contains(key) { selections[key] = nil }
    }

    func facet(_ field: String) -> [FacetEntry] { facets[field] ?? [] }
    func selection(_ field: String) -> String? { selections[field] }

    /// Choosing in a pane clears the panes to its right, as iTunes did.
    func select(_ value: String?, in field: String) {
        guard selections[field] != value else { return }
        selections[field] = value
        if let i = browserFields.firstIndex(of: field) {
            for later in browserFields[(i + 1)...] { selections[later] = nil }
        }
        reload()
    }

    func clearBrowserSelections() {
        guard !selections.isEmpty else { return }
        selections.removeAll()
    }

    var sortKey: String? = nil
    var sortAscending = true

    /// Called after any state change the window should redraw for.
    var onPlaylistsChanged: () -> Void = {}
    var onBrowserChanged: () -> Void = {}
    var onTracksChanged: () -> Void = {}
    var onStatusChanged: () -> Void = {}
    var onFirstLoad: () -> Void = {}

    private var generation = 0
    private var firstLoadDone = false

    private func resetBrowser() {
        selections.removeAll()
    }

    // MARK: Connect

    func connect(_ client: APIClient) {
        api = client
        Task { await loadLibrary() }
    }

    /// Retries the first load until it works. Without this a single failure
    /// at launch left the app sitting on an empty library forever, because
    /// nothing ever asked again.
    private var loadRetry: Timer?

    private func loadLibrary() async {
        guard let api = api else { return }
        loading = true
        onStatusChanged()
        do {
            info = try await api.libraryInfo()
            api.libraryVersion = info?.version ?? ""
            playlists = try await api.playlists()
            lastError = nil
            loadRetry?.invalidate()
            loadRetry = nil
            onPlaylistsChanged()
            startVersionPolling()
        } catch {
            lastError = error.localizedDescription + " — retrying"
            loading = false
            onStatusChanged()
            scheduleLoadRetry()
            return
        }
        reload()
    }

    /// Watches for the library changing under the app: a vinyl rip landing
    /// through the pipeline, or an edit made in iTunes itself. A change
    /// empties the read cache; one that adds or removes tracks or playlists
    /// also refreshes what is on screen.
    private var versionTimer: Timer?

    /// How often the library version is checked; longer when away.
    var versionInterval: TimeInterval = 15 {
        didSet { if versionTimer != nil, versionInterval != oldValue { startVersionPolling() } }
    }

    private func startVersionPolling() {
        versionTimer?.invalidate()
        versionTimer = Timer.scheduledTimer(withTimeInterval: versionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkVersion() }
        }
    }

    /// The Refresh button: the daemon looks at the XML now, then whatever
    /// changed is taken the way the version poll would have taken it.
    func refreshNow() async -> Bool {
        guard let api = api else { return false }
        let reloaded = (try? await api.refreshLibrary()) ?? false
        if reloaded { api.dropCache() }
        await checkVersion()
        return reloaded
    }

    private func checkVersion() async {
        guard let api = api, let known = info, !loading, let fresh = try? await api.libraryInfo() else { return }
        guard fresh.version != known.version else { return }
        info = fresh
        api.libraryVersion = fresh.version
        if fresh.trackCount != known.trackCount || fresh.playlistCount != known.playlistCount
            || fresh.contentVersion != known.contentVersion {
            if let list = try? await api.playlists() { replacePlaylists(list); onPlaylistsChanged() }
            reload()
        }
    }

    private func scheduleLoadRetry() {
        guard loadRetry == nil else { return }
        loadRetry = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.info == nil else {
                    self?.loadRetry?.invalidate()
                    self?.loadRetry = nil
                    return
                }
                await self.loadLibrary()
            }
        }
    }

    func setRating(_ persistentId: String, _ value: Int) {
        if let i = tracks.firstIndex(where: { $0.persistentId == persistentId }) {
            tracks[i].rating = value
        }
    }

    /// Mirrors a checkbox change locally without refetching the whole list.
    func setEnabled(_ persistentId: String, _ on: Bool) {
        if let i = tracks.firstIndex(where: { $0.persistentId == persistentId }) {
            tracks[i].enabled = on
        }
    }

    /// Replaces the cached playlist list after a create, add or remove.
    func replacePlaylists(_ list: [Playlist]) {
        playlists = list
        if case let .playlist(current) = source,
           let fresh = list.first(where: { $0.persistentId == current.persistentId }) {
            // Keep the selected source's count in step without reselecting it.
            source = .playlist(fresh)
        }
    }

    // MARK: Filters

    /// The filter with every pane's choice applied except those after `field`.
    private func filter(upTo field: String?) -> TrackFilter {
        var f = TrackFilter(q: searchText, playlist: source.playlistId, recent: source.recentLimit)
        for name in browserFields {
            if name == field { break }
            guard let value = selections[name] else { continue }
            switch name {
            case "genre": f.genre = value
            case "artist": f.artist = value
            case "album": f.album = value
            case "composer": f.composer = value
            case "grouping": f.grouping = value
            default: break
            }
        }
        return f
    }

    var trackFilter: TrackFilter { filter(upTo: nil) }

    // MARK: Reload

    func reload() {
        guard let api = api else { return }
        generation += 1
        let gen = generation
        loading = true
        onStatusChanged()
        let fields = browserFields
        let paneFilters = fields.map { filter(upTo: $0) }
        let trackFilter = self.trackFilter
        Task {
            do {
                var fetched: [String: [FacetEntry]] = [:]
                try await withThrowingTaskGroup(of: (String, [FacetEntry]).self) { group in
                    for (i, field) in fields.enumerated() {
                        group.addTask { (field, try await api.facet(field, filter: paneFilters[i])) }
                    }
                    for try await (field, values) in group { fetched[field] = values }
                }
                let page = try await api.tracks(filter: trackFilter)
                guard gen == generation else { return }
                self.facets = fetched
                // A choice that no longer exists in its pane falls back to All.
                var changed = false
                for field in fields {
                    if let s = selections[field], !(fetched[field] ?? []).contains(where: { $0.name == s }) {
                        selections[field] = nil
                        changed = true
                    }
                }
                if changed {
                    reload()
                    return
                }
                self.tracks = page.tracks
                self.totalTime = page.totalTime
                self.totalSize = page.totalSize
                applySort()
                lastError = nil
                loading = false
                onBrowserChanged()
                onTracksChanged()
                onStatusChanged()
                if !firstLoadDone {
                    firstLoadDone = true
                    onFirstLoad()
                }
            } catch {
                guard gen == generation else { return }
                // A failed load used to leave the track table empty with no
                // way back: the daemon restarting under a running app emptied
                // the view and nothing ever asked again. Try once more.
                lastError = error.localizedDescription
                loading = false
                onStatusChanged()
                self.scheduleReloadRetry(gen)
            }
        }
    }

    private var reloadRetry: Timer?

    private func scheduleReloadRetry(_ gen: Int) {
        reloadRetry?.invalidate()
        reloadRetry = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, gen == self.generation, self.lastError != nil else { return }
                self.reload()
            }
        }
    }

    // MARK: Sort

    func setSort(key: String?, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        applySort()
        onTracksChanged()
    }

    private func applySort() {
        guard let key = sortKey else {
            if source == .recentlyAdded {
                // Newest album first, but each album's songs in track order —
                // plain date order interleaved and scrambled a rip's sides.
                var newest: [String: String] = [:]
                for t in tracks {
                    let k = t.displayArtist.lowercased() + "\u{1f}" + t.album.lowercased()
                    if t.dateAdded > (newest[k] ?? "") { newest[k] = t.dateAdded }
                }
                tracks.sort { a, b in
                    let ka = a.displayArtist.lowercased() + "\u{1f}" + a.album.lowercased()
                    let kb = b.displayArtist.lowercased() + "\u{1f}" + b.album.lowercased()
                    let da = newest[ka] ?? "", db = newest[kb] ?? ""
                    if da != db { return da > db }
                    return LibraryController.artistKey(a) < LibraryController.artistKey(b)
                }
            }
            return
        }
        // iTunes' orders, on iTunes' sort forms. Artist is artist, then the
        // artist's albums by year, then disc and track — the same order the
        // daemon delivers by default, so clicking Artist on the library does
        // not reshuffle it. Every column sort ends in disc/track order, so
        // albums always read top to bottom. Descending reverses the lot, as
        // iTunes does.
        let asc = sortAscending
        func less<T: Comparable>(_ a: T, _ b: T, tie: () -> Bool) -> Bool {
            a == b ? tie() : (asc ? a < b : a > b)
        }
        // The artist key is six fields built from strings; made inside the
        // comparator it was built a few million times per sort of the whole
        // library. Once per track instead, then the sort moves indices.
        let artist = tracks.map(LibraryController.artistKey)
        func byArtist(_ i: Int, _ j: Int) -> Bool { artist[i] < artist[j] }
        var order = Array(tracks.indices)
        switch key {
        case "artist": order.sort { less(artist[$0], artist[$1], tie: { false }) }
        case "album":
            let album = tracks.map(LibraryController.albumKey)
            order.sort { less(album[$0], album[$1], tie: { false }) }
        case "name":
            let k = tracks.map { $0.sortName }
            order.sort { i, j in less(k[i], k[j], tie: { byArtist(i, j) }) }
        case "genre":
            let k = tracks.map { $0.genre.lowercased() }
            order.sort { i, j in less(k[i], k[j], tie: { byArtist(i, j) }) }
        case "year": order.sort { i, j in less(tracks[i].year ?? 0, tracks[j].year ?? 0, tie: { byArtist(i, j) }) }
        case "totalTime": order.sort { i, j in less(tracks[i].totalTime ?? 0, tracks[j].totalTime ?? 0, tie: { byArtist(i, j) }) }
        case "trackNumber": order.sort { i, j in less(tracks[i].trackNumber ?? 0, tracks[j].trackNumber ?? 0, tie: { byArtist(i, j) }) }
        case "rating": order.sort { i, j in less(tracks[i].rating, tracks[j].rating, tie: { byArtist(i, j) }) }
        case "playCount": order.sort { i, j in less(tracks[i].playCount, tracks[j].playCount, tie: { byArtist(i, j) }) }
        case "dateAdded": order.sort { i, j in less(tracks[i].dateAdded, tracks[j].dateAdded, tie: { byArtist(i, j) }) }
        default: return
        }
        tracks = order.map { tracks[$0] }
    }

    /// The daemon's default order: sort artist, year, sort album, disc, track, sort name.
    static func artistKey(_ t: Track) -> SortKey {
        SortKey(a: t.sortArtist.isEmpty ? "\u{ffff}" : t.sortArtist, n: t.year ?? 0,
                b: t.sortAlbum, d: t.discNumber ?? 0, k: t.trackNumber ?? 0, c: t.sortName)
    }

    /// Album, then the album's artist, then disc and track.
    static func albumKey(_ t: Track) -> SortKey {
        SortKey(a: t.sortAlbum.isEmpty ? "\u{ffff}" : t.sortAlbum, n: 0,
                b: t.sortArtist, d: t.discNumber ?? 0, k: t.trackNumber ?? 0, c: t.sortName)
    }

    struct SortKey: Comparable {
        let a: String, n: Int, b: String, d: Int, k: Int, c: String
        static func < (x: SortKey, y: SortKey) -> Bool {
            if x.a != y.a { return x.a < y.a }
            if x.n != y.n { return x.n < y.n }
            if x.b != y.b { return x.b < y.b }
            if x.d != y.d { return x.d < y.d }
            if x.k != y.k { return x.k < y.k }
            return x.c < y.c
        }
    }

    // MARK: Status text

    var statusText: String {
        if let e = lastError { return "Error: \(e)" }
        if api == nil { return "Not connected" }
        if loading && tracks.isEmpty { return "Loading…" }
        return StatusFormat.summary(count: tracks.count, totalTime: totalTime, totalSize: totalSize)
    }
}
