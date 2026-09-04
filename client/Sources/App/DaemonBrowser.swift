import Foundation
import Network

/// Finds daemons on the local network by their Bonjour registration
/// (`_itunesremote._tcp`), then asks each who it is, so the setup assistant
/// can show "Steven's MacBook Pro" rather than an address.
@MainActor
final class DaemonBrowser {
    struct Found: Equatable {
        let name: String        // the Mac's name, from the daemon
        let host: String        // its .local name, kept as the home address
        let address: String     // the IP it answered on, in case .local does not resolve
        let port: Int
        let itunesVersion: String
    }

    private(set) var found: [Found] = []
    var onChange: ([Found]) -> Void = { _ in }
    private var browser: NWBrowser?
    private var probing = Set<String>()

    func start() {
        stop()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_itunesremote._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.probe(results) }
        }
        b.stateUpdateHandler = { _ in }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func probe(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, !probing.contains(name),
                  !found.contains(where: { $0.name == name }) else { continue }
            probing.insert(name)
            resolve(r.endpoint, serviceName: name)
        }
    }

    /// Connects to the advertised endpoint to learn its address, then asks
    /// the daemon's hello for its names.
    private func resolve(_ endpoint: NWEndpoint, serviceName: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint else { conn.cancel(); return }
                var address = "\(host)"
                if let i = address.firstIndex(of: "%") { address = String(address[..<i]) }   // strip the scope
                let p = Int(port.rawValue)
                conn.cancel()
                Task { @MainActor in await self?.hello(address: address, port: p, serviceName: serviceName) }
            case .failed, .cancelled:
                Task { @MainActor in self?.probing.remove(serviceName) }
            default: break
            }
        }
        conn.start(queue: .global())
    }

    private func hello(address: String, port: Int, serviceName: String) async {
        defer { probing.remove(serviceName) }
        let literal = address.contains(":") ? "[\(address)]" : address
        guard let url = URL(string: "http://\(literal):\(port)/api/hello") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["app"] as? String == "iTunes Remote" else { return }
        let f = Found(name: obj["name"] as? String ?? serviceName,
                      host: obj["host"] as? String ?? address,
                      address: address, port: obj["port"] as? Int ?? port,
                      itunesVersion: obj["itunesVersion"] as? String ?? "")
        if !found.contains(f) {
            found.append(f)
            onChange(found)
        }
    }
}
