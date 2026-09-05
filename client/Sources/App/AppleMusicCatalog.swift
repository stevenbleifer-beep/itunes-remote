import Foundation
import MusicKit

/// Apple Music's catalogue, for the Apple Music library on this Mac.
///
/// The library itself is read through the daemon like everything else;
/// this is the one thing the daemon cannot do — search the songs you do
/// not have — and the ways of acting on what it finds: play it, put it in
/// the library, put it in a playlist. MusicKit signs the requests with a
/// token it makes for this app, which needs the app's identifier to have
/// the MusicKit service turned on in the Apple Developer account, and an
/// Apple Music subscription on the Mac to play or add anything.
///
/// Nothing here touches the iTunes side: it is only reachable when the
/// Apple Music library is the active one.
@MainActor
enum AppleMusicCatalog {
    struct SongHit {
        let id: String
        let name: String
        let artist: String
        let album: String
        let duration: Int?          // milliseconds
        let artworkURL: URL?
        let song: Song
    }

    struct AlbumHit {
        let id: String
        let name: String
        let artist: String
        let year: Int?
        let trackCount: Int?
        let artworkURL: URL?
        let album: Album
    }

    struct PlaylistEntry {
        let id: String
        let name: String
    }

    /// Asks once; macOS shows its own "wants to access Apple Music" prompt.
    static func authorize() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized: return true
        case .notDetermined: return await MusicAuthorization.request() == .authorized
        default: return false
        }
    }

    /// A short list from the catalogue for what was typed: songs and albums.
    static func search(_ term: String) async throws -> (songs: [SongHit], albums: [AlbumHit]) {
        guard await authorize() else { throw AppleMusicError("Apple Music access was not allowed. System Settings ▸ Privacy & Security ▸ Media & Apple Music.") }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self])
        request.limit = 8
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            throw AppleMusicError(explain(error))
        }
        let songs = response.songs.map { s in
            SongHit(id: s.id.rawValue, name: s.title, artist: s.artistName, album: s.albumTitle ?? "",
                    duration: s.duration.map { Int($0 * 1000) }, artworkURL: s.artwork?.url(width: 120, height: 120), song: s)
        }
        let albums = response.albums.map { a in
            AlbumHit(id: a.id.rawValue, name: a.title, artist: a.artistName,
                     year: a.releaseDate.map { Calendar.current.component(.year, from: $0) },
                     trackCount: a.trackCount, artworkURL: a.artwork?.url(width: 120, height: 120), album: a)
        }
        return (Array(songs.prefix(6)), Array(albums.prefix(3)))
    }

    /// Plays through Apple Music's own player, on this Mac.
    static func play(_ song: Song) async throws {
        try await requireSubscription()
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        try await player.play()
    }

    static func play(_ album: Album) async throws {
        try await requireSubscription()
        let player = ApplicationMusicPlayer.shared
        player.queue = [album]
        try await player.play()
    }

    /// Puts songs or albums into the library. MusicKit has no library-add
    /// on macOS, so this is the Apple Music API call it would make,
    /// signed by MusicKit.
    static func addToLibrary(songIDs: [String] = [], albumIDs: [String] = []) async throws {
        try await requireSubscription()
        var comps = URLComponents(string: "https://api.music.apple.com/v1/me/library")!
        var items: [URLQueryItem] = []
        if !songIDs.isEmpty { items.append(URLQueryItem(name: "ids[songs]", value: songIDs.joined(separator: ","))) }
        if !albumIDs.isEmpty { items.append(URLQueryItem(name: "ids[albums]", value: albumIDs.joined(separator: ","))) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        try await send(req)
    }

    /// The library's own playlists, for "Add to Playlist".
    static func playlists() async throws -> [PlaylistEntry] {
        guard await authorize() else { return [] }
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.sort(by: \.name, ascending: true)
        let response = try await request.response()
        return response.items.map { PlaylistEntry(id: $0.id.rawValue, name: $0.name) }
    }

    /// Adds catalogue songs to one of the library's playlists. Apple adds
    /// them to the library as well.
    static func add(songIDs: [String], toPlaylist playlistID: String) async throws {
        try await requireSubscription()
        var req = URLRequest(url: URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(playlistID)/tracks")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["data": songIDs.map { ["id": $0, "type": "songs"] }])
        try await send(req)
    }

    /// A new library playlist holding these songs.
    static func createPlaylist(named name: String, songIDs: [String]) async throws {
        try await requireSubscription()
        var req = URLRequest(url: URL(string: "https://api.music.apple.com/v1/me/library/playlists")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["attributes": ["name": name]]
        if !songIDs.isEmpty {
            body["relationships"] = ["tracks": ["data": songIDs.map { ["id": $0, "type": "songs"] }]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await send(req)
    }

    // MARK: Plumbing

    private static func requireSubscription() async throws {
        guard await authorize() else { throw AppleMusicError("Apple Music access was not allowed.") }
        let sub: MusicSubscription
        do { sub = try await MusicSubscription.current } catch { throw AppleMusicError(explain(error)) }
        guard sub.canPlayCatalogContent else {
            throw AppleMusicError("This needs an Apple Music subscription on this Mac.")
        }
    }

    private static func send(_ req: URLRequest) async throws {
        do {
            let response = try await MusicDataRequest(urlRequest: req).response()
            let status = (response.urlResponse as HTTPURLResponse?)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                let text = String(data: response.data, encoding: .utf8) ?? ""
                throw AppleMusicError("Apple Music answered \(status)" + (text.isEmpty ? "" : ": \(text.prefix(200))"))
            }
        } catch let e as AppleMusicError {
            throw e
        } catch {
            throw AppleMusicError(explain(error))
        }
    }

    /// MusicKit's errors in words, with the one setup step named.
    private static func explain(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("developerTokenRequestFailed") || text.contains("DeveloperToken") {
            return "Apple Music would not issue this app a token. In the Apple Developer account, the identifier \(AppIdentity.bundleId) needs the MusicKit service enabled (Certificates, Identifiers & Profiles ▸ Identifiers ▸ App Services)."
        }
        if text.contains("userTokenRequestFailed") || text.contains("UserToken") {
            return "Apple Music would not sign you in. Open the Music app, make sure you are signed in there, then try again."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct AppleMusicError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
