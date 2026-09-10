import CoreLocation
import Foundation

/// The radio's search, done by the local model the curator uses: a request
/// in plain words becomes directory searches, the results are gathered, and
/// the model chooses from them and says why. No station it names is one it
/// made up — everything comes back from the directory.
@MainActor
final class RadioAgent {
    struct Pick { let station: RadioStation; let why: String }
    struct Result {
        let picks: [Pick]
        /// Everything the searches found, for the map, in the directory's order.
        let found: [RadioStation]
        let note: String
        let seconds: Double
    }

    var onStatus: (String) -> Void = { _ in }
    /// Ask's own model: the radio's setting when it has one, else whatever
    /// the curator is on.
    var model: String { CuratorModels.radioModel }
    private let ollama: OllamaClient
    private let browser: RadioBrowserClient

    init(ollama: OllamaClient, browser: RadioBrowserClient = .shared) {
        self.ollama = ollama
        self.browser = browser
    }

    private static let planSystem = """
    You help a listener find live internet radio stations. Turn the request into searches against a station directory. \
    Reply with JSON only, of this shape: {"queries":[{"name":"","tag":"","countrycode":"","language":"","place":"","order":"clickcount"}],"note":""}. \
    Rules: countrycode is an ISO 3166-1 alpha-2 code (US, GB, FR, JP, BR…) when a country is meant. \
    tag is one lowercase word for a genre or style: jazz, classical, news, talk, sports, lofi, chillout, ambient, electronic, house, techno, hiphop, rock, indie, metal, oldies, 80s, 90s, country, blues, soul, reggae, latin, world, folk, pop. \
    place is a city or region when the listener names one and the search should be near it; leave countrycode empty then. \
    language is a language name in English (portuguese, japanese) only when the listener asks for it. \
    name only when the listener names a station. order is clickcount unless they ask for random. \
    Prefer two to five short queries over one long one; leave a field empty rather than guess. \
    note is one warm sentence to the listener about what you searched for.
    """

    private static let chooseSystem = """
    You are choosing live internet radio stations for a listener from a numbered list the directory returned. \
    Reply with JSON only: {"picks":[{"n":1,"why":"a few words"}],"note":"one sentence"}. \
    Choose up to the number asked for, best fit first, only numbers from the list, no repeats. \
    Favour stations whose tags and place match the request and, between equals, the better-known ones (earlier in the list). \
    why is under ten words: what makes this one right for the request.
    """

    func ask(_ text: String, filter: RadioFilter = RadioFilter(), want: Int = 15) async throws -> Result {
        let started = Date()
        try await ensureModel()
        onStatus("Working out what to search for…")
        var plan = try await makePlan(text, filter: filter, broaden: nil)
        var found = try await run(plan.queries)
        if found.isEmpty {
            onStatus("Nothing matched — trying a wider search…")
            plan = try await makePlan(text, filter: filter, broaden: plan.queries)
            found = try await run(plan.queries)
        }
        if found.isEmpty {
            return Result(picks: [], found: [], note: "The directory has nothing for that. Try a genre, a country or a city.",
                          seconds: Date().timeIntervalSince(started))
        }
        // Many to choose from: let the model choose. A handful: they all
        // stand, in the directory's order.
        let candidates = Array(found.prefix(60))
        if candidates.count <= want {
            return Result(picks: candidates.map { Pick(station: $0, why: "") }, found: found, note: plan.note,
                          seconds: Date().timeIntervalSince(started))
        }
        onStatus("Choosing from \(candidates.count) stations…")
        let (picks, note) = await choose(text, from: candidates, want: want)
        return Result(picks: picks, found: found, note: note.isEmpty ? plan.note : note,
                      seconds: Date().timeIntervalSince(started))
    }

    /// Fetches Ask's model when it has been chosen but never downloaded —
    /// the case when the radio is given a picker of its own in Preferences.
    private func ensureModel() async throws {
        let name = model
        let have = (try? await ollama.models()) ?? []
        guard !have.contains(where: { $0 == name || $0.hasPrefix(name + ":") }) else { return }
        let size = CuratorModels.tier(for: name).map { " (about \(Int($0.downloadGB.rounded())) GB)" } ?? ""
        onStatus("Downloading \(name)\(size)…")
        do {
            try await ollama.pull(model: name) { [weak self] fraction, text in
                Task { @MainActor in
                    let pct = fraction >= 0 ? " \(Int(fraction * 100))%" : ""
                    self?.onStatus("Downloading \(name)\(size):\(pct) \(text)")
                }
            }
        } catch {
            throw CuratorError("Could not download \(name): \(error.localizedDescription)")
        }
    }

