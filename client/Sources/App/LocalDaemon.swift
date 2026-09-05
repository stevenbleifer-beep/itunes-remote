import Foundation

/// The daemon on *this* Mac, for the Apple Music library in Music.app.
///
/// The daemon is bundled (Resources/daemon, with musiclibdump in Helpers)
/// and installed by its own installer as a LaunchAgent, exactly as it is on
/// a Mac that runs iTunes. Because it runs as the same user, the app reads
/// the token straight from the daemon's config instead of pairing.
enum LocalDaemon {
    static let host = "127.0.0.1"
    static let support = NSString(string: "~/Library/Application Support/iTunesRemote").expandingTildeInPath
    static var configPath: String { support + "/config.json" }

    static var musicVersion: String {
        for app in ["/System/Applications/Music.app", "/Applications/Music.app"] {
            if let d = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
               let v = d["CFBundleShortVersionString"] as? String { return v }
        }
        return ""
    }

    /// Music.app is here, so the library can be read without another Mac.
    static var available: Bool { !musicVersion.isEmpty }

    static func config() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static var port: Int { (config()?["port"] as? Int) ?? 8765 }
    static var token: String? {
        let t = config()?["token"] as? String ?? ""
        return t.isEmpty ? nil : t
    }

    static var installer: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("daemon/Install iTunes Remote Daemon.command")
    }

    /// Runs the bundled installer without its pauses. Returns its output;
    /// throws with the tail of it when it fails.
    static func install() async throws -> String {
        guard let script = installer, FileManager.default.fileExists(atPath: script.path) else {
            throw APIError(status: 0, message: "this build has no daemon bundled; build the app with client/build.sh")
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--quiet"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    let tail = out.split(separator: "\n").suffix(3).joined(separator: " ")
                    cont.resume(throwing: APIError(status: 0, message: tail.isEmpty ? "the installer failed" : tail))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Waits for the daemon to answer /api/hello, for up to `seconds`.
    static func waitForHello(seconds: Int) async -> DaemonHello? {
        for _ in 0..<max(1, seconds / 2) {
            if let h = try? await APIClient.hello(host: host, port: port) { return h }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }
}
