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
        let result = ChatResult(text: text, promptTokens: obj["prompt_eval_count"] as? Int ?? 0,
                                outputTokens: obj["eval_count"] as? Int ?? 0, seconds: Date().timeIntervalSince(started))
        OllamaClient.log("\(model) prompt \(result.promptTokens) tok, output \(result.outputTokens) tok (cap \(maxTokens)), \(String(format: "%.1f", result.seconds)) s\n--- prompt ---\n\(prompt.prefix(3000))\n--- reply ---\n\(text.prefix(6000))\n")
        return result
    }

    /// ~/Library/Logs/iTunesRemote/curator.log: every prompt and reply, so
    /// a bad playlist can be traced to what the model was shown and said.
    static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iTunesRemote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("curator.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = ("[\(stamp)] " + line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
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
    /// The earliest year tagged on anything by each artist: a 2013 Beatles
    /// track is a reissue, and this is how the model gets told so.
    private var artistSince: [String: Int] = [:]
    /// The order candidates came out of retrieval on the last turn, best
    /// first, for topping a list up without going alphabetical.
    private var lastRank: [String: Int] = [:]
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
                if let y = t.year, y > 1900 { artistSince[key] = min(artistSince[key] ?? y, y) }
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
        /// Years the songs must come from, when the request names an era.
        var years: ClosedRange<Int>?
    }

    /// "90s", "1970s", "the eighties", "1994 to 1998": the years a request
    /// names, read from the words rather than trusted to the model.
    static func yearRange(in text: String) -> ClosedRange<Int>? {
        let t = text.lowercased()
        let words = ["fifties": 1950, "sixties": 1960, "seventies": 1970, "eighties": 1980, "nineties": 1990,
                     "noughties": 2000, "aughts": 2000, "twenties": 2020]
        for (w, y) in words where t.contains(w) { return y...(y + 9) }
        let span = NSRange(t.startIndex..., in: t)
        if let m = try? NSRegularExpression(pattern: "\\b(19\\d\\d|20\\d\\d)\\s*(?:-|–|to|through)\\s*(19\\d\\d|20\\d\\d)\\b").firstMatch(in: t, range: span),
           let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t),
           let from = Int(t[a]), let to = Int(t[b]), from <= to {
            return from...to
        }
        if let m = try? NSRegularExpression(pattern: "\\b(?:(19|20)|')?(\\d)0'?s\\b").firstMatch(in: t, range: span),
           let d = Range(m.range(at: 2), in: t), let tens = Int(t[d]) {
            var century = 1900
            if let c = Range(m.range(at: 1), in: t), let cc = Int(t[c]) { century = cc * 100 }
            else if tens <= 2 { century = 2000 }
            let y = century + tens * 10
            return y...(y + 9)
        }
        return nil
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
          "fresh": true only if this is a request for a different playlist rather than a change to the current one,
          "years": [first year, last year] when the request names an era or years, otherwise null
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
        if let ys = obj["years"] as? [Any], ys.count == 2,
           let a = ys[0] as? Int, let b = ys[1] as? Int, a >= 1900, b <= 2100, a <= b {
            p.years = a...b
        }
        if let spoken = CuratorEngine.yearRange(in: (feedback ? request + " " : "") + text) { p.years = spoken }
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
        var undated: [Track] = []
        var rank: [String: Int] = [:]
        func take(_ t: Track) {
            let key = CuratorEngine.fold(t.name) + "|" + CuratorEngine.fold(t.artist)
            guard !seen.contains(key), !t.name.isEmpty else { return }
            if let years = plan.years {
                // An era was asked for: a song from outside it is out; one
                // with no year tag, or on a live album, remaster or
                // compilation (whose year is the reissue's, not the song's),
                // waits behind the dated ones.
                guard let y = t.year else { seen.insert(key); undated.append(t); return }
                guard years.contains(y) else { return }
                if CuratorEngine.isReissue(t) { seen.insert(key); undated.append(t); return }
            }
            seen.insert(key)
            rank[t.persistentId] = rank.count
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
        // Round-robin so no single source or artist swamps the list. A long
        // list needs a longer shelf: two per artist means fifty songs want
        // twenty-five artists with something to spare.
        var i = 0
        let cap = max(140, plan.length * 4)
        while out.count < cap, lists.contains(where: { $0.count > i }) {
            for list in lists where i < list.count && out.count < cap {
                if !avoided(list[i]) { take(list[i]) }
            }
            i += 1
        }
        if plan.years != nil, out.count < cap {
            for t in undated.prefix(min(cap - out.count, cap / 4)) {
                rank[t.persistentId] = rank.count
                out.append(t)
            }
        }
        lastRank = rank
        // Grouped by artist so the model reads it like a record shelf.
        let head = feedback ? current.count : 0
        let rest = out.dropFirst(head).sorted {
            let a = CuratorEngine.fold($0.artist), b = CuratorEngine.fold($1.artist)
            return a == b ? $0.name < $1.name : a < b
        }
        return Array(out.prefix(head)) + rest
    }

    private static let reissueWords = try! NSRegularExpression(
        pattern: "\\b(live|remaster(ed)?|anthology|greatest|best of|collection|deluxe|anniversary|bbc|sessions?|complete|box set|singles|rarities|demos|bootleg|compilation|reissue|edition|hits)\\b|\\b(19|20)\\d\\d-\\d\\d-\\d\\d\\b",
        options: .caseInsensitive)

    /// A live album, remaster, anthology or compilation: its year is when
    /// it came out, not when the songs did.
    static func isReissue(_ t: Track) -> Bool {
        let s = t.album + " | " + t.name
        return reissueWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
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
            if let years = plan.years {
                if let since = artistSince[CuratorEngine.fold(t.artist)], since < years.lowerBound - 12 {
                    s += " ⚠ artist since \(since)"
                }
                if CuratorEngine.isReissue(t) { s += " ⚠ live/reissue" }
            }
            if feedback, inList.contains(t.persistentId) { s += " ✓ in the current playlist" }
            lines.append(s)
        }
        var eraRule = ""
        if let years = plan.years {
            eraRule = "- The listener wants songs from \(years.lowerBound) to \(years.upperBound). The year shown is the album's release. Skip anything that is really an older song: a live recording, remaster, reissue, or a cover of an old standard. ⚠ marks an artist active since long before then, or a live/reissue album; take those only if you know the song itself is from the era.\n"
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
            \(eraRule)
            Return JSON: {"remove": [numbers], "add": [{"n": 12, "why": "a few words"}, ...], "order": [numbers], "note": "one or two sentences to the listener about what changed", "name": "a short playlist name"}

            Candidates:

            """
        } else {
            prompt += """
            Choose \(plan.length + max(6, plan.length / 3)) songs for the playlist. Rules:
            - Use ONLY the numbers listed. Never invent a song.
            - Sequence them like a real playlist: an opener, a flow, an ender.
            - Vary artists; at most 2 songs by the same artist unless the request is about one artist.
            - Prefer songs that clearly fit the request over merely famous ones.
            \(eraRule)
            Return JSON: {"playlist": [{"n": 12, "why": "a few words"}, ...], "note": "one or two sentences to the listener about the choices", "name": "a short playlist name"}

            Candidates:

            """
        }
        prompt += lines.joined(separator: "\n")
        let r = try await ollama.chatJSON(model: model, system: CuratorEngine.system, prompt: prompt,
                                          maxTokens: 600 + 60 * (plan.length + max(6, plan.length / 3)), temperature: 0.5)
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
        // The rules above cost a few picks. Short, the model is asked for
        // the rest — with reasons — rather than the list being padded from
        // candidates it never judged.
        var seconds = r.seconds
        if picks.count < plan.length {
            onStatus("Choosing \(plan.length - picks.count) more…")
            let more = try await chooseMore(plan.length - picks.count, plan: plan, candidates: cands, eraRule: eraRule,
                                            used: &used, perArtist: &perArtist, requestFold: requestFold,
                                            allowHoliday: wantsHoliday, isHoliday: isHoliday)
            picks += more.picks
            seconds += more.seconds
        }
        fill(&picks, to: plan.length, from: cands, perArtist: &perArtist, requestFold: requestFold,
             allowHoliday: wantsHoliday, isHoliday: isHoliday, years: plan.years)
        return Reply(picks: picks, note: obj["note"] as? String ?? "", name: obj["name"] as? String ?? plan.name,
                     seconds: seconds)
    }

    /// A second, smaller ask: this many more songs from the candidates not
    /// yet taken, same rules, each with its reason.
    private func chooseMore(_ count: Int, plan: Plan, candidates cands: [Track], eraRule: String,
                            used: inout Set<String>, perArtist: inout [String: Int], requestFold: String,
                            allowHoliday: Bool, isHoliday: (String) -> Bool) async throws -> (picks: [CuratorPick], seconds: Double) {
        var lines: [String] = []
        for (i, t) in cands.enumerated() where !used.contains(t.persistentId) {
            let a = CuratorEngine.fold(t.artist)
            if perArtist[a, default: 0] >= 2 && !(a.count >= 3 && requestFold.contains(a)) { continue }
            if let years = plan.years, let y = t.year, !years.contains(y) { continue }
            var s = "\(i + 1). \(t.artist) – \(t.name) (\(t.album.isEmpty ? "?" : t.album)"
            if let y = t.year { s += " \(y)" }
            s += ")"
            if !t.genre.isEmpty { s += " [\(t.genre)]" }
            if let years = plan.years {
                if let since = artistSince[a], since < years.lowerBound - 12 { s += " ⚠ artist since \(since)" }
                if CuratorEngine.isReissue(t) { s += " ⚠ live/reissue" }
            }
            lines.append(s)
        }
        guard !lines.isEmpty else { return ([], 0) }
        let prompt = """
        Request: \(request)
        Your plan: \(plan.vibe)
        The playlist already has most of its songs. Choose \(count + 2) MORE from the candidates below, one per line as N. artist – title (album year) [genre]. Rules:
        - Use ONLY the numbers listed. Never invent a song.
        - Prefer songs that clearly fit the request.
        \(eraRule)
        Return JSON: {"playlist": [{"n": 12, "why": "a few words"}, ...]}

        Candidates:

        """ + lines.joined(separator: "\n")
        let r = try await ollama.chatJSON(model: model, system: CuratorEngine.system, prompt: prompt,
                                          maxTokens: 300 + 60 * (count + 2), temperature: 0.5)
        let obj = CuratorEngine.parseJSON(r.text)
        var out: [CuratorPick] = []
        for item in (obj["playlist"] as? [[String: Any]]) ?? [] {
            var n = item["n"] as? Int
            if n == nil, let s = item["n"] as? String { n = Int(s) }
            guard let k = n, k >= 1, k <= cands.count else { continue }
            let t = cands[k - 1]
            guard !used.contains(t.persistentId) else { continue }
            let a = CuratorEngine.fold(t.artist)
            if perArtist[a, default: 0] >= 2 && !(a.count >= 3 && requestFold.contains(a)) { continue }
            if !allowHoliday && (isHoliday(t.name) || isHoliday(t.album)) { continue }
            if let years = plan.years, let y = t.year, !years.contains(y) { continue }
            used.insert(t.persistentId)
            perArtist[a, default: 0] += 1
            out.append(CuratorPick(track: t, why: item["why"] as? String ?? ""))
            if out.count >= count { break }
        }
        return (out, r.seconds)
    }

    /// Tops a list up to `length` from the candidates the model passed over,
    /// under the same rules, dated songs first when an era was asked for.
    private func fill(_ picks: inout [CuratorPick], to length: Int, from cands: [Track], perArtist: inout [String: Int],
                      requestFold: String, allowHoliday: Bool, isHoliday: (String) -> Bool, years: ClosedRange<Int>?) {
        guard picks.count < length else { return }
        let used = Set(picks.map { $0.track.persistentId })
        // Best retrieval rank first, never alphabetical; with an era asked
        // for, dated studio songs before undated or reissued ones.
        let pool = cands.filter { !used.contains($0.persistentId) }
            .sorted { (lastRank[$0.persistentId] ?? .max) < (lastRank[$1.persistentId] ?? .max) }
        func doubtful(_ t: Track) -> Bool {
            guard let years = years else { return false }
            if t.year == nil || CuratorEngine.isReissue(t) { return true }
            if let since = artistSince[CuratorEngine.fold(t.artist)], since < years.lowerBound - 12 { return true }
            return false
        }
        let ordered = years == nil ? pool : pool.filter { !doubtful($0) } + pool.filter { doubtful($0) }
        for t in ordered where picks.count < length {
            if let years = years, let y = t.year, !years.contains(y) { continue }
            let a = CuratorEngine.fold(t.artist)
            let aboutArtist = a.count >= 3 && requestFold.contains(a)
            if perArtist[a, default: 0] >= 2 && !aboutArtist { continue }
            if !allowHoliday && (isHoliday(t.name) || isHoliday(t.album)) { continue }
            perArtist[a, default: 0] += 1
            picks.append(CuratorPick(track: t, why: ""))
        }
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
            if let years = plan.years, let y = t.year, !years.contains(y) { continue }
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
        // "keep it to 20": a number in the feedback is a length, cut or filled.
        // Without one, a swap keeps the length it had: the model removes
        // four and adds three, and the listener did not ask for nineteen.
        // Removals with nothing added are taken as removals, and stay.
        let added = list.count - (current.count - removed.count)
        if let m = try? NSRegularExpression(pattern: "\\b([1-9][0-9]?)\\b").firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text), let n = Int(text[r]), n >= 3 {
            if list.count > n {
                list = Array(list.prefix(n))
            } else if list.count < n {
                fill(&list, to: n, from: cands, perArtist: &perArtist, requestFold: requestFold,
                     allowHoliday: wantsHoliday, isHoliday: isHoliday, years: plan.years)
            }
        } else if added > 0 {
            // "Add a couple more" may grow it; a swap, or anything else,
            // keeps the length it had.
            let span = NSRange(text.startIndex..., in: text)
            let grows = (try? NSRegularExpression(pattern: "\\b(add|more|extra|another|include|longer)\\b", options: .caseInsensitive))?
                .firstMatch(in: text, range: span) != nil
            let swaps = (try? NSRegularExpression(pattern: "\\b(swap|replace|instead|trade|switch|change)\\b", options: .caseInsensitive))?
                .firstMatch(in: text, range: span) != nil
            if swaps || !grows {
                if list.count > current.count {
                    list = Array(list.prefix(current.count))
                } else if list.count < current.count {
                    fill(&list, to: current.count, from: cands, perArtist: &perArtist, requestFold: requestFold,
                         allowHoliday: wantsHoliday, isHoliday: isHoliday, years: plan.years)
                }
            }
        }
        return Reply(picks: list, note: obj["note"] as? String ?? "", name: obj["name"] as? String ?? plan.name, seconds: seconds)
    }

    private static func parseJSON(_ text: String) -> [String: Any] {
        if let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // Some models wrap the object in prose despite JSON mode.
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
           let d = String(text[a...b]).data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // Cut off mid-list by the output cap: keep the complete entries.
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            let head = String(text[a...b])
            for tail in ["]}", "]}}", "}]}"] {
                if let d = (head + tail).data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    OllamaClient.log("salvaged a cut-off reply")
                    return o
                }
            }
        }
        return [:]
    }
}
