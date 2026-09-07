import Foundation

/// One internet radio station, as the Radio Browser directory describes it
/// (api.radio-browser.info: open, community-kept, ~58,000 stations). Saved
/// as-is into the app's station lists, so it is Codable.
struct RadioStation: Codable, Equatable {
    let uuid: String
    var name: String
    /// The stream itself: `url_resolved` when the directory has followed the
    /// playlist file through, else the address as listed.
    var url: String
    var homepage: String
    var favicon: String
    var tags: [String]
    var country: String
    var countryCode: String
    var state: String
    var language: String
    var codec: String
    var bitrate: Int
    var votes: Int
    var clicks: Int
    var latitude: Double?
    var longitude: Double?
    var hls: Bool
    /// The directory's last check found the stream up.
    var ok: Bool

    static func == (a: RadioStation, b: RadioStation) -> Bool { a.uuid == b.uuid }

    /// "Lisbon, Portugal", or just the country.
    var place: String {
        let s = state.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.caseInsensitiveCompare(country) == .orderedSame { return country }
        return "\(s), \(country)"
    }
    var tagLine: String { tags.prefix(4).joined(separator: ", ") }
    var quality: String {
        let c = codec.isEmpty ? "" : codec
        if bitrate > 0 { return c.isEmpty ? "\(bitrate) kbps" : "\(c) \(bitrate)" }
        return c
    }
    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// One line for the model: enough to choose by, short enough for many.
    var summary: String {
        var parts = [name, place]
        if !tagLine.isEmpty { parts.append(tagLine) }
        if !language.isEmpty { parts.append(language) }
        if !quality.isEmpty { parts.append(quality) }
        return parts.joined(separator: " — ")
    }

    init?(json d: [String: Any]) {
        guard let id = d["stationuuid"] as? String, !id.isEmpty,
              let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let resolved = (d["url_resolved"] as? String) ?? ""
        let listed = (d["url"] as? String) ?? ""
        let url = resolved.isEmpty ? listed : resolved
        guard !url.isEmpty else { return nil }
        func s(_ k: String) -> String { ((d[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func n(_ k: String) -> Int { (d[k] as? Int) ?? Int((d[k] as? Double) ?? 0) }
        func f(_ k: String) -> Double? { if let v = d[k] as? Double { return v }; if let v = d[k] as? Int { return Double(v) }; return nil }
        uuid = id
        self.name = name
        self.url = url
        homepage = s("homepage")
        favicon = s("favicon")
        tags = s("tags").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        country = s("country")
        countryCode = s("countrycode").uppercased()
        state = s("state")
        language = s("language").split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        codec = s("codec")
        bitrate = n("bitrate")
        votes = n("votes")
        clicks = n("clickcount")
        latitude = f("geo_lat")
        longitude = f("geo_long")
        hls = n("hls") == 1
        ok = n("lastcheckok") == 1
    }
}

struct RadioError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// The Radio Browser directory over HTTPS. Several mirrors; the first that
/// answers is kept until it fails. The directory asks for a User-Agent
/// that names the app, and counts a "click" per station played so its
/// popularity order means something.
final class RadioBrowserClient {
    static let shared = RadioBrowserClient()

    struct Query {
        var name: String?
        var tag: String?
        var countryCode: String?
        var language: String?
        var latitude: Double?
        var longitude: Double?
        var distanceKm: Double?
        /// clickcount | votes | bitrate | name | random
        var order = "clickcount"
        var limit = 60

        /// How the query reads in a status line: "jazz in PT, near Lisbon".
        var description: String {
            var parts: [String] = []
            if let n = name, !n.isEmpty { parts.append("“\(n)”") }
            if let t = tag, !t.isEmpty { parts.append(t) }
            if let c = countryCode, !c.isEmpty { parts.append("in \(c)") }
            if let l = language, !l.isEmpty { parts.append("in \(l)") }
            if latitude != nil { parts.append("nearby") }
            return parts.isEmpty ? "everything" : parts.joined(separator: " ")
        }
        var isEmpty: Bool {
            (name ?? "").isEmpty && (tag ?? "").isEmpty && (countryCode ?? "").isEmpty && (language ?? "").isEmpty && latitude == nil
        }
    }

    private let mirrors = ["https://de1.api.radio-browser.info", "https://fi1.api.radio-browser.info",
                           "https://at1.api.radio-browser.info", "https://de2.api.radio-browser.info"]
    private var mirror = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpAdditionalHeaders = ["User-Agent": "iTunesRemote/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    func search(_ q: Query) async throws -> [RadioStation] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "limit", value: String(max(1, min(q.limit, 500)))),
            URLQueryItem(name: "order", value: q.order),
        ]
        if ["clickcount", "votes", "bitrate"].contains(q.order) { items.append(URLQueryItem(name: "reverse", value: "true")) }
        if let v = q.name, !v.isEmpty { items.append(URLQueryItem(name: "name", value: v)) }
        if let v = q.tag, !v.isEmpty { items.append(URLQueryItem(name: "tag", value: v.lowercased())) }
        if let v = q.countryCode, !v.isEmpty { items.append(URLQueryItem(name: "countrycode", value: v.uppercased())) }
        if let v = q.language, !v.isEmpty { items.append(URLQueryItem(name: "language", value: v.lowercased())) }
        if let lat = q.latitude, let long = q.longitude {
            items.append(URLQueryItem(name: "geo_lat", value: String(lat)))
            items.append(URLQueryItem(name: "geo_long", value: String(long)))
            items.append(URLQueryItem(name: "geo_distance", value: String(Int((q.distanceKm ?? 60) * 1000))))
        }
        let rows = try await get("/json/stations/search", items)
        return rows.compactMap { RadioStation(json: $0) }.filter { $0.ok }
    }

    /// The most listened-to stations in the directory right now.
    func popular(limit: Int = 60) async throws -> [RadioStation] {
        try await search(Query(order: "clickcount", limit: limit))
    }

    /// Tells the directory a station was played, once per play. Its
    /// popularity order is built from these; a failure here is nobody's loss.
    func click(_ uuid: String) {
        Task { _ = try? await get("/json/url/\(uuid)", [], single: true) }
    }

    private func get(_ path: String, _ items: [URLQueryItem], single: Bool = false) async throws -> [[String: Any]] {
        var lastError: Error = RadioError("the station directory did not answer")
        for attempt in 0..<mirrors.count {
            let base = mirrors[(mirror + attempt) % mirrors.count]
            var comps = URLComponents(string: base + path)!
            if !items.isEmpty { comps.queryItems = items }
            do {
                let (data, resp) = try await session.data(from: comps.url!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RadioError("\(base) answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
                let obj = try JSONSerialization.jsonObject(with: data)
                mirror = (mirror + attempt) % mirrors.count
                if single { return (obj as? [String: Any]).map { [$0] } ?? [] }
                return obj as? [[String: Any]] ?? []
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}
