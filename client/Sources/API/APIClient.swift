import Foundation
import Security
import AppKit

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
        // Covers get their own session with more connections, so a screen
        // full of them neither queues behind one another nor holds up the
        // player poll on the main session.
        let art = URLSessionConfiguration.ephemeral
        art.timeoutIntervalForRequest = 20
        art.httpMaximumConnectionsPerHost = 12
        artSession = URLSession(configuration: art)
    }

    private let artSession: URLSession

    // MARK: Read cache

    /// Library reads are kept until the library changes. Going back to a
    /// source used to refetch and re-decode the whole 94,000-track library —
    /// 21 MB — every time; now it is instant. Set from the daemon's library
    /// version; any change empties the cache. The app's own writes empty it
    /// too, since the daemon answers them from its patched copy at once.
    var libraryVersion = "" {
        didSet { if libraryVersion != oldValue { dropCache() } }
    }
    private var cache: [String: Any] = [:]
    private var cacheOrder: [String] = []
    private let cacheLock = NSLock()
    private static let cacheLimit = 24

    func dropCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheLock.unlock()
    }

    private func cached<T>(_ key: String, _ load: () async throws -> T) async throws -> T {
        if let hit = cacheGet(key) as? T { return hit }
        let value = try await load()
        cachePut(key, value)
        return value
    }

    private func cacheGet(_ key: String) -> Any? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private func cachePut(_ key: String, _ value: Any) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > APIClient.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private static func cacheKey(_ path: String, _ query: [URLQueryItem]) -> String {
        path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    // MARK: Transport

    /// URL errors worth trying again. Reaching the MacBook Pro by its .local
    /// name goes through mDNS, which occasionally fails to resolve on the
    /// first attempt right after launch; one such failure used to leave the
    /// app showing an empty library with "the Internet connection appears to
    /// be offline" and no way back short of relaunching.
    private static let retryableURLErrors: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorTimedOut,
    ]

    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await session.data(for: req)
            } catch let error as URLError where APIClient.retryableURLErrors.contains(error.errorCode) && attempt < 2 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
                         timeout: TimeInterval? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        // The player poll must give up quickly. One request left hanging on a
        // blocked iTunes used to stall polling for the full 30 seconds, and
        // the window sat showing the track that had been playing when it
        // stalled while iTunes had moved on.
        if let timeout = timeout { req.timeoutInterval = timeout }
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await send(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: status, message: msg ?? "request failed")
        }
        // A write changed what the library reads would say.
        if method != "GET", path.hasPrefix("/api/tracks") || path.hasPrefix("/api/playlists") {
            dropCache()
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

    /// Quits and relaunches iTunes on the MacBook Pro. Takes up to half a
    /// minute on the far end, so the timeout is generous.
    func restartITunes() async throws {
        _ = try await request("POST", "/api/itunes/restart", timeout: 90)
    }

    func playerState() async throws -> PlayerState {
        let data = try await request("GET", "/api/player", timeout: 10)
        return try JSONDecoder().decode(PlayerState.self, from: data)
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
        // The daemon gives up on iTunes after 8 s and reports what it is
        // showing; leave it room to answer with that.
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

    enum ArtworkFetch {
        case image(Data)
        /// The track has no artwork.
        case none
        /// iTunes has to export it; the daemon has queued that. Ask again shortly.
        case pending
    }

    /// The cover, if the daemon has it to hand. `quick` never waits on
    /// iTunes: a cover that needs exporting comes back as `.pending`.
    func artwork(for persistentId: String) async throws -> ArtworkFetch {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/api/tracks/\(persistentId)/artwork"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "quick", value: "1")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await artSession.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data.isEmpty ? .none : .image(data)
        case 404: return .none
        case 202: return .pending
        case let status:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(status: status, message: msg ?? "request failed")
        }
    }

    /// One row per album for the current filters, for Cover Flow and Grid.
    func albumList(filter: TrackFilter) async throws -> [AlbumEntry] {
        struct Wrap: Decodable { let albums: [AlbumEntry] }
        let q = filter.queryItems
        return try await cached(APIClient.cacheKey("/api/albumlist", q)) {
            let w: Wrap = try await get("/api/albumlist", query: q)
            return w.albums
        }
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
    /// Any modal dialog iTunes is showing, and whether it can be read at all.
    func itunesAlert() async throws -> (alert: ITunesAlert?, readable: Bool) {
        struct Wrap: Decodable { let alert: ITunesAlert?; let readable: Bool }
        let w: Wrap = try await get("/api/itunes/alert")
        return (w.alert, w.readable)
    }

    func dismissITunesAlert(button: String) async throws {
        _ = try await request("POST", "/api/itunes/alert/dismiss", body: ["button": button])
    }

    /// Copies library tracks onto a device — what dropping them on it does.
    func copyToDevice(_ name: String, ids: [String]) async throws -> DeviceCopyResult {
        let data = try await request("POST", "/api/devices/\(name)/tracks", body: ["tracks": ids])
        return try JSONDecoder().decode(DeviceCopyResult.self, from: data)
    }

    // MARK: The app's own sync plan

    /// The selection the app holds for a device. `device` is a serial number;
    /// omitting it asks about whatever iPod is plugged in.
    func syncPlan(device: String? = nil) async throws -> SyncPlanReply {
        var q: [URLQueryItem] = []
        if let d = device { q.append(URLQueryItem(name: "device", value: d)) }
        return try await get("/api/sync", query: q)
    }

    /// Ticks or unticks one row. Each list stands on its own, so this changes
    /// that row and nothing else. Recorded only — the playlist in iTunes is
    /// not touched until `syncRebuild`.
    @discardableResult
    func syncToggle(device: String?, kind: String, value: Any, on: Bool) async throws -> SyncPlanReply {
        var body: [String: Any] = ["kind": kind, "value": value, "on": on]
        if let d = device { body["device"] = d }
        let data = try await request("POST", "/api/sync/toggle", body: body)
        return try JSONDecoder().decode(SyncPlanReply.self, from: data)
    }

    /// Writes the plan to its playlist in iTunes. The only call here that
    /// changes anything, and never automatic.
    func syncRebuild(device: String? = nil) async throws -> SyncPlanReply {
        var body: [String: Any] = [:]
        if let d = device { body["device"] = d }
        let data = try await request("POST", "/api/sync/rebuild", body: body, timeout: 1800)
        return try JSONDecoder().decode(SyncPlanReply.self, from: data)
    }

    /// Polled once a second while something is being written.
    func syncProgress() async throws -> SyncProgress {
        let data = try await request("GET", "/api/sync/progress", timeout: 10)
        return try JSONDecoder().decode(SyncProgress.self, from: data)
    }

    func deviceFacets(_ name: String) async throws -> DeviceFacets {
        try await get("/api/devices/\(name)/facets")
    }

    func deviceTracks(_ name: String, playlist: String, limit: Int = 500) async throws -> [DeviceTrack] {
        struct Wrap: Decodable { let tracks: [DeviceTrack] }
        let w: Wrap = try await get("/api/devices/\(name)/tracks", query: [
            URLQueryItem(name: "playlist", value: playlist),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return w.tracks
    }

    /// The device's own picture, as iTunes draws it. The daemon reads it out
    /// of iTunes.app, so the client ships no Apple artwork.
    func deviceImageURL(_ name: String, size: Int) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/api/devices/\(name)/image"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "size", value: String(size))]
        return comps.url!
    }

    func deviceImage(_ name: String, size: Int) async throws -> NSImage? {
        var req = URLRequest(url: deviceImageURL(name, size: size))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }

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

    /// Puts one picture (JPEG or PNG bytes) on every track listed.
    /// The song's lyrics, read from iTunes on demand: they are not in the XML.
    func lyrics(for persistentId: String) async throws -> String {
        struct Wrap: Decodable { let lyrics: String }
        let w: Wrap = try await get("/api/tracks/\(persistentId)/lyrics")
        // iTunes hands them back with carriage returns.
        return w.lyrics.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    func setArtwork(ids: [String], image: Data) async throws -> PatchResult {
        let data = try await request("PUT", "/api/tracks/artwork",
                                     body: ["ids": ids, "image": image.base64EncodedString()], timeout: 120)
        return try JSONDecoder().decode(PatchResult.self, from: data)
    }

    /// Takes the artwork off every track listed.
    func clearArtwork(ids: [String]) async throws -> PatchResult {
        let data = try await request("DELETE", "/api/tracks/artwork", body: ["ids": ids], timeout: 120)
        return try JSONDecoder().decode(PatchResult.self, from: data)
    }

    /// `folder` files the new playlist under that folder, creating it first
    /// if iTunes has no folder of that name.
    func createPlaylist(name: String, folder: String? = nil) async throws -> Playlist {
        var body: [String: Any] = ["name": name]
        if let folder = folder { body["folder"] = folder }
        let data = try await request("POST", "/api/playlists", body: body)
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

    /// Asks the daemon to re-read the XML this instant. True when it did.
    func refreshLibrary() async throws -> Bool {
        let data = try await request("POST", "/api/library/refresh", timeout: 120)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["reloaded"] as? Bool ?? false
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
        let q = filter.queryItems
        return try await cached(APIClient.cacheKey("/api/\(plural)", q)) {
            let data = try await request("GET", "/api/\(plural)", query: q)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let arr = obj?[plural] as? [[String: Any]] else { return [] }
            return arr.map { FacetEntry(name: $0["name"] as? String ?? "", count: $0["count"] as? Int ?? 0) }
        }
    }

    /// Fetches every matching track in the compact row format.
    func tracks(filter: TrackFilter, limit: Int = 200_000) async throws -> TrackPage {
        var q = filter.queryItems
        q.append(URLQueryItem(name: "compact", value: "1"))
        q.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await cached(APIClient.cacheKey("/api/tracks", q)) {
            let data = try await request("GET", "/api/tracks", query: q)
            return try Self.decodeCompact(data)
        }
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
                dateAdded: idx["dateAdded"].flatMap { row[$0] as? String } ?? "",
                lastPlayed: idx["lastPlayed"].flatMap { row[$0] as? String } ?? "",
                bitRate: idx["bitRate"].flatMap { row[$0] as? Int },
                sortArtist: idx["sortArtist"].flatMap { row[$0] as? String } ?? "",
                sortAlbum: idx["sortAlbum"].flatMap { row[$0] as? String } ?? "",
                sortName: idx["sortName"].flatMap { row[$0] as? String } ?? ""
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
/// What a daemon says about itself before pairing.
struct DaemonHello {
    let name: String
    let host: String
    let port: Int
    let itunesVersion: String
}

/// The result of a successful pairing: the token, plus the daemon's names.
struct PairResult {
    let token: String
    let name: String
    let tailscaleName: String
}

extension APIClient {
    private static func literal(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    /// GET /api/hello on a host, no token needed.
    static func hello(host: String, port: Int) async throws -> DaemonHello {
        guard let url = URL(string: "http://\(literal(host)):\(port)/api/hello") else { throw APIError(status: 0, message: "bad address") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["app"] as? String == "iTunes Remote" else {
            throw APIError(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "that is not an iTunes Remote daemon")
        }
        return DaemonHello(name: obj["name"] as? String ?? host, host: obj["host"] as? String ?? host,
                           port: obj["port"] as? Int ?? port, itunesVersion: obj["itunesVersion"] as? String ?? "")
    }

    /// POST /api/pair with the six-digit code the installer printed.
    static func pair(host: String, port: Int, code: String) async throws -> PairResult {
        guard let url = URL(string: "http://\(literal(host)):\(port)/api/pair") else { throw APIError(status: 0, message: "bad address") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let token = obj["token"] as? String, !token.isEmpty else {
            throw APIError(status: status, message: obj["error"] as? String ?? "pairing failed")
        }
        return PairResult(token: token, name: obj["name"] as? String ?? host, tailscaleName: obj["tailscaleName"] as? String ?? "")
    }
}

struct ServerSettings {
    static let hostKey = "serverHost"
    static let lanHostKey = "serverLANHost"
    static let portKey = "serverPort"
    static let tokenKey = "serverToken"
    static let nameKey = "serverName"

    /// The host used when the LAN one does not answer — the Tailscale name.
    var host: String
    /// The host on the home network, probed first; used whenever it answers.
    var lanHost: String
    var port: Int
    var token: String
    /// The other Mac's name as its System Preferences shows it, learned at
    /// pairing. Every message that names the other machine uses it.
    var name: String = ServerSettings.name

    /// The paired Mac's name, for messages, without loading the rest.
    static var name: String {
        let n = UserDefaults.standard.string(forKey: nameKey) ?? ""
        return n.isEmpty ? "MacBook Pro" : n
    }

    static func load() -> ServerSettings {
        let d = UserDefaults.standard
        // The token lives in the keychain. One kept in UserDefaults by an
        // earlier version, or by a save the keychain refused, moves over
        // the first time the keychain takes it.
        var token = d.string(forKey: tokenKey) ?? ""
        if TokenStore.enabled {
            if !token.isEmpty {
                if TokenStore.write(token) { d.removeObject(forKey: tokenKey) }
            } else {
                token = TokenStore.read() ?? ""
            }
        }
        return ServerSettings(
            host: d.string(forKey: hostKey) ?? "Stevens-MacBook-Pro.local",
            lanHost: d.string(forKey: lanHostKey) ?? "Stevens-MacBook-Pro.local",
            port: d.integer(forKey: portKey) == 0 ? 8765 : d.integer(forKey: portKey),
            token: token
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(host, forKey: Self.hostKey)
        d.set(lanHost, forKey: Self.lanHostKey)
        d.set(port, forKey: Self.portKey)
        d.set(name, forKey: Self.nameKey)
        if TokenStore.enabled && TokenStore.write(token) {
            d.removeObject(forKey: Self.tokenKey)
        } else {
            d.set(token, forKey: Self.tokenKey)
        }
    }

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }

    var lanURL: URL? {
        URL(string: "http://\(lanHost):\(port)")
    }
}

/// The daemon's bearer token, in the login keychain rather than in the
/// preferences file, where anything that can read a plist could read it.
///
/// Only a build signed with a Team ID uses the keychain. An ad-hoc
/// development build would get an "allow access?" dialog for an item the
/// signed app made (and the signed app one for an item the dev build made),
/// so development builds stay on UserDefaults, or on `--token`.
enum TokenStore {
    static let service = "local.stevenbleifer.itunesremote"
    static let account = "daemon-token"

    /// Off for `--token` runs, and for anything not signed by a team.
    nonisolated(unsafe) static var enabled: Bool = signedWithTeam

    static let signedWithTeam: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let c = code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(c, [], &staticCode) == errSecSuccess, let sc = staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return ((dict[kSecCodeInfoTeamIdentifier as String] as? String) ?? "").isEmpty == false
    }()

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        let data = Data(token.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "iTunes Remote daemon token"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
