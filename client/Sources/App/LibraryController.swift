import Foundation

enum Source: Equatable {
    case library
    case playlist(Playlist)

    static func == (a: Source, b: Source) -> Bool {
        switch (a, b) {
        case (.library, .library): return true
        case let (.playlist(x), .playlist(y)): return x.persistentId == y.persistentId
        default: return false
        }
    }

    var playlistId: String? {
        if case let .playlist(p) = self { return p.persistentId }
        return nil
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
    private(set) var genres: [FacetEntry] = []
    private(set) var artists: [FacetEntry] = []
    private(set) var albums: [FacetEntry] = []
    private(set) var tracks: [Track] = []
    private(set) var totalTime = 0
    private(set) var totalSize = 0
    private(set) var loading = false
    private(set) var lastError: String?

    var source: Source = .library { didSet { if source != oldValue { resetBrowser(); reload() } } }
    var searchText: String = "" { didSet { if searchText != oldValue { reload() } } }
    var selectedGenre: String? { didSet { if selectedGenre != oldValue { selectedArtist = nil; selectedAlbum = nil; reload() } } }
    var selectedArtist: String? { didSet { if selectedArtist != oldValue { selectedAlbum = nil; reload() } } }
    var selectedAlbum: String? { didSet { if selectedAlbum != oldValue { reload() } } }

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
        selectedGenre = nil
        selectedArtist = nil
        selectedAlbum = nil
    }

    // MARK: Connect

    func connect(_ client: APIClient) {
        api = client
        Task { await loadLibrary() }
    }

    private func loadLibrary() async {
        guard let api = api else { return }
        loading = true
        onStatusChanged()
        do {
            info = try await api.libraryInfo()
            playlists = try await api.playlists()
            lastError = nil
            onPlaylistsChanged()
        } catch {
            lastError = error.localizedDescription
            loading = false
            onStatusChanged()
            return
        }
        reload()
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

    private var browserFilter: TrackFilter {
        TrackFilter(q: searchText, genre: nil, artist: nil, album: nil, playlist: source.playlistId)
    }

    var trackFilter: TrackFilter {
        TrackFilter(q: searchText, genre: selectedGenre, artist: selectedArtist,
                    album: selectedAlbum, playlist: source.playlistId)
    }

    // MARK: Reload

    func reload() {
        guard let api = api else { return }
        generation += 1
        let gen = generation
        loading = true
        onStatusChanged()
        let base = browserFilter
        let artistFilter = TrackFilter(q: base.q, genre: selectedGenre, artist: nil, album: nil, playlist: base.playlist)
        let albumFilter = TrackFilter(q: base.q, genre: selectedGenre, artist: selectedArtist, album: nil, playlist: base.playlist)
        let trackFilter = self.trackFilter
        Task {
            do {
                async let g = api.facet(.genre, filter: base)
                async let a = api.facet(.artist, filter: artistFilter)
                async let al = api.facet(.album, filter: albumFilter)
                async let t = api.tracks(filter: trackFilter)
                let (genres, artists, albums, page) = try await (g, a, al, t)
                guard gen == generation else { return }
                self.genres = genres
                self.artists = artists
                self.albums = albums
                // A selection that no longer exists in its pane falls back to All.
                var changed = false
                if let s = selectedGenre, !genres.contains(where: { $0.name == s }) { selectedGenre = nil; changed = true }
                if let s = selectedArtist, !artists.contains(where: { $0.name == s }) { selectedArtist = nil; changed = true }
                if let s = selectedAlbum, !albums.contains(where: { $0.name == s }) { selectedAlbum = nil; changed = true }
                if changed { return }   // the didSet already kicked off a fresh reload
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
                lastError = error.localizedDescription
                loading = false
                onStatusChanged()
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
        guard let key = sortKey else { return }
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
