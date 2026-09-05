import Foundation

/// What the listener has taught the curator by editing its playlists: the
/// songs they took out, what they said, what they asked for instead, and
/// the lists they kept. Read back on requests like the old ones, so the
/// same song is not offered twice for the same idea, and the model sees
/// what this listener has objected to before.
///
/// Lives beside the search index in Application Support/iTunes Remote/curator:
/// `memory.json` for the lessons, and `training.jsonl` for the turns the
/// listener approved by saving, in the chat format a fine-tune reads.
@MainActor
final class CuratorMemory {
    struct Song: Codable, Equatable {
        let id: String
        let name: String
        let artist: String
        let album: String
        let year: Int?
        init(_ t: Track) { id = t.persistentId; name = t.name; artist = t.artist; album = t.album; year = t.year }
        var line: String { "\(artist) – \(name)" + (year.map { " (\($0))" } ?? "") }
    }

    /// One request and everything the listener did about it.
    struct Lesson: Codable {
        var date: Date
        var request: String
        var feedback: [String] = []   // what they said, in order
        var removed: [Song] = []      // by feedback or by hand
        var added: [Song] = []        // by feedback
        var kept: [Song] = []         // the list as saved
        var saved = false
        var vector: [Float]?          // the request's embedding, to find it again

        var isEmpty: Bool { feedback.isEmpty && removed.isEmpty && added.isEmpty && !saved }
    }

    private(set) var lessons: [Lesson] = []
    private let url: URL
    private let trainingURL: URL
    private var open: Int?
    private var dirty = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("\(AppIdentity.supportFolder)/curator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
        trainingURL = dir.appendingPathComponent("training.jsonl")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Lesson].self, from: data) {
            lessons = list
        }
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        if let data = try? JSONEncoder().encode(lessons) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: The request in progress

    /// A new request: its lesson starts empty and fills as the listener edits.
    func begin(request: String, vector: [Float]?) {
        close()
        lessons.append(Lesson(date: Date(), request: request, vector: vector))
        if lessons.count > 500 { lessons.removeFirst(lessons.count - 500) }
        open = lessons.count - 1
        dirty = true
    }

    /// Nothing more will be said about the request; a lesson that taught
    /// nothing is dropped.
    func close() {
        if let i = open, i < lessons.count, lessons[i].isEmpty { lessons.remove(at: i) }
        open = nil
        dirty = true
        save()
    }

    func noteFeedback(_ text: String) {
        guard let i = open else { return }
        lessons[i].feedback.append(text)
        dirty = true
        save()
    }

    func noteRemoved(_ tracks: [Track]) {
        guard let i = open, !tracks.isEmpty else { return }
        for t in tracks {
            let s = Song(t)
            if !lessons[i].removed.contains(s) { lessons[i].removed.append(s) }
            lessons[i].added.removeAll { $0 == s }
        }
        dirty = true
        save()
    }

    func noteAdded(_ tracks: [Track]) {
        guard let i = open, !tracks.isEmpty else { return }
        for t in tracks {
            let s = Song(t)
            if !lessons[i].added.contains(s) { lessons[i].added.append(s) }
            lessons[i].removed.removeAll { $0 == s }
        }
        dirty = true
        save()
    }

    /// The listener saved the list: what is in it is approved.
    func noteSaved(_ tracks: [Track]) {
        guard let i = open else { return }
        lessons[i].kept = tracks.map(Song.init)
        lessons[i].saved = true
        dirty = true
        save()
    }

    // MARK: Reading it back

    /// Lessons about requests like this one, most alike first: the same
    /// words, or an embedding within reach. Only lessons that taught something.
    func similar(to vector: [Float]?, request: String, limit: Int = 4) -> [Lesson] {
        let want = CuratorEngine.fold(request)
        var scored: [(Lesson, Float)] = []
        for (i, l) in lessons.enumerated() where i != open && !l.isEmpty {
            if CuratorEngine.fold(l.request) == want { scored.append((l, 2)); continue }
            guard let v = vector, let w = l.vector, v.count == w.count else { continue }
            var dot: Float = 0
            for k in 0..<v.count { dot += v[k] * w[k] }
            if dot >= 0.62 { scored.append((l, dot)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// Songs not to offer: taken out of a list like this one before, or
    /// taken out of any list twice.
    func unwanted(near similar: [Lesson]) -> Set<String> {
        var out = Set<String>()
        for l in similar { for s in l.removed { out.insert(s.id) } }
        var count: [String: Int] = [:]
        for l in lessons { for s in l.removed { count[s.id, default: 0] += 1 } }
        for (id, n) in count where n >= 2 { out.insert(id) }
        return out
    }

    /// A few lines for the prompt about what this listener did last time.
    func summary(of similar: [Lesson]) -> String {
        guard !similar.isEmpty else { return "" }
        var lines: [String] = []
        for l in similar.prefix(3) {
            var s = "For “\(l.request)”"
            var parts: [String] = []
            if !l.feedback.isEmpty { parts.append("they said: " + l.feedback.prefix(2).map { "“\($0)”" }.joined(separator: " and ")) }
            if !l.removed.isEmpty { parts.append("they took out " + l.removed.prefix(5).map { $0.line }.joined(separator: "; ")) }
            if !l.added.isEmpty { parts.append("they asked for " + l.added.prefix(4).map { $0.line }.joined(separator: "; ")) }
            if l.saved && !l.kept.isEmpty { parts.append("they kept a list with " + l.kept.prefix(5).map { $0.line }.joined(separator: "; ")) }
            guard !parts.isEmpty else { continue }
            s += " " + parts.joined(separator: "; ") + "."
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    /// What the listener said about requests like this, for the planner.
    func remarks(of similar: [Lesson]) -> [String] {
        similar.flatMap { $0.feedback }.prefix(4).map { $0 }
    }

    // MARK: Training examples

    /// One approved turn, in the chat shape mlx-lm's fine-tune reads:
    /// the prompt the model saw and the answer the listener ended up with.
    func recordExample(system: String, prompt: String, answer: [String: Any]) {
        guard let a = try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]),
              let answerText = String(data: a, encoding: .utf8) else { return }
        let obj: [String: Any] = ["messages": [
            ["role": "system", "content": system],
            ["role": "user", "content": prompt],
            ["role": "assistant", "content": answerText],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: trainingURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: trainingURL)
        }
    }

    /// How many approved turns are on file.
    var exampleCount: Int {
        guard let s = try? String(contentsOf: trainingURL, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }
}
