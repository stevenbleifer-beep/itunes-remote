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
            playlists = try await api.playlists()
            lastError = nil
            loadRetry?.invalidate()
            loadRetry = nil
            onPlaylistsChanged()
        } catch {
            lastError = error.localizedDescription + " — retrying"
            loading = false
            onStatusChanged()
            scheduleLoadRetry()
            return
        }
        reload()
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
                tracks.sort { $0.dateAdded > $1.dateAdded }
            }
            return
        }
        let asc = sortAscending
        func cmpStr(_ a: String, _ b: String) -> Bool {
            let r = a.localizedCaseInsensitiveCompare(b)
            return asc ? r == .orderedAscending : r == .orderedDescending
        }
        func cmpInt(_ a: Int?, _ b: Int?) -> Bool {
            let x = a ?? 0, y = b ?? 0
            return asc ? x < y : x > y
        }
        switch key {
        case "name": tracks.sort { cmpStr($0.name, $1.name) }
        case "artist": tracks.sort { $0.artist == $1.artist ? albumOrder($0, $1) : cmpStr($0.artist, $1.artist) }
        case "album": tracks.sort { $0.album == $1.album ? discTrack($0, $1) : cmpStr($0.album, $1.album) }
        case "genre": tracks.sort { $0.genre == $1.genre ? albumOrder($0, $1) : cmpStr($0.genre, $1.genre) }
        case "year": tracks.sort { $0.year == $1.year ? albumOrder($0, $1) : cmpInt($0.year, $1.year) }
        case "totalTime": tracks.sort { cmpInt($0.totalTime, $1.totalTime) }
        case "trackNumber": tracks.sort { cmpInt($0.trackNumber, $1.trackNumber) }
        case "rating": tracks.sort { $0.rating == $1.rating ? albumOrder($0, $1) : cmpInt($0.rating, $1.rating) }
        case "playCount": tracks.sort { $0.playCount == $1.playCount ? albumOrder($0, $1) : cmpInt($0.playCount, $1.playCount) }
        case "dateAdded": tracks.sort { asc ? $0.dateAdded < $1.dateAdded : $0.dateAdded > $1.dateAdded }
        default: break
        }
    }

    private func albumOrder(_ a: Track, _ b: Track) -> Bool {
        if a.album != b.album { return a.album.localizedCaseInsensitiveCompare(b.album) == .orderedAscending }
        return discTrack(a, b)
    }

    private func discTrack(_ a: Track, _ b: Track) -> Bool {
        let d1 = a.discNumber ?? 0, d2 = b.discNumber ?? 0
        if d1 != d2 { return d1 < d2 }
        return (a.trackNumber ?? 0) < (b.trackNumber ?? 0)
    }

    // MARK: Status text

    var statusText: String {
        if let e = lastError { return "Error: \(e)" }
        if api == nil { return "Not connected" }
        if loading && tracks.isEmpty { return "Loading…" }
        return StatusFormat.summary(count: tracks.count, totalTime: totalTime, totalSize: totalSize)
    }
}
