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
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var probing = false

    init(lanURL: URL, token: String) {
        self.lanURL = lanURL
        self.token = token
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.probe() }
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

    /// A one-shot latch safe to hit from two queues.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    /// Opens a connection to the LAN host and reads which interface it went
    /// out on. A Thunderbolt bridge shows up as wired Ethernet on bridge0.
    private func linkName() async -> String {
        guard let host = lanURL.host, let port = NWEndpoint.Port(rawValue: UInt16(lanURL.port ?? 8765)) else { return "" }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = OnceBox()
            @Sendable func finish(_ s: String) {
                guard once.take() else { return }
                conn.cancel()
                cont.resume(returning: s)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let i = conn.currentPath?.availableInterfaces.first else { finish(""); return }
                    if i.name.hasPrefix("bridge") { finish("Thunderbolt") }
                    else if i.type == .wifi { finish("Wi-Fi") }
                    else if i.type == .wiredEthernet { finish("Ethernet") }
                    else { finish("") }
                case .failed, .cancelled: finish("")
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish("") }
        }
    }
}
