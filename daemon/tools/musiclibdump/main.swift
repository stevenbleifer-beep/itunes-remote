// musiclibdump: the Music.app library as an iTunes-style library plist.
//
// Music.app (macOS Catalina and later) no longer writes "iTunes Music
// Library.xml", so the daemon cannot read the library the way it does on
// the MacBook Pro. Apple's iTunesLibrary framework reads Music's own
// database in well under a second, and this tool writes what it finds in
// the exact shape of the old XML — a "Tracks" dictionary and a "Playlists"
// array with the same key names — as a binary plist, so library.py parses
// it with the same code and none of the browser, sort or grouping rules
// need a second implementation.
//
//   musiclibdump dump OUT.plist          write the library
//   musiclibdump artwork OUTDIR < PIDS   one cover per persistent ID on stdin,
//                                        written to OUTDIR/<PID>.<ext>
//
// Only songs are written (no videos, podcasts, audiobooks); Apple Music
// cloud tracks are included with "Track Type" "Remote" and no "Location",
// plus a "Cloud" flag.

import Foundation
import iTunesLibrary

func hex(_ n: NSNumber) -> String { String(format: "%016llX", n.uint64Value) }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func loadLibrary() -> ITLibrary {
    do { return try ITLibrary(apiVersion: "1.1") } catch { fail("cannot open the Music library: \(error.localizedDescription)") }
}

func trackDict(_ m: ITLibMediaItem, id: Int) -> [String: Any] {
    var d: [String: Any] = [
        "Track ID": id,
        "Persistent ID": hex(m.persistentID),
        "Name": m.title,
        "Track Type": m.locationType == .file ? "File" : "Remote",
        "Kind": m.kind ?? "",
        "Total Time": m.totalTime,
        "Size": Int(m.fileSize),
        "Bit Rate": m.bitrate,
        "Play Count": m.playCount,
        "Rating": m.rating,
        "Artwork Count": m.hasArtworkAvailable ? 1 : 0,
        "Cloud": m.isCloud,
    ]
    func put(_ key: String, _ s: String?) { if let s = s, !s.isEmpty { d[key] = s } }
    func putInt(_ key: String, _ n: Int) { if n != 0 { d[key] = n } }
    put("Artist", m.artist?.name)
    put("Sort Artist", m.artist?.sortName)
    put("Album", m.album.title)
    put("Sort Album", m.album.sortTitle)
    put("Album Artist", m.album.albumArtist)
    put("Sort Album Artist", m.album.sortAlbumArtist)
    put("Sort Name", m.sortTitle)
    put("Genre", m.genre)
    put("Composer", m.composer)
    put("Sort Composer", m.sortComposer)
    put("Grouping", m.grouping)
    putInt("Year", m.year)
    putInt("Track Number", m.trackNumber)
    putInt("Track Count", m.album.trackCount)
    putInt("Disc Number", m.album.discNumber)
    putInt("Disc Count", m.album.discCount)
    putInt("BPM", m.beatsPerMinute)
    if m.album.isCompilation { d["Compilation"] = true }
    if m.isUserDisabled { d["Disabled"] = true }
    if m.isRatingComputed { d["Rating Computed"] = true }
    if let dt = m.addedDate { d["Date Added"] = dt }
    if let dt = m.modifiedDate { d["Date Modified"] = dt }
    if let dt = m.lastPlayedDate { d["Play Date UTC"] = dt }
    if let url = m.location { d["Location"] = url.absoluteString }
    return d
}

func dump(to path: String) {
    let t0 = Date()
    let lib = loadLibrary()
    var tracks: [String: Any] = [:]
    var ids: [UInt64: Int] = [:]
    var next = 1
    for m in lib.allMediaItems where m.mediaKind == .kindSong {
        let id = next; next += 1
        ids[m.persistentID.uint64Value] = id
        tracks[String(id)] = trackDict(m, id: id)
    }
    var playlists: [[String: Any]] = []
    for p in lib.allPlaylists where p.isVisible {
        var d: [String: Any] = [
            "Name": p.name,
            "Playlist ID": Int(truncatingIfNeeded: p.persistentID.uint64Value),
            "Playlist Persistent ID": hex(p.persistentID),
        ]
        if p.isPrimary { d["Master"] = true }
        if p.distinguishedKind != .kindNone { d["Distinguished Kind"] = Int(p.distinguishedKind.rawValue) }
        if p.kind == .folder { d["Folder"] = true }
        if p.kind == .smart || p.kind == .genius || p.kind == .geniusMix { d["Smart Info"] = Data() }
        if let parent = p.parentID { d["Parent Persistent ID"] = hex(parent) }
        d["Playlist Items"] = p.items.compactMap { ids[$0.persistentID.uint64Value] }.map { ["Track ID": $0] }
        playlists.append(d)
    }
    let root: [String: Any] = [
        "Major Version": 1,
        "Minor Version": 1,
        "Date": Date(),
        "Application Version": lib.applicationVersion,
        "Library Persistent ID": "MUSICAPP",
        "Music Folder": lib.mediaFolderLocation?.absoluteString ?? "",
        "Tracks": tracks,
        "Playlists": playlists,
    ]
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        // Write beside the target and rename, so a reader never sees a half file.
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    } catch { fail("cannot write \(path): \(error.localizedDescription)") }
    print("wrote \(path): \(tracks.count) songs, \(playlists.count) playlists, \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
}

func artworkBatch(dir: String) {
    let lib = loadLibrary()
    var byPid: [String: ITLibMediaItem] = [:]
    for m in lib.allMediaItems { byPid[hex(m.persistentID)] = m }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    while let line = readLine() {
        let pid = line.trimmingCharacters(in: .whitespaces).uppercased()
        guard !pid.isEmpty else { continue }
        guard let m = byPid[pid], let art = m.artwork, let data = art.imageData else { print("\(pid) none"); continue }
        let ext: String
        switch art.imageDataFormat {
        case .PNG: ext = "png"
        case .JPEG: ext = "jpg"
        case .GIF: ext = "gif"
        case .TIFF: ext = "tiff"
        case .BMP: ext = "bmp"
        default: ext = "bin"
        }
        let out = (dir as NSString).appendingPathComponent("\(pid).\(ext)")
        do { try data.write(to: URL(fileURLWithPath: out)); print("\(pid) \(out)") } catch { print("\(pid) error \(error.localizedDescription)") }
    }
}

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count > 2 ? args[2] : nil) {
case ("dump", let path?): dump(to: path)
case ("artwork", let dir?): artworkBatch(dir: dir)
default: fail("usage: musiclibdump dump OUT.plist | musiclibdump artwork OUTDIR < PIDS")
}
