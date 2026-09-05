import Foundation

struct LibraryInfo: Decodable {
    let trackCount: Int
    let xmlEntryCount: Int
    let playlistCount: Int
    let xmlWrittenAt: String
    let loadedAt: String
    let parseSeconds: Double
    let applicationVersion: String
    let itunesVersion: String?
    let reloading: Bool
    let lastError: String?
    /// Edits made through the daemon that the XML has not caught up with.
    var journalLength: Int? = nil
    var playlistJournalLength: Int? = nil

    /// Changes when iTunes has rewritten its library, so a cached read is stale.
    var version: String { "\(xmlWrittenAt)|\(loadedAt)|\(journalLength ?? 0)|\(playlistJournalLength ?? 0)" }
    /// Changes only when the library itself did — not for the app's own edits,
    /// which are already mirrored on screen.
    var contentVersion: String { "\(xmlWrittenAt)|\(loadedAt)" }
}

struct Track {
    let persistentId: String
    var name: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var totalTime: Int?      // milliseconds
    var size: Int?           // bytes
    var compilation: Bool
    var enabled: Bool = true // the checkbox column
    var rating: Int = 0      // 0-100, five stars of 20
    var playCount: Int = 0
    var dateAdded: String = ""   // ISO 8601, so it sorts as text
    var lastPlayed: String = ""  // ISO 8601, empty when never played
    var bitRate: Int? = nil      // kbps
    /// iTunes' sort forms: the Sort field if set, else the text with a leading
    /// article dropped, folded. So "The Beatles" sorts as "beatles".
    var sortArtist: String = ""
    var sortAlbum: String = ""
    var sortName: String = ""

    /// The artist shown in the browser and used for grouping.
    var displayArtist: String { albumArtist.isEmpty ? artist : albumArtist }

    var durationText: String {
        guard let ms = totalTime else { return "" }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Saved to UserDefaults (the Up Next queue outlives a launch)

    var defaultsDict: [String: Any] {
        var d: [String: Any] = ["id": persistentId, "name": name, "artist": artist, "album": album,
                                "albumArtist": albumArtist, "genre": genre, "compilation": compilation]
        if let v = year { d["year"] = v }
        if let v = trackNumber { d["trackNumber"] = v }
        if let v = discNumber { d["discNumber"] = v }
        if let v = totalTime { d["totalTime"] = v }
        return d
    }
}

extension Track {
    /// A track saved by `defaultsDict`; the memberwise init stays available
    /// because this one lives in an extension.
    init?(defaults d: [String: Any]) {
        guard let id = d["id"] as? String, id.count == 16 else { return nil }
        self.init(persistentId: id, name: d["name"] as? String ?? "", artist: d["artist"] as? String ?? "",
                  album: d["album"] as? String ?? "", albumArtist: d["albumArtist"] as? String ?? "",
                  genre: d["genre"] as? String ?? "", year: d["year"] as? Int, trackNumber: d["trackNumber"] as? Int,
                  discNumber: d["discNumber"] as? Int, totalTime: d["totalTime"] as? Int, size: nil,
                  compilation: d["compilation"] as? Bool ?? false)
    }
}

struct TrackPage {
    let total: Int
    let totalTime: Int
    let totalSize: Int
    let tracks: [Track]
}

struct FacetEntry: Decodable {
    let name: String
    let count: Int
}

struct Playlist: Decodable {
    let persistentId: String
    /// iTunes' integer id, absent until the XML has caught up with a playlist
    /// the app just created. It was `Int`, so creating a playlist decoded as
    /// an error ("the data couldn't be read") even though iTunes had made it,
    /// and every playlist list after that failed until iTunes rewrote the XML.
    let playlistId: Int?
    let name: String
    let smart: Bool
    let count: Int
    /// A folder of playlists. iTunes treats it as a playlist whose items are
    /// everything in the playlists under it.
    let folder: Bool
    /// The folder this one sits in, if any.
    let parentId: String?

    init(persistentId: String, playlistId: Int?, name: String, smart: Bool, count: Int,
         folder: Bool = false, parentId: String? = nil) {
        self.persistentId = persistentId
        self.playlistId = playlistId
        self.name = name
        self.smart = smart
        self.count = count
        self.folder = folder
        self.parentId = parentId
    }