    /// A plain search, no model: the words as a station name, and as a
    /// style, within whatever the menus have fixed.
    func search(_ text: String, filter: RadioFilter = RadioFilter()) async throws -> [RadioStation] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var byNameQ = RadioBrowserClient.Query(name: words, tag: filter.tag, countryCode: filter.countryCode, limit: 60)
        var byTagQ = RadioBrowserClient.Query(tag: words, countryCode: filter.countryCode, limit: 60)
        if let t = filter.tag, !t.isEmpty, t.lowercased() != words.lowercased() {
            // The words as a name within the fixed style; and the style
            // alone with the words as a name is the same search, so the
            // second is the words as a second style — rarely useful — skipped.
            byTagQ = byNameQ
            byNameQ.name = words
        }
        async let byName = browser.search(byNameQ)
        async let byTag = browser.search(byTagQ)
        let name = (try? await byName) ?? []
        let tag = (try? await byTag) ?? []
        return RadioAgent.merge([name, tag])
    }

    // MARK: The plan

    private struct Plan {
        var queries: [RadioBrowserClient.Query]
        var places: [String]
        var note: String
    }

    private func makePlan(_ text: String, filter: RadioFilter, broaden previous: [RadioBrowserClient.Query]?) async throws -> Plan {
        var prompt = "Request: \(text)"
        if !filter.isEmpty {
            var fixed: [String] = []
            if let t = filter.tag, !t.isEmpty { fixed.append("tag \"\(t)\"") }
            if let c = filter.countryCode, !c.isEmpty { fixed.append("countrycode \"\(c)\" (\(filter.countryName ?? c))") }
            prompt += "\n\nThe listener has fixed these in the menus, and every query must keep them: " + fixed.joined(separator: ", ") + "."
        }
        if let p = previous {
            prompt += "\n\nThese searches found nothing: " + p.map { $0.description }.joined(separator: "; ")
                + ". Search more broadly: drop the place or the country, use a more general tag, or search by name alone."
        }
        let reply = try await ollama.chatJSON(model: model, system: RadioAgent.planSystem, prompt: prompt, maxTokens: 500, temperature: 0.2)
        let obj = RadioAgent.parseJSON(reply.text)
        var queries: [RadioBrowserClient.Query] = []
        var places: [String] = []
        for q in (obj["queries"] as? [[String: Any]] ?? []).prefix(5) {
            func s(_ k: String) -> String? {
                let v = ((q[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            var query = RadioBrowserClient.Query(name: s("name"), tag: s("tag"), countryCode: s("countrycode"), language: s("language"))
            if let o = s("order"), ["clickcount", "votes", "random", "bitrate"].contains(o) { query.order = o }
            if let place = s("place") {
                onStatus("Finding \(place)…")
                if let c = await RadioAgent.geocode(place) {
                    query.latitude = c.latitude
                    query.longitude = c.longitude
                    query.distanceKm = 80
                    places.append(place)
                } else if query.countryCode == nil {
                    // Unknown to the map: try it as a name, which catches
                    // "Radio Lisboa" and the like.
                    query.name = query.name ?? place
                }
            }
            // The menus are not a suggestion.
            if let t = filter.tag, !t.isEmpty { query.tag = t }
            if let c = filter.countryCode, !c.isEmpty { query.countryCode = c }
            if !query.isEmpty { queries.append(query) }
        }
        if queries.isEmpty {
            // The model gave nothing usable: the request itself, as a name and a tag.
            queries = [RadioBrowserClient.Query(name: text, tag: filter.tag, countryCode: filter.countryCode, limit: 40),
                       RadioBrowserClient.Query(tag: filter.tag ?? text, countryCode: filter.countryCode, limit: 40)]
        }
        return Plan(queries: queries, places: places, note: (obj["note"] as? String) ?? "")
    }

    private func run(_ queries: [RadioBrowserClient.Query]) async throws -> [RadioStation] {
        onStatus("Searching: " + queries.map { $0.description }.joined(separator: "; ") + "…")
        var lists: [[RadioStation]] = []
        var lastError: Error?
        for q in queries {
            do { lists.append(try await browser.search(q)) } catch { lastError = error }
        }
        if lists.isEmpty, let e = lastError { throw e }
        return RadioAgent.merge(lists)
    }

    /// Interleaved and de-duplicated, so every search gets its best few in
    /// near the top rather than the first search taking all the room.
    static func merge(_ lists: [[RadioStation]]) -> [RadioStation] {
        var out: [RadioStation] = []
        var seen = Set<String>()
        let longest = lists.map { $0.count }.max() ?? 0
        for i in 0..<longest {
            for l in lists where i < l.count {
                if seen.insert(l[i].uuid).inserted { out.append(l[i]) }
            }
        }
        return out
    }

    private func choose(_ text: String, from candidates: [RadioStation], want: Int) async -> ([Pick], String) {
        let listing = candidates.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }.joined(separator: "\n")
        let prompt = "Request: \(text)\nChoose up to \(want).\n\nStations:\n\(listing)"
        guard let reply = try? await ollama.chatJSON(model: model, system: RadioAgent.chooseSystem, prompt: prompt,
                                                     maxTokens: 900, temperature: 0.3) else {
            return (candidates.prefix(want).map { Pick(station: $0, why: "") }, "")
        }
        let obj = RadioAgent.parseJSON(reply.text)
        var picks: [Pick] = []
        var used = Set<Int>()
        for p in obj["picks"] as? [[String: Any]] ?? [] {
            let n = (p["n"] as? Int) ?? Int((p["n"] as? String) ?? "") ?? 0
            guard n >= 1, n <= candidates.count, used.insert(n).inserted else { continue }
            picks.append(Pick(station: candidates[n - 1], why: ((p["why"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            if picks.count >= want { break }
        }
        if picks.isEmpty { picks = candidates.prefix(want).map { Pick(station: $0, why: "") } }
        return (picks, (obj["note"] as? String) ?? "")
    }

    static func geocode(_ place: String) async -> CLLocationCoordinate2D? {
        let marks = try? await CLGeocoder().geocodeAddressString(place)
        return marks?.first?.location?.coordinate
    }

    static func parseJSON(_ text: String) -> [String: Any] {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // The model wrapped it, or trailed off: take the outermost braces.
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let d = String(text[a...b]).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        return [:]
    }
}
