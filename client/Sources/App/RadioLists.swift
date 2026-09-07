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
