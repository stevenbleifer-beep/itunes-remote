import Foundation
import Accelerate

/// One embedding per song, so a request in words can find songs by meaning
/// rather than by an artist list the model has to read every time.
///
/// Vectors come from a small embedding model in Ollama, are cut to 256
/// dimensions (the model is trained so a prefix still works) and stored unit
/// length, so a dot product is the cosine. 93,000 songs is about 95 MB in
/// memory and one file on disk; a search is one matrix-vector multiply.
///
/// The index is built once, in the background, and then only grows: songs
/// already embedded are never sent again.
final class CuratorIndex {
    static let dims = 256

    let dir: URL
    private(set) var ids: [String] = []
    private var rowOf: [String: Int] = [:]
    private var vectors: [Float] = []
    private(set) var model = ""
    private var dirty = false

    var count: Int { ids.count }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dir = base.appendingPathComponent("iTunes Remote/curator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private var metaURL: URL { dir.appendingPathComponent("index.json") }
    private var dataURL: URL { dir.appendingPathComponent("vectors.bin") }

    // MARK: Disk

    private func load() {
        guard let meta = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let dims = obj["dims"] as? Int, dims == CuratorIndex.dims,
              let list = obj["ids"] as? [String],
              let data = try? Data(contentsOf: dataURL),
              data.count == list.count * dims * MemoryLayout<Float>.size else { return }
        model = obj["model"] as? String ?? ""
        ids = list
        vectors = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        rowOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    func save() {
        guard dirty else { return }
        let meta: [String: Any] = ["dims": CuratorIndex.dims, "model": model, "ids": ids]
        guard let data = try? JSONSerialization.data(withJSONObject: meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
        vectors.withUnsafeBufferPointer { buf in
            try? Data(buffer: buf).write(to: dataURL, options: .atomic)
        }
        dirty = false
    }

    /// Throws the index away when it was built by a different model; vectors
    /// from two models do not live in the same space.
    func reset(forModel model: String) {
        if self.model == model, !ids.isEmpty { return }
        self.model = model
        ids = []
        rowOf = [:]
        vectors = []
        dirty = true
    }

    // MARK: Contents

    func contains(_ id: String) -> Bool { rowOf[id] != nil }

    /// The stored (unit-length) vector of one song, when it has been embedded.
    func vector(of id: String) -> [Float]? {
        guard let row = rowOf[id] else { return nil }
        let start = row * CuratorIndex.dims
        return Array(vectors[start..<start + CuratorIndex.dims])
    }

    /// Cuts a raw embedding to the index's width and normalises it.
    static func prepare(_ v: [Float]) -> [Float] {
        var out = Array(v.prefix(dims))
        if out.count < dims { out += [Float](repeating: 0, count: dims - out.count) }
        var norm: Float = 0
        vDSP_dotpr(out, 1, out, 1, &norm, vDSP_Length(dims))
        if norm > 0 {
            var scale = 1 / sqrt(norm)
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(dims))
        }
        return out
    }

    func add(ids newIds: [String], vectors raw: [[Float]]) {
        for (id, v) in zip(newIds, raw) where rowOf[id] == nil {
            rowOf[id] = ids.count
            ids.append(id)
            vectors += CuratorIndex.prepare(v)
        }
        dirty = true
    }

    // MARK: Search

    /// The `k` nearest songs to a prepared query vector, best first, among
    /// those the filter allows.
    func search(_ query: [Float], k: Int, allow: ((String) -> Bool)? = nil) -> [(id: String, score: Float)] {
        let n = ids.count
        guard n > 0, query.count == CuratorIndex.dims else { return [] }
        var scores = [Float](repeating: 0, count: n)
        vectors.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(CuratorIndex.dims), 1,
                            m.baseAddress, Int32(CuratorIndex.dims), q.baseAddress, 1, 0, &scores, 1)
            }
        }
        // Keep the best k without sorting all 93,000: a small sorted buffer.
        var best: [(Int, Float)] = []
        best.reserveCapacity(k + 1)
        var floor: Float = -.infinity
        for i in 0..<n {
            let s = scores[i]
            if s <= floor { continue }
            if let allow = allow, !allow(ids[i]) { continue }
            var j = best.count
            best.append((i, s))
            while j > 0, best[j - 1].1 < s {
                best[j] = best[j - 1]
                j -= 1
            }
            best[j] = (i, s)
            if best.count > k {
                best.removeLast()
                floor = best.last!.1
            }
        }
        return best.map { (ids[$0.0], $0.1) }
    }
}
