import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "\(message) (HTTP \(status))" }
}

/// Thin client for the daemon. Every call is async and returns decoded models.
final class APIClient {
    var baseURL: URL
    var token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: cfg)
    }

    // MARK: Transport

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: status, message: msg ?? "request failed")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Player

    func itunesStatus() async throws -> ITunesStatus {
        try await get("/api/itunes")
    }

    func launchITunes() async throws {
        _ = try await request("POST", "/api/itunes/launch")
    }

    func playerState() async throws -> PlayerState {
        try await get("/api/player")
    }

    func playerCommand(_ cmd: String) async throws {
        _ = try await request("POST", "/api/player/\(cmd)")
    }

    func play(track: String? = nil, playlist: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let t = track { body["track"] = t }
        if let p = playlist { body["playlist"] = p }
        _ = try await request("POST", "/api/player/play", body: body)
    }

    func setVolume(_ volume: Int) async throws {
        _ = try await request("POST", "/api/player/volume", body: ["volume": volume])
    }

    func setPosition(_ seconds: Double) async throws {
        _ = try await request("POST", "/api/player/position", body: ["position": seconds])
    }

    func outputs() async throws -> [Output] {
        struct Wrap: Decodable { let outputs: [Output] }
        let w: Wrap = try await get("/api/outputs")
        return w.outputs
    }

    func setOutputs(_ names: [String]) async throws -> [Output] {
        struct Wrap: Decodable { let outputs: [Output] }
        let data = try await request("POST", "/api/outputs", body: ["names": names])
        return try JSONDecoder().decode(Wrap.self, from: data).outputs
    }

    /// The track's file, for playing on this Mac. The token rides in the
    /// query as well because AVFoundation does not always send headers.
    func audioURL(for persistentId: String) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/api/tracks/\(persistentId)/audio"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "token", value: token)]
        return comps.url!
    }

    /// Image bytes, or nil when the track has no artwork (404).
    func artwork(for persistentId: String) async throws -> Data? {
        do {
            return try await request("GET", "/api/tracks/\(persistentId)/artwork")
        } catch let e as APIError where e.status == 404 {
            return nil
        }
    }

    /// One row per album for the current filters, for Cover Flow and Grid.
    func albumList(filter: TrackFilter) async throws -> [AlbumEntry] {
        struct Wrap: Decodable { let albums: [AlbumEntry] }
        let w: Wrap = try await get("/api/albumlist", query: filter.queryItems)
        return w.albums
    }

    func setShuffle(_ enabled: Bool) async throws {
        _ = try await request("POST", "/api/player/shuffle", body: ["enabled": enabled])
    }

    func setRepeat(_ mode: String) async throws {
        _ = try await request("POST", "/api/player/repeat", body: ["mode": mode])
    }

    func sources() async throws -> [DeviceSource] {
        struct Wrap: Decodable { let sources: [DeviceSource] }
        let w: Wrap = try await get("/api/sources")
        return w.sources
    }

    func devices() async throws -> [DeviceSource] {
        struct Wrap: Decodable { let devices: [DeviceSource] }
        return (try await get("/api/devices") as Wrap).devices
    }

    func deviceDetail(_ name: String) async throws -> DeviceDetail {
        try await get("/api/devices/\(name)")
    }

    // Device names are passed raw. `request` builds the URL with
    // appendingPathComponent, which percent-encodes the component itself; a
    // name escaped here first came out double-encoded ("iPod%2520classic") and
    // the daemon answered 404.
    private func sourcePath(_ name: String, _ op: String) -> String {
        "/api/sources/\(name)/\(op)"
    }

    func syncSource(_ name: String) async throws {
        _ = try await request("POST", sourcePath(name, "sync"))
    }

    func ejectSource(_ name: String) async throws {
        _ = try await request("POST", sourcePath(name, "eject"))
    }

    // MARK: Writes

    func patchTracks(ids: [String], fields: [String: Any]) async throws -> PatchResult {
        let data = try await request("PATCH", "/api/tracks", body: ["ids": ids, "fields": fields])
        return try JSONDecoder().decode(PatchResult.self, from: data)
    }

    func createPlaylist(name: String) async throws -> Playlist {
        let data = try await request("POST", "/api/playlists", body: ["name": name])
        return try JSONDecoder().decode(Playlist.self, from: data)
    }

    func renamePlaylist(_ playlistId: String, name: String) async throws -> Playlist {
        let data = try await request("PATCH", "/api/playlists/\(playlistId)", body: ["name": name])
        return try JSONDecoder().decode(Playlist.self, from: data)
    }

    func deletePlaylist(_ playlistId: String) async throws {
        _ = try await request("DELETE", "/api/playlists/\(playlistId)")
    }

    func addToPlaylist(_ playlistId: String, ids: [String]) async throws -> PlaylistChange {
        let data = try await request("POST", "/api/playlists/\(playlistId)/tracks", body: ["ids": ids])
        return try JSONDecoder().decode(PlaylistChange.self, from: data)
    }

    func removeFromPlaylist(_ playlistId: String, ids: [String]) async throws -> PlaylistChange {
        let data = try await request("DELETE", "/api/playlists/\(playlistId)/tracks", body: ["ids": ids])
        return try JSONDecoder().decode(PlaylistChange.self, from: data)
    }

    // MARK: Reads

    func libraryInfo() async throws -> LibraryInfo {
        try await get("/api/library")
    }

    /// One track's full record, for reading a value back after a write.
    func track(_ persistentId: String) async throws -> Track {
        let data = try await request("GET", "/api/tracks/\(persistentId)")
        struct Row: Decodable {
            let persistentId: String, name: String, artist: String, album: String, albumArtist: String
            let genre: String, year: Int?, trackNumber: Int?, discNumber: Int?, totalTime: Int?
            let size: Int?, compilation: Bool, enabled: Bool, rating: Int, playCount: Int
        }
        let r = try JSONDecoder().decode(Row.self, from: data)
        return Track(persistentId: r.persistentId, name: r.name, artist: r.artist, album: r.album,
                     albumArtist: r.albumArtist, genre: r.genre, year: r.year, trackNumber: r.trackNumber,
                     discNumber: r.discNumber, totalTime: r.totalTime, size: r.size,
                     compilation: r.compilation, enabled: r.enabled, rating: r.rating, playCount: r.playCount)
    }

    func playlists() async throws -> [Playlist] {
        struct Wrap: Decodable { let playlists: [Playlist] }
        let w: Wrap = try await get("/api/playlists")
        return w.playlists
    }

    /// `field` is the singular name: genre, artist, album, composer, grouping.
    func facet(_ field: String, filter: TrackFilter) async throws -> [FacetEntry] {
        let plural = field + "s"
        let data = try await request("GET", "/api/\(plural)", query: filter.queryItems)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let arr = obj?[plural] as? [[String: Any]] else { return [] }
        return arr.map { FacetEntry(name: $0["name"] as? String ?? "", count: $0["count"] as? Int ?? 0) }
    }

    /// Fetches every matching track in the compact row format.
    func tracks(filter: TrackFilter, limit: Int = 200_000) async throws -> TrackPage {
        var q = filter.queryItems
        q.append(URLQueryItem(name: "compact", value: "1"))
        q.append(URLQueryItem(name: "limit", value: String(limit)))
        let data = try await request("GET", "/api/tracks", query: q)
        return try Self.decodeCompact(data)
    }

    static func decodeCompact(_ data: Data) throws -> TrackPage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = obj["columns"] as? [String],
              let rows = obj["rows"] as? [[Any]] else {
            throw APIError(status: 0, message: "unexpected track payload")
        }
        var idx: [String: Int] = [:]
        for (i, c) in columns.enumerated() { idx[c] = i }
        func s(_ row: [Any], _ key: String) -> String { (row[idx[key]!] as? String) ?? "" }
        func i(_ row: [Any], _ key: String) -> Int? { row[idx[key]!] as? Int }
        var tracks: [Track] = []
        tracks.reserveCapacity(rows.count)
        for row in rows {
            tracks.append(Track(
                persistentId: s(row, "persistentId"),
                name: s(row, "name"),
                artist: s(row, "artist"),
                album: s(row, "album"),
                albumArtist: s(row, "albumArtist"),
                genre: s(row, "genre"),
                year: i(row, "year"),
                trackNumber: i(row, "trackNumber"),
                discNumber: i(row, "discNumber"),
                totalTime: i(row, "totalTime"),
                size: i(row, "size"),
                compilation: (row[idx["compilation"]!] as? Bool) ?? false,
                enabled: idx["enabled"].flatMap { row[$0] as? Bool } ?? true,
                rating: idx["rating"].flatMap { row[$0] as? Int } ?? 0,
                playCount: idx["playCount"].flatMap { row[$0] as? Int } ?? 0,
                dateAdded: idx["dateAdded"].flatMap { row[$0] as? String } ?? ""
            ))
        }
        return TrackPage(
            total: obj["total"] as? Int ?? tracks.count,
            totalTime: obj["totalTime"] as? Int ?? 0,
            totalSize: obj["totalSize"] as? Int ?? 0,
            tracks: tracks
        )
    }
}

/// Where the daemon is. Stored in UserDefaults; edited from the connect panel.
struct ServerSettings {
    static let hostKey = "serverHost"
    static let portKey = "serverPort"
    static let tokenKey = "serverToken"

    var host: String
    var port: Int
    var token: String

    static func load() -> ServerSettings {
        let d = UserDefaults.standard
        return ServerSettings(
            host: d.string(forKey: hostKey) ?? "Stevens-MacBook-Pro.local",
            port: d.integer(forKey: portKey) == 0 ? 8765 : d.integer(forKey: portKey),
            token: d.string(forKey: tokenKey) ?? ""
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Self.hostKey)
        d.set(port, forKey: Self.portKey)
        d.set(token, forKey: Self.tokenKey)
    }

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}
