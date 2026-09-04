import Foundation

/// The Ollama side: a local model on this Mac, spoken to over HTTP.
final class OllamaClient {
    let baseURL: URL
    init(baseURL: URL) { self.baseURL = baseURL }

    struct ChatResult {
        let text: String
        let promptTokens: Int
        let outputTokens: Int
        let seconds: Double
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CuratorError("Ollama sent something that was not JSON")
        }
        if status != 200 {
            throw CuratorError(obj["error"] as? String ?? "Ollama answered \(status)")
        }
        return obj
    }

    func isUp() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    /// Model names Ollama has on disk.
    func models() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    func embed(model: String, texts: [String]) async throws -> [[Float]] {
        let obj = try await post("api/embed", ["model": model, "input": texts, "truncate": true], timeout: 600)
        guard let rows = obj["embeddings"] as? [[Double]] else { throw CuratorError("no embeddings came back") }
        return rows.map { $0.map(Float.init) }
    }

    /// One chat turn, answered as JSON. Thinking is off and the output is
    /// capped: left alone, a model will write pages before the answer.
    func chatJSON(model: String, system: String, prompt: String, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        let started = Date()
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "format": "json",
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "options": ["temperature": temperature, "num_ctx": 16384, "num_predict": maxTokens],
        ]
        let obj = try await post("api/chat", body, timeout: 600)
        let text = ((obj["message"] as? [String: Any])?["content"] as? String) ?? ""
        return ChatResult(text: text, promptTokens: obj["prompt_eval_count"] as? Int ?? 0,
                          outputTokens: obj["eval_count"] as? Int ?? 0, seconds: Date().timeIntervalSince(started))
    }
}

struct CuratorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A song the curator chose, with its reason.
struct CuratorPick {
    let track: Track
    var why: String
}

/// The curator: a local model that builds playlists from this library and
/// edits them on request.
///
/// The model never sees the library. Each turn it writes a short plan — the
/// mood, search phrases, artists it expects to fit — and the index and the
/// artist table turn that into a hundred-odd real candidate songs. Then it
/// picks from those by number, so it cannot name a song that is not here.
/// Feedback re-plans, so "add some slow indie rock" can reach artists that
/// were not on the table the first time.
@MainActor
final class CuratorEngine {
    static let defaultModel = "qwen3.5:4b"
    static let embedModel = "embeddinggemma:300m"

    struct Reply {
        let picks: [CuratorPick]
        let note: String
        let name: String
        let seconds: Double
    }

    let ollama: OllamaClient
    let index = CuratorIndex()
    var model: String
    var onStatus: (String) -> Void = { _ in }
    /// Called as the index grows: (done, total).
    var onIndexProgress: (Int, Int) -> Void = { _, _ in }

    private var library: [Track] = []
    private var byId: [String: Track] = [:]
    private var byArtist: [String: [Track]] = [:]
    private var artistNames: [String: String] = [:]   // folded -> display
    private var history: [String] = []
    private var request = ""
    private(set) var current: [CuratorPick] = []
    private var building = false
    private var asking = false

