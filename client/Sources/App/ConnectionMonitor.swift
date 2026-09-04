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
            if new != mode {
                mode = new
                onChange(new)
            }
        }
    }
}