    private enum CodingKeys: String, CodingKey {
        case persistentId, playlistId, name, smart, count, folder, parentId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistentId = try c.decode(String.self, forKey: .persistentId)
        playlistId = try c.decodeIfPresent(Int.self, forKey: .playlistId)
        name = try c.decode(String.self, forKey: .name)
        smart = try c.decodeIfPresent(Bool.self, forKey: .smart) ?? false
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        folder = try c.decodeIfPresent(Bool.self, forKey: .folder) ?? false
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
    }
}

/// Query parameters shared by tracks and facet calls. Nil means no filter.
struct TrackFilter: Equatable {
    var q: String?
    var genre: String?
    var artist: String?
    var album: String?
    var composer: String?
    var grouping: String?
    var playlist: String?
    /// Non-zero asks the daemon for only the N most recently added, newest first.
    var recent: Int = 0

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let v = q, !v.isEmpty { items.append(URLQueryItem(name: "q", value: v)) }
        if let v = genre { items.append(URLQueryItem(name: "genre", value: v)) }
        if let v = artist { items.append(URLQueryItem(name: "artist", value: v)) }
        if let v = album { items.append(URLQueryItem(name: "album", value: v)) }
        if let v = composer { items.append(URLQueryItem(name: "composer", value: v)) }
        if let v = grouping { items.append(URLQueryItem(name: "grouping", value: v)) }
        if let v = playlist { items.append(URLQueryItem(name: "playlist", value: v)) }
        if recent > 0 { items.append(URLQueryItem(name: "recent", value: String(recent))) }
        return items
    }
}

/// The daemon's facet endpoints are the field name plus "s".
enum FacetKind: String {
    case genre = "genres"
    case artist = "artists"
    case album = "albums"
    case composer = "composers"
    case grouping = "groupings"
}

/// Formats totals the way the iTunes status bar did: "1,234 songs, 3.2 days, 12.1 GB".
enum StatusFormat {
    static func summary(count: Int, totalTime ms: Int, totalSize bytes: Int) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        let songs = "\(n.string(from: NSNumber(value: count)) ?? "\(count)") song\(count == 1 ? "" : "s")"
        return "\(songs), \(duration(ms)), \(size(bytes))"
    }

    static func duration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 3600 {
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        if s < 86400 {
            let h = Double(s) / 3600
            return String(format: "%.1f hours", h)
        }
        let d = Double(s) / 86400
        return String(format: "%.1f days", d)
    }

    static func size(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1_000_000 { return String(format: "%.0f KB", b / 1000) }
        if b < 1_000_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
        return String(format: "%.2f GB", b / 1_000_000_000)
    }
}

// MARK: Player

struct PlayerTrack: Decodable {
    let persistentId: String
    let name: String
    let artist: String
    let album: String
    let duration: Double
}

struct PlayerPlaylist: Decodable {
    let name: String
    let persistentId: String
}

struct PlayerState: Decodable {
    let state: String          // playing | paused | stopped
    let volume: Int
    let position: Double
    let track: PlayerTrack?
    let playlist: PlayerPlaylist?
    let shuffle: Bool?
    let `repeat`: String?

    var isPlaying: Bool { state == "playing" }
    var repeatMode: String { `repeat` ?? "off" }
}

struct DeviceSource: Decodable, Equatable {
    let name: String
    let kind: String
    let freeSpace: Int?
    let capacity: Int?
    /// False for an Apple device seen on the USB bus that iTunes has not
    /// opened as a source. It still gets a row; its page says why it is empty.
    var itunesSource: Bool? = nil
    var isIPod: Bool { kind == "iPod" }
}

/// Everything the daemon can say about one connected device, for the sync
/// page. `categories` is what iTunes reports is on the device; `otherBytes`
/// is what it does not account for — artwork, the device database, calendars.
struct DeviceDetail: Decodable {
    struct Category: Decodable, Equatable {
        let name: String
        let trackCount: Int
        let bytes: Int
    }
    struct DevicePlaylist: Decodable, Equatable {
        let name: String
        let count: Int
    }
    let name: String
    let kind: String
    let capacity: Int?
    let freeSpace: Int?
    let usedBytes: Int?
    let otherBytes: Int?
    let trackCount: Int?
    let serialNumber: String?
    let connection: String?
    let productName: String?
    let manufacturer: String?
    let mountPoint: String?
    let fileSystem: String?
    let volumeName: String?
    let itunesSource: Bool
    let syncable: Bool
    let unavailableReason: String?
    let categories: [Category]
    let playlists: [DevicePlaylist]
    /// From iTunes' own com.apple.iPod preferences, which is the only place
    /// the printed serial and the firmware version can be read.
    let deviceSerialNumber: String?
    let softwareVersion: String?
    let familyId: Int?
    let deviceClass: String?
    let useCount: Int?
    let lastConnected: String?
    let formatName: String?
    let diskUse: Bool?
    let hasImage: Bool?
    let sync: DeviceSync?
}

/// How a device syncs, worked out from what is actually on it. iTunes keeps
/// these settings in its library database, out of reach of AppleScript, the
/// preference files and the accessibility tree, so everything here is derived
/// or reported as unreadable — never guessed.
struct DeviceSync: Decodable, Equatable {
    struct Convert: Decodable, Equatable {
        let kbps: Int
        let sampled: Int
        let atCap: Int
    }
    struct SyncedPlaylist: Decodable, Equatable {
        let name: String
        let playlistId: String
        let deviceCount: Int
        let libraryCount: Int
        let smart: Bool
    }
    let mode: String
    let songsOnDevice: Int
    let songsInLibrary: Int
    let convert: Convert?
    let playlists: [SyncedPlaylist]
    let deviceOnlyPlaylists: [String]
    let unreadable: [String]

