import Foundation
import Network

/// Works out whether the daemon is reachable on the local network or only
/// through the Tailscale tunnel, and says so whenever that changes.
///
/// The LAN name is probed with a short timeout on start, whenever the
/// network path changes (Wi-Fi joined or left, cable in or out) and every
/// 45 seconds as a backstop. A probe that answers means home.
@MainActor
final class ConnectionMonitor {
    enum Mode { case lan, away }

    let lanURL: URL
    private let token: String
    private(set) var mode: Mode?
    /// "Thunderbolt", "Wi-Fi" or "Ethernet": the link the LAN path uses.
    private(set) var link = ""
    var onChange: (Mode) -> Void = { _ in }

    private let session: URLSession
    private let metrics = MetricsCatcher()
    private let pathMonitor = NWPathMonitor()
    private var interfaceTypes: [String: NWInterface.InterfaceType] = [:]
    private var timer: Timer?
    private var probing = false

    init(lanURL: URL, token: String) {
        self.lanURL = lanURL
        self.token = token
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        session = URLSession(configuration: c, delegate: metrics, delegateQueue: nil)
    }

    /// Keeps the local address of the most recent request.
    final class MetricsCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var address: String?
        var lastLocalAddress: String? { lock.lock(); defer { lock.unlock() }; return address }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let a = metrics.transactionMetrics.last?.localAddress else { return }
            lock.lock(); address = a; lock.unlock()
        }
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let types = Dictionary(path.availableInterfaces.map { ($0.name, $0.type) }, uniquingKeysWith: { a, _ in a })
            Task { @MainActor in
                self?.interfaceTypes = types
                self?.probe()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.stevenbleifer.itunesremote.path"))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        probe()
    }

    func probe() {
        guard !probing else { return }
        probing = true
        var req = URLRequest(url: lanURL.appendingPathComponent("/api/library"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task {
            var reachable = false
            if let (_, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                reachable = true
            }
            probing = false
            let new: Mode = reachable ? .lan : .away
            if new == .lan {
                let l = await self.linkName()
                if new != mode || l != link {
                    link = l
                    mode = new
                    onChange(new)
                }
            } else if new != mode {
                link = ""
                mode = new
                onChange(new)
            }
        }
    }

    /// Which interface the probe's own request left on, so the badge
    /// describes the path the app's requests take rather than a separate
    /// guess: the probe and the API share the resolver and the routing.
    private func linkName() async -> String {
        guard let local = metrics.lastLocalAddress else { return "" }
        guard let name = ConnectionMonitor.interfaceName(forLocalAddress: local) else { return "" }
        if name.hasPrefix("bridge") { return "Thunderbolt" }
        if let type = interfaceTypes[name] {
            switch type {
            case .wifi: return "Wi-Fi"
            case .wiredEthernet: return name.hasPrefix("bridge") ? "Thunderbolt" : "Ethernet"
            default: return ""
            }
        }
        return name.hasPrefix("en0") ? "Wi-Fi" : ""
    }

    /// The interface that owns a local address, from getifaddrs.
    private static func interfaceName(forLocalAddress address: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                var s = String(cString: buf)
                if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
                if s == address { return String(cString: cur.pointee.ifa_name) }
            }
        }
        return nil
    }
}
