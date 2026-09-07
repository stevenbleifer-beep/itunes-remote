import Foundation

/// A named set of stations, the radio's playlist. Kept by the app, not in
/// iTunes: a station is a URL, and iTunes' idea of one is a library entry
/// the daemon has to reparse for.
struct RadioList: Codable, Equatable {
    var id: String
    var name: String
    var stations: [RadioStation]

    static func == (a: RadioList, b: RadioList) -> Bool { a.id == b.id }
}

/// The saved lists, in Application Support/<app>/radio/lists.json, one file
/// per library profile like everything else in that folder.
@MainActor
final class RadioLists {
    private(set) var lists: [RadioList] = []
    var onChange: () -> Void = {}
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("radio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("lists.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([RadioList].self, from: data) {
            lists = saved
        }
    }

    func list(_ id: String) -> RadioList? { lists.first { $0.id == id } }

    @discardableResult
    func create(_ name: String, stations: [RadioStation] = []) -> RadioList {
        var seen = Set<String>()
        let l = RadioList(id: UUID().uuidString, name: name, stations: stations.filter { seen.insert($0.uuid).inserted })
        lists.append(l)
        lists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        return l
    }

    func rename(_ id: String, to name: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].name = name
        lists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func delete(_ id: String) {
        lists.removeAll { $0.id == id }
        save()
    }

    /// Adds what is not already there; returns how many were new.
    @discardableResult
    func add(_ stations: [RadioStation], to id: String) -> Int {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return 0 }
        let have = Set(lists[i].stations.map { $0.uuid })
        let fresh = stations.filter { !have.contains($0.uuid) }
        lists[i].stations += fresh
        if !fresh.isEmpty { save() }
        return fresh.count
    }

    func remove(_ uuids: Set<String>, from id: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].stations.removeAll { uuids.contains($0.uuid) }
        save()
    }

    func replace(_ id: String, stations: [RadioStation]) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].stations = stations
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: url, options: .atomic) }
        onChange()
    }
}


/// A station tuned to, and when: the radio's listening history, newest
/// first, kept in Application Support/<app>/radio/history.json. One entry
/// per station, moved to the top when it is played again, two hundred at most.
struct RadioPlay: Codable {
    var station: RadioStation
    var date: Date
    var plays: Int
}

@MainActor
final class RadioHistory {
    private(set) var plays: [RadioPlay] = []
    var onChange: () -> Void = {}
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("radio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([RadioPlay].self, from: data) {
            plays = saved
        }
    }

    func record(_ station: RadioStation) {
        var count = 1
        if let i = plays.firstIndex(where: { $0.station.uuid == station.uuid }) {
            count = plays[i].plays + 1
            plays.remove(at: i)
        }
        plays.insert(RadioPlay(station: station, date: Date(), plays: count), at: 0)
        if plays.count > 200 { plays.removeLast(plays.count - 200) }
        save()
    }

    func remove(_ uuids: Set<String>) {
        plays.removeAll { uuids.contains($0.station.uuid) }
        save()
    }

    func clear() {
        plays = []
        save()
    }

    /// "Just now", "20 min ago", "Yesterday 9:14 PM", "Sep 3".
    static func when(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) { f.dateStyle = .none; f.timeStyle = .short; return f.string(from: d) }
        if Calendar.current.isDateInYesterday(d) { f.timeStyle = .short; f.dateStyle = .none; return "Yesterday " + f.string(from: d) }
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plays) { try? data.write(to: url, options: .atomic) }
        onChange()
    }
}