    var syncsWholeLibrary: Bool { mode == "entireLibrary" }
}

/// The artists, albums and genres that actually reached a device. iTunes' own
/// Music pane ticks whatever its sync selection names, and that selection is
/// readable by nothing outside iTunes, so the pane marks this instead.
struct DeviceFacets: Decodable {
    let device: String
    let artists: [String]
    let albums: [String]
    let genres: [String]
}

/// A modal dialog iTunes is showing on the MacBook Pro. Nobody is sitting in
/// front of that machine, so the app surfaces these rather than letting them
/// block iTunes unseen.
struct ITunesAlert: Decodable, Equatable {
    let message: String
    let buttons: [String]
}

/// What came of copying tracks onto a device. `reason` is set when iTunes
/// refused every one, and explains which setting is in the way.
struct DeviceCopyResult: Decodable {
    struct Failure: Decodable {
        let persistentId: String
        let error: String
    }
    let device: String
    let added: [String]
    let failed: [Failure]
    let reason: String?
}

/// One track on the device, as iTunes reports it.
struct DeviceTrack: Decodable, Equatable {
    let name: String
    let artist: String
    let album: String
    let totalTime: Int
}

struct Output: Decodable {
    let name: String
    let kind: String
    let selected: Bool
    let active: Bool
    let available: Bool
    let volume: Int
}

struct ITunesStatus: Decodable {
    let running: Bool
    let ipodMounted: Bool
}

// MARK: Writes

struct PatchResult: Decodable {
    let requested: Int
    let updated: Int
    let failed: Int

    private enum CodingKeys: String, CodingKey { case requested, updated, changed, failed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requested = try c.decodeIfPresent(Int.self, forKey: .requested) ?? 0
        // Field edits say "updated"; artwork writes say "changed".
        updated = try c.decodeIfPresent(Int.self, forKey: .updated)
            ?? c.decodeIfPresent(Int.self, forKey: .changed) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
    }

    var summary: String {
        if failed == 0 {
            return "Updated \(updated) track\(updated == 1 ? "" : "s")."
        }
        return "Updated \(updated), failed \(failed)."
    }
}

struct PlaylistChange: Decodable {
    let playlist: Playlist
    let requested: Int
    let changed: Int
    let failed: Int

    func summary(_ verb: String) -> String {
        if failed == 0 {
            return "\(verb) \(changed) track\(changed == 1 ? "" : "s") \(verb == "Added" ? "to" : "from") \(playlist.name)."
        }
        return "\(verb) \(changed), failed \(failed)."
    }
}

/// The app's own sync selection for one device.
///
/// iTunes keeps its selection where nothing outside iTunes can read it, so the
/// app holds this one and projects it onto a playlist the device syncs. The
/// five lists stand on their own and the device gets their union, exactly as
/// iTunes' Music pane behaves: ticking an artist means that artist, and
/// unticking an album takes only that album out.
struct SyncPlan: Decodable {
    struct Selections: Decodable {
        var playlist: [String] = []
        var artist: [String] = []
        var albumartist: [String] = []
        var genre: [String] = []
        /// Stored as [artist, album] so two albums of the same name stay apart.
        var album: [[String]] = []
    }
    let device: String
    let label: String
    let playlistName: String
    var selections: Selections
}

/// Where a plan stands against iTunes. Everything here is read, never assumed.
struct SyncPlanStatus: Decodable {
    let playlistExists: Bool
    let playlistTrackCount: Int
    /// Distinct library tracks the plan covers — iTunes' "N songs" heading.
    var trackCount: Int? = nil
    /// nil means it could not be checked, not that the answer is no.
    let playlistOnDevice: Bool?
    let isConnected: Bool
    let ready: Bool
    let setupHint: String
}

struct SyncPlanReply: Decodable {
    let plan: SyncPlan?
    let status: SyncPlanStatus?
}

/// What the daemon is writing right now, for the LCD's sync view. A plan
/// rebuild reports chunks done of total and tracks so far; an iPod sync
/// reports only the songs on the device so far, since iTunes gives no total.
struct SyncProgress: Decodable, Equatable {
    let active: Bool
    var kind: String? = nil
    var label: String? = nil
    var done: Int? = nil
    var total: Int? = nil
    var tracks: Int? = nil
    var endedAt: Double? = nil
    var error: String? = nil

    /// 0...1 when the job has a known size, nil for an indeterminate one.
    var fraction: Double? {
        guard let d = done, let t = total, t > 0 else { return nil }
        return min(1, max(0, Double(d) / Double(t)))
    }
}

/// What POST /api/devices/find found: the iPod is open in iTunes, absent
/// from the USB bus, or on the bus with iTunes ignoring it ("wedged").
struct IPodSearch: Decodable {
    struct USB: Decodable {
        let name: String
        let product: String
        let mountPoint: String?
    }
    let state: String        // open | absent | locked | wedged
    let source: String?
    let restarted: Bool
    let message: String
    let usb: [USB]
}
