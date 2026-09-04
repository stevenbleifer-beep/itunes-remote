import Cocoa

/// Fetches and caches album art. Misses are remembered too, because a track
/// with no artwork costs the daemon an AppleScript round trip to discover.
@MainActor
final class ArtworkCache {
    var api: APIClient?

    private let cache = NSCache<NSString, NSImage>()
    private var misses = Set<String>()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    init(limit: Int = 400) {
        cache.countLimit = limit
    }

    func cached(_ persistentId: String) -> NSImage? {
        cache.object(forKey: persistentId as NSString)
    }

    func isKnownMiss(_ persistentId: String) -> Bool {
        misses.contains(persistentId)
    }

    /// Calls back on the main actor, immediately when already cached.
    func image(for persistentId: String, then completion: @escaping (NSImage?) -> Void) {
        if let hit = cache.object(forKey: persistentId as NSString) {
            completion(hit)
            return
        }
        if misses.contains(persistentId) {
            completion(nil)
            return
        }
        if inFlight[persistentId] != nil {
            inFlight[persistentId]?.append(completion)
            return
        }
        guard let api = api else {
            completion(nil)
            return
        }
        inFlight[persistentId] = [completion]
        Task {
            var image: NSImage?
            // Only a 404 means "this track has no artwork". Anything else is
            // the daemon being unreachable, and remembering that as a miss
            // blacklisted the cover for the life of the process: restarting
            // the daemon once left Cover Flow showing grey placeholders until
            // the app was relaunched.
            var definitelyNone = false
            // A cover iTunes still has to export comes back "pending"; keep
            // asking, at a widening interval, for about a minute.
            var delay: UInt64 = 1_500_000_000
            var tries = 0
            while tries < 12 {
                tries += 1
                do {
                    switch try await api.artwork(for: persistentId) {
                    case .image(let data):
                        image = NSImage(data: data)
                    case .none:
                        definitelyNone = true
                    case .pending:
                        try? await Task.sleep(nanoseconds: delay)
                        delay = min(delay + 1_000_000_000, 6_000_000_000)
                        continue
                    }
                } catch {
                    definitelyNone = false
                }
                break
            }
            if let image = image {
                cache.setObject(image, forKey: persistentId as NSString)
            } else if definitelyNone {
                misses.insert(persistentId)
            }
            let waiting = inFlight.removeValue(forKey: persistentId) ?? []
            for block in waiting { block(image) }
        }
    }

    func clear() {
        cache.removeAllObjects()
        misses.removeAll()
    }

    /// Drops what is known about these tracks: their art just changed.
    func forget(_ ids: [String]) {
        for id in ids {
            cache.removeObject(forKey: id as NSString)
            misses.remove(id)
        }
    }
}
