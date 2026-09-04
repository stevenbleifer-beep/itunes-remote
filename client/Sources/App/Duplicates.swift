import Foundation

/// Finds songs the library holds more than once, the way iTunes' Show
/// Duplicates did: the same title by the same artist, within a couple of
/// seconds of the same length. (Title and artist alone would pair a studio
/// cut with its live version; the length keeps those apart.)
///
/// Each group is ordered with the copy worth keeping first: the highest bit
/// rate, then the rated one, then the most played, then the one added
/// first. The rest are the "extras" the view shows grey.
@MainActor
enum Duplicates {
    struct Found {
        let tracks: [Track]
        let extras: Set<String>
        let groups: Int
    }

    static func find(in tracks: [Track]) -> Found {
        var byKey: [String: [Track]] = [:]
        for t in tracks where !t.name.isEmpty {
            byKey[fold(t.name) + "|" + fold(t.artist), default: []].append(t)
        }
        var groups: [[Track]] = []
        for (_, list) in byKey where list.count > 1 {
            // Split the name/artist bucket by length: two songs closer than
            // two seconds are one recording, or near enough.
            var clusters: [[Track]] = []
            for t in list.sorted(by: { ($0.totalTime ?? 0) < ($1.totalTime ?? 0) }) {
                if let last = clusters.last?.last, let a = last.totalTime, let b = t.totalTime, abs(a - b) <= 2000 {
                    clusters[clusters.count - 1].append(t)
                } else {
                    clusters.append([t])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                groups.append(cluster.sorted(by: keepFirst))
            }
        }
        // Groups in library order, by the keeper, so the list reads by
        // artist like the rest of the app.
        groups.sort { LibraryController.artistKey($0[0]) < LibraryController.artistKey($1[0]) }
        var extras = Set<String>()
        for g in groups { for t in g.dropFirst() { extras.insert(t.persistentId) } }
        return Found(tracks: groups.flatMap { $0 }, extras: extras, groups: groups.count)
    }

    /// Which copy to keep, best first.
    static func keepFirst(_ a: Track, _ b: Track) -> Bool {
        if (a.bitRate ?? 0) != (b.bitRate ?? 0) { return (a.bitRate ?? 0) > (b.bitRate ?? 0) }
        if a.rating != b.rating { return a.rating > b.rating }
        if a.playCount != b.playCount { return a.playCount > b.playCount }
        return a.dateAdded < b.dateAdded
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
