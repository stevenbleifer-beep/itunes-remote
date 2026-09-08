import Foundation

/// The stations marked as favorites, in the order they were marked, kept
/// in Application Support/<app>/radio/favorites.json. (Named lists came
/// before this; their file, lists.json, is left where it is.)
@MainActor
final class RadioFavorites {
    private(set) var stations: [RadioStation] = []
    var onChange: () -> Void = {}
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("radio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([RadioStation].self, from: data) {
            stations = saved
        }
    }

    var uuids: Set<String> { Set(stations.map { $0.uuid }) }
    func contains(_ s: RadioStation) -> Bool { stations.contains { $0.uuid == s.uuid } }

    /// Adds what is not there yet; returns how many were new.
    @discardableResult
    func add(_ new: [RadioStation]) -> Int {
        let have = uuids
        let fresh = new.filter { !have.contains($0.uuid) }
        guard !fresh.isEmpty else { return 0 }
        stations += fresh
        save()
        return fresh.count
    }

    func remove(_ ids: Set<String>) {
        stations.removeAll { ids.contains($0.uuid) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stations) { try? data.write(to: url, options: .atomic) }
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
