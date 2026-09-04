import Foundation

/// The model server the curator talks to. Ollama's own app, if it is
/// running on this Mac, is used as it is; otherwise the copy of Ollama
/// inside this app's bundle is started as a child process on a private port
/// with its own models folder, and stopped when the app quits. Nobody has
/// to install anything: the models download on first use.
@MainActor
final class OllamaRuntime {
    static let shared = OllamaRuntime()

    /// Where an Ollama app on this Mac would answer.
    let systemURL: URL
    /// The embedded server's address: a port nothing else uses.
    let embeddedURL = URL(string: "http://127.0.0.1:11435")!
    /// Development: `--embedded-ollama` ignores a running Ollama app.
    var forceEmbedded = CommandLine.arguments.contains("--embedded-ollama")

    enum Source { case none, system, embedded }
    private(set) var source: Source = .none
    private var process: Process?
    private var starting: Task<URL?, Never>?

    private init() {
        systemURL = URL(string: UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434")!
    }

    /// The bundle's copy: Contents/Helpers/ollama/ollama.
    static var embeddedBinary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ollama/ollama")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var hasEmbedded: Bool { OllamaRuntime.embeddedBinary != nil }

    /// The models the embedded server keeps, beside the curator's index.
    static var embeddedModelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("iTunes Remote/ollama/models", isDirectory: true)
    }

    /// The address of a working server, starting the embedded one if it must.
    /// Nil when there is neither an Ollama app nor a bundled copy.
    func ensureRunning() async -> URL? {
        if let t = starting { return await t.value }
        let t = Task<URL?, Never> { await self.bringUp() }
        starting = t
        let url = await t.value
        starting = nil
        return url
    }

    /// The last known address without starting anything.
    var currentURL: URL? {
        switch source {
        case .system: return systemURL
        case .embedded: return embeddedURL
        case .none: return nil
        }
    }

    private func bringUp() async -> URL? {
        if !forceEmbedded, await OllamaClient(baseURL: systemURL).isUp() {
            source = .system
            return systemURL
        }
        if source == .embedded, process?.isRunning == true, await OllamaClient(baseURL: embeddedURL).isUp() {
            return embeddedURL
        }
        // Something already on the private port — an earlier copy of this
        // app, say — serves just as well.
        if await OllamaClient(baseURL: embeddedURL).isUp() {
            source = .embedded
            return embeddedURL
        }
        guard let binary = OllamaRuntime.embeddedBinary else {
            source = .none
            return nil
        }
        let models = OllamaRuntime.embeddedModelsDir
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/iTunesRemote")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("ollama.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()

        // Not the server itself but a small shell that runs it, kills it when
        // told, and kills it when this app's pid disappears — a crash or a
        // hard exit would otherwise leave a server listening.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            "$1" serve & pid=$!
            trap 'kill $pid 2>/dev/null; exit 0' TERM INT HUP
            while kill -0 "$2" 2>/dev/null && kill -0 $pid 2>/dev/null; do sleep 1; done
            kill $pid 2>/dev/null
            """, "ollama-watchdog", binary.path, String(ProcessInfo.processInfo.processIdentifier)]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:11435"
        env["OLLAMA_MODELS"] = models.path
        env["OLLAMA_KEEP_ALIVE"] = "15m"
        env["OLLAMA_NOHISTORY"] = "1"
        // Only this app talks to it; no browser origins at all.
        env["OLLAMA_ORIGINS"] = "http://127.0.0.1"
        p.environment = env
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                if self?.process === p { self?.process = nil; self?.source = .none }
            }
        }
        do {
            try p.run()
        } catch {
            OllamaClient.log("embedded ollama failed to start: \(error)")
            source = .none
            return nil
        }
        process = p
        // GPU discovery takes it a few seconds on first launch.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await OllamaClient(baseURL: embeddedURL).isUp() {
                source = .embedded
                OllamaClient.log("embedded ollama up on \(embeddedURL) with models in \(models.path)")
                return embeddedURL
            }
            if !p.isRunning { break }
        }
        OllamaClient.log("embedded ollama did not answer; see ollama.log")
        stop()
        return nil
    }

    /// Stops the child. Called when the app quits; harmless otherwise.
    func stop() {
        guard let p = process else { return }
        process = nil
        if p.isRunning {
            p.terminate()
            // SIGTERM is enough for Ollama; give it a moment, then insist.
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        if source == .embedded { source = .none }
    }

    /// One line for the page: which server, and where.
    var description: String {
        switch source {
        case .system: return "Ollama app"
        case .embedded: return "built-in Ollama"
        case .none: return hasEmbedded ? "built-in Ollama" : "Ollama not found"
        }
    }
}