    init() {
        let d = UserDefaults.standard
        ollama = OllamaClient(baseURL: URL(string: d.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434")!)
        model = d.string(forKey: "curatorModel") ?? CuratorEngine.defaultModel
    }

    // MARK: Library and index

    var libraryLoaded: Bool { !library.isEmpty }
    var indexed: Int { index.count }
    var total: Int { library.count }

    /// Takes the whole library and starts (or resumes) indexing whatever is
    /// not embedded yet.
    func setLibrary(_ tracks: [Track]) {
        library = tracks
        byId = Dictionary(tracks.map { ($0.persistentId, $0) }, uniquingKeysWith: { a, _ in a })
        byArtist = [:]
        artistNames = [:]
        for t in tracks {
            for name in Set([t.artist, t.albumArtist]) where !name.isEmpty {
                let key = CuratorEngine.fold(name)
                byArtist[key, default: []].append(t)
                if artistNames[key] == nil { artistNames[key] = name }
            }
        }
        Task { await buildIndex() }
    }

    private func buildIndex() async {
        guard !building else { return }
        building = true
        defer { building = false }
        index.reset(forModel: CuratorEngine.embedModel)
        let missing = library.filter { !index.contains($0.persistentId) }
        onIndexProgress(index.count, library.count)
        guard !missing.isEmpty else { return }
        guard await ollama.isUp() else {
            onStatus("Ollama is not running, so the library cannot be indexed.")
            return
        }
        var done = 0
        let batch = 256
        var sinceSave = 0
        while done < missing.count {
            // A question in flight has the GPU; wait rather than fight it.
            while asking { try? await Task.sleep(nanoseconds: 300_000_000) }
            let slice = Array(missing[done..<min(done + batch, missing.count)])
            do {
                let vectors = try await ollama.embed(model: CuratorEngine.embedModel, texts: slice.map(CuratorEngine.text))
                index.add(ids: slice.map { $0.persistentId }, vectors: vectors)
            } catch {
                onStatus("Indexing stopped: \(error.localizedDescription)")
                index.save()
                return
            }
            done += slice.count
            sinceSave += slice.count
            if sinceSave >= 4096 {
                index.save()
                sinceSave = 0
            }
            onIndexProgress(index.count, library.count)
        }
        index.save()
        onIndexProgress(index.count, library.count)
    }

    /// What a song looks like to the embedding model.
    static func text(_ t: Track) -> String {
        var s = "\(t.name) — \(t.artist)"
        if !t.album.isEmpty { s += " (\(t.album)" + (t.year.map { ", \($0)" } ?? "") + ")" }
        if !t.genre.isEmpty { s += " · \(t.genre)" }
        return s
    }

    static func fold(_ s: String) -> String {
        var f = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        f = f.replacingOccurrences(of: "&", with: "and")
        if f.hasPrefix("the ") { f.removeFirst(4) }
        return f.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Conversation

    func reset() {
        history = []
        request = ""
        current = []
    }

    /// The list as the listener has edited it, so feedback starts from what
    /// is on screen rather than what the model last said.
    func setCurrent(_ picks: [CuratorPick]) { current = picks }

    private struct Plan {
        var vibe = ""
        var queries: [String] = []
        var artists: [String] = []
        var avoid: [String] = []
        var length = 20
        var name = ""
        /// The listener asked for a different playlist, not a change to this one.
        var fresh = false
    }

    private static let system = """
    You are a music curator working from ONE listener's personal music library on their Mac. \
    You cannot see the library; a search engine fetches candidate songs for you. \
    Answer with JSON only, exactly in the shape asked, no commentary.
    """

    /// A request, or feedback on the current list. Returns the new list.
    func ask(_ text: String) async throws -> Reply {
        guard libraryLoaded else { throw CuratorError("The library has not loaded yet.") }
        guard await ollama.isUp() else {
            throw CuratorError("Ollama is not running. Open the Ollama app and try again.")
        }
        asking = true
        defer { asking = false }
        let started = Date()
        var isFeedback = !current.isEmpty && !request.isEmpty
        if !isFeedback { request = text }

        onStatus("Thinking about what fits…")
        let plan = try await makePlan(text, feedback: isFeedback)
        // "Now something for a road trip" after a date-night list is a new
        // playlist, not an edit; the plan step says which.
        if isFeedback && plan.fresh {
            reset()
            request = text
            isFeedback = false
        }

        onStatus("Searching the library…")
        await embedQueries(plan.queries)
        let candidates = gather(plan, feedback: isFeedback)
        guard !candidates.isEmpty else { throw CuratorError("Nothing in the library seemed to fit. Try describing it differently.") }

        onStatus("Choosing from \(candidates.count) songs…")
        let reply = try await choose(text, plan: plan, candidates: candidates, feedback: isFeedback)
        current = reply.picks
        history.append("Listener: \(text)")
        let names = reply.picks.prefix(30).map { "\($0.track.name) – \($0.track.artist)" }.joined(separator: "; ")
        history.append("You: \(reply.note) Playlist (\(reply.picks.count) songs): \(names)")
        if history.count > 8 { history.removeFirst(history.count - 8) }
        return Reply(picks: reply.picks, note: reply.note, name: reply.name.isEmpty ? plan.name : reply.name,
                     seconds: Date().timeIntervalSince(started))
    }

    private func makePlan(_ text: String, feedback: Bool) async throws -> Plan {
        var prompt = ""
        if feedback {
            prompt += "The conversation so far:\n" + history.joined(separator: "\n") + "\n\n"
            prompt += "The listener's feedback on the current playlist: \(text)\n\n"
            prompt += "Plan the search for what the feedback needs (new kinds of songs, artists, moods); keep the original request in mind: \(request)\n"
            prompt += "If instead the listener is asking for a different playlist altogether, say so with \"fresh\": true and plan that.\n"
        } else {
            prompt += "The listener's request: \(text)\n"
        }
        prompt += """

        Write a JSON object:
        {
          "vibe": "one sentence: the mood, tempo and setting",
          "queries": ["8 to 12 short phrases a music search engine would match: moods, genres, eras, instruments, and specific well-known songs or albums that fit"],
          "artists": ["up to 12 well-known artists likely to fit"],
          "avoid": ["things to steer clear of: genres, moods, artists"],
          "length": how many songs the playlist should have (20 unless the listener said),
          "name": "a short playlist name, two or three words",
          "fresh": true only if this is a request for a different playlist rather than a change to the current one
        }
        """
        let r = try await ollama.chatJSON(model: model, system: CuratorEngine.system, prompt: prompt, maxTokens: 700, temperature: 0.6)
        let obj = CuratorEngine.parseJSON(r.text)
        var p = Plan()
        p.vibe = obj["vibe"] as? String ?? ""
        p.queries = (obj["queries"] as? [Any])?.compactMap { $0 as? String } ?? []
        p.artists = (obj["artists"] as? [Any])?.compactMap { $0 as? String } ?? []
        p.avoid = (obj["avoid"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let n = obj["length"] as? Int { p.length = max(3, min(60, n)) }
        else if let s = obj["length"] as? String, let n = Int(s) { p.length = max(3, min(60, n)) }
        p.name = obj["name"] as? String ?? ""
        p.fresh = (obj["fresh"] as? Bool) ?? false
        if p.queries.isEmpty { p.queries = [text] }
        return p
    }

    /// Real songs for the plan: by meaning through the index, and by name
    /// through the artist table. The current list always stays on the table.
    private func gather(_ plan: Plan, feedback: Bool) -> [Track] {
        let avoidArtists = Set(plan.avoid.map(CuratorEngine.fold))
        func avoided(_ t: Track) -> Bool {
            avoidArtists.contains(CuratorEngine.fold(t.artist)) || avoidArtists.contains(CuratorEngine.fold(t.albumArtist))
        }
        var seen = Set<String>()
        var out: [Track] = []
        func take(_ t: Track) {
            let key = CuratorEngine.fold(t.name) + "|" + CuratorEngine.fold(t.artist)
            guard !seen.contains(key), !t.name.isEmpty else { return }
            seen.insert(key)
            out.append(t)
        }
        if feedback { current.forEach { take($0.track) } }

        // Artists the model named: exact, then contained, in the library's names.
        var lists: [[Track]] = []
        for name in plan.artists {
            let key = CuratorEngine.fold(name)
            guard key.count >= 2 else { continue }
            var found = byArtist[key]
            if found == nil, key.count >= 4 {
                if let hit = byArtist.keys.first(where: { $0.hasPrefix(key + " ") || $0.hasSuffix(" " + key) || $0 == key }) {
                    found = byArtist[hit]
                }
            }
            guard let tracks = found else { continue }
            lists.append(CuratorEngine.best(of: tracks, limit: 8))
        }
        // Phrases: nearest songs by meaning, when the index has them.
        if index.count > 0 {
            for q in plan.queries {
                lists.append(searchTracks(q, k: 25).filter { !avoided($0) })
            }
        }
        // Round-robin so no single source or artist swamps the list.
        var i = 0
        let cap = 140
        while out.count < cap, lists.contains(where: { $0.count > i }) {
            for list in lists where i < list.count && out.count < cap {
                if !avoided(list[i]) { take(list[i]) }
            }
            i += 1
        }
        // Grouped by artist so the model reads it like a record shelf.
        let head = feedback ? current.count : 0
        let rest = out.dropFirst(head).sorted {
            let a = CuratorEngine.fold($0.artist), b = CuratorEngine.fold($1.artist)
            return a == b ? $0.name < $1.name : a < b
        }
        return Array(out.prefix(head)) + rest
    }

    /// The listener's own favourites first: rated, then played, studio
    /// albums before live ones, and one version of a title.
    private static func best(of tracks: [Track], limit: Int) -> [Track] {
        let live = try! NSRegularExpression(pattern: "live|demo|bootleg|session|remix", options: .caseInsensitive)
        let sorted = tracks.sorted { a, b in
            if a.rating != b.rating { return a.rating > b.rating }
            if a.playCount != b.playCount { return a.playCount > b.playCount }
            let la = live.firstMatch(in: a.album, range: NSRange(a.album.startIndex..., in: a.album)) != nil
            let lb = live.firstMatch(in: b.album, range: NSRange(b.album.startIndex..., in: b.album)) != nil
            if la != lb { return !la }
            return (a.year ?? 0) < (b.year ?? 0)
        }
        var seen = Set<String>()
        var out: [Track] = []
        for t in sorted where !seen.contains(fold(t.name)) {
            seen.insert(fold(t.name))
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// Embedding queries are cached: the same phrase costs the model once.
    private var queryCache: [String: [Float]] = [:]

    private func searchTracks(_ phrase: String, k: Int) -> [Track] {
        guard let q = queryCache[phrase] else { return [] }
        return index.search(q, k: k).compactMap { byId[$0.id] }
    }

    /// Embeds every phrase of the plan up front, one call.
    private func embedQueries(_ phrases: [String]) async {
        let fresh = phrases.filter { queryCache[$0] == nil }
        guard !fresh.isEmpty else { return }
        let texts = fresh.map { "task: search result | query: \($0)" }
        if let vs = try? await ollama.embed(model: CuratorEngine.embedModel, texts: texts) {
            for (p, v) in zip(fresh, vs) { queryCache[p] = CuratorIndex.prepare(v) }
        }
    }

    private func choose(_ text: String, plan: Plan, candidates cands: [Track], feedback: Bool) async throws -> Reply {
        let inList = Set(current.map { $0.track.persistentId })
        var lines: [String] = []
        for (i, t) in cands.enumerated() {
            var s = "\(i + 1). \(t.artist) – \(t.name) (\(t.album.isEmpty ? "?" : t.album)"
            if let y = t.year { s += " \(y)" }
            s += ")"
            if !t.genre.isEmpty { s += " [\(t.genre)]" }
            if t.rating > 0 { s += " ★\(t.rating / 20)" }
            if feedback, inList.contains(t.persistentId) { s += " ✓ in the current playlist" }
            lines.append(s)
        }
        var prompt = "Request: \(request)\n"
        if feedback {
            prompt += "The listener's feedback on the current playlist: \(text)\n"
            prompt += "Songs marked ✓ are the current playlist, in its order.\n"
        }
        prompt += "Your plan: \(plan.vibe)"
        if !plan.avoid.isEmpty { prompt += " Avoid: \(plan.avoid.joined(separator: ", "))." }
        prompt += """


        Below are candidate songs from the library, one per line, as:
          N. artist – title (album year) [genre] ★rating

        """
        if feedback {
            // An edit, described as an edit: what to drop and what to add.
            // Asked for a whole new list, the model rewrote most of it.
            prompt += """
            This is an EDIT of the current playlist, not a new one. Rules:
            - Use ONLY the numbers listed. Never invent a song.
            - "remove" lists ✓ songs the feedback objects to, and nothing else.
            - "add" lists new songs the feedback asks for ("a couple" means two or three), that fit the request.
            - If the feedback asks for a length, remove or add enough to reach it.
            - At most 2 songs by the same artist unless the request is about one artist.
            - "order" is every remaining ✓ song and every added song, sequenced like a real playlist.

            Return JSON: {"remove": [numbers], "add": [{"n": 12, "why": "a few words"}, ...], "order": [numbers], "note": "one or two sentences to the listener about what changed", "name": "a short playlist name"}

            Candidates:

            """
        } else {
            prompt += """
            Choose \(plan.length + 2) songs for the playlist. Rules:
            - Use ONLY the numbers listed. Never invent a song.
            - Sequence them like a real playlist: an opener, a flow, an ender.
            - Vary artists; at most 2 songs by the same artist unless the request is about one artist.
            - Prefer songs that clearly fit the request over merely famous ones.

            Return JSON: {"playlist": [{"n": 12, "why": "a few words"}, ...], "note": "one or two sentences to the listener about the choices", "name": "a short playlist name"}

            Candidates:

            """
        }
        prompt += lines.joined(separator: "\n")
        let r = try await ollama.chatJSON(model: model, system: CuratorEngine.system, prompt: prompt, maxTokens: 2500, temperature: 0.5)
        let obj = CuratorEngine.parseJSON(r.text)
        if feedback {
            return applyEdit(obj, text: text, plan: plan, candidates: cands, seconds: r.seconds)
        }
        let items = obj["playlist"] as? [[String: Any]] ?? []

        // The model is told the rules and forgets them often enough that
        // they are enforced here: only real numbers, no repeats, two per
        // artist, no holiday songs unless asked, and the planned length.
        let holiday = try! NSRegularExpression(pattern: "christmas|xmas|santa|jingle|silent night|noel|hanukkah", options: .caseInsensitive)
        func isHoliday(_ s: String) -> Bool { holiday.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let wantsHoliday = isHoliday(request) || isHoliday(text)
        let requestFold = CuratorEngine.fold(request + " " + text)
        var picks: [CuratorPick] = []
        var used = Set<String>()
        var perArtist: [String: Int] = [:]
        for item in items {
            var n = item["n"] as? Int
            if n == nil, let s = item["n"] as? String { n = Int(s) }
            guard let k = n, k >= 1, k <= cands.count else { continue }
            let t = cands[k - 1]
            guard !used.contains(t.persistentId) else { continue }
            let a = CuratorEngine.fold(t.artist)
            let aboutArtist = a.count >= 3 && requestFold.contains(a)
            if perArtist[a, default: 0] >= 2 && !aboutArtist { continue }
            if !wantsHoliday && (isHoliday(t.name) || isHoliday(t.album)) { continue }
            used.insert(t.persistentId)
            perArtist[a, default: 0] += 1
            picks.append(CuratorPick(track: t, why: item["why"] as? String ?? ""))
            if picks.count >= plan.length { break }
        }
        guard !picks.isEmpty else { throw CuratorError("The model did not pick any songs. Try again, or say it differently.") }
        return Reply(picks: picks, note: obj["note"] as? String ?? "", name: obj["name"] as? String ?? plan.name,
                     seconds: r.seconds)
    }

    /// The edit the model described, applied to the current list: drop what
    /// it named, add what it chose (under the same rules), then take its
    /// order for whatever survives. A number in the feedback sets the length.
    private func applyEdit(_ obj: [String: Any], text: String, plan: Plan, candidates cands: [Track], seconds: Double) -> Reply {
        func number(_ v: Any?) -> Int? {
            if let n = v as? Int { return n }
            if let s = v as? String { return Int(s) }
            return nil
        }
        func track(_ n: Int) -> Track? { n >= 1 && n <= cands.count ? cands[n - 1] : nil }
        // "Less jazz" is not "no jazz": unless the feedback asks to replace
        // most of the list, at most a third of it goes, in the order the
        // model named them. Left alone it dropped fifteen of twenty.
        let sweeping = try! NSRegularExpression(pattern: "\\b(all|everything|most|replace|redo|rebuild|start over|completely|scrap|different)\\b", options: .caseInsensitive)
        let wantsSweep = sweeping.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        var removals = ((obj["remove"] as? [Any]) ?? []).compactMap(number).compactMap(track).map { $0.persistentId }
        if !wantsSweep { removals = Array(removals.prefix(max(3, current.count / 3))) }
        let removed = Set(removals)
        var list = current.filter { !removed.contains($0.track.persistentId) }
        var perArtist: [String: Int] = [:]
        for p in list { perArtist[CuratorEngine.fold(p.track.artist), default: 0] += 1 }
        let holiday = try! NSRegularExpression(pattern: "christmas|xmas|santa|jingle|silent night|noel|hanukkah", options: .caseInsensitive)
        func isHoliday(_ s: String) -> Bool { holiday.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let wantsHoliday = isHoliday(request) || isHoliday(text)
        let requestFold = CuratorEngine.fold(request + " " + text)
        for item in (obj["add"] as? [[String: Any]]) ?? [] {
            guard let n = number(item["n"]), let t = track(n) else { continue }
            guard !list.contains(where: { $0.track.persistentId == t.persistentId }) else { continue }
            let a = CuratorEngine.fold(t.artist)
            let aboutArtist = a.count >= 3 && requestFold.contains(a)
            if perArtist[a, default: 0] >= 2 && !aboutArtist { continue }
            if !wantsHoliday && (isHoliday(t.name) || isHoliday(t.album)) { continue }
            perArtist[a, default: 0] += 1
            list.append(CuratorPick(track: t, why: item["why"] as? String ?? ""))
        }
        // The model's order, for the songs that are actually in the list;
        // anything it forgot keeps its place at the end.
        let wanted = ((obj["order"] as? [Any]) ?? []).compactMap(number).compactMap(track).map { $0.persistentId }
        if wanted.count >= list.count / 2 {
            var ordered: [CuratorPick] = []
            for id in wanted {
                if let p = list.first(where: { $0.track.persistentId == id }), !ordered.contains(where: { $0.track.persistentId == id }) {
                    ordered.append(p)
                }
            }
            ordered += list.filter { p in !ordered.contains(where: { $0.track.persistentId == p.track.persistentId }) }
            list = ordered
        }
        // "keep it to 20": a number in the feedback is a length.
        if let m = try? NSRegularExpression(pattern: "\\b([1-9][0-9]?)\\b").firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), n >= 3, list.count > n {
            list = Array(list.prefix(n))
        }
        return Reply(picks: list, note: obj["note"] as? String ?? "", name: obj["name"] as? String ?? plan.name, seconds: seconds)
    }

    private static func parseJSON(_ text: String) -> [String: Any] {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // Some models wrap the object in prose despite JSON mode.
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let d = String(text[a...b]).data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        return [:]
    }
}
