import Foundation

/// Runs the bundled finetune.sh as a child of the app, streaming its lines
/// to whoever is watching. One run at a time; it outlives the training
/// window, so closing that leaves the training going.
@MainActor
final class CuratorTrainer {
    static let shared = CuratorTrainer()

    struct Status {
        var examples = 0
        var minimum = 40
        var python: String?     // a Python 3.10+ the script can use, if any
        var tuned = ""          // the picker the app is set to
        var stock = ""          // the stock picker
        var hasTuned: Bool { !tuned.isEmpty && tuned != stock }
    }

    /// Contents/Resources/finetune.sh, copied in by build.sh.
    static var script: URL? { Bundle.main.url(forResource: "finetune", withExtension: "sh") }

    private(set) var process: Process?
    var isRunning: Bool { process?.isRunning == true }
    /// The lines of the run in progress (or the last one), for a window
    /// opened after it started.
    private(set) var lines: [String] = []
    var onLine: (String) -> Void = { _ in }
    var onExit: (Int32) -> Void = { _ in }

    private init() {}

    /// The environment the script needs: a PATH that reaches ollama, uv
    /// and curl, and the embedded Ollama when that is what the app uses.
    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["ITR_PROGRESS"] = "1"
        env["ITR_NO_SWITCH"] = "1"   // the app switches the picker itself
        let rt = OllamaRuntime.shared
        if rt.source == .embedded, let bin = OllamaRuntime.embeddedBinary {
            env["ITR_OLLAMA"] = bin.path
            env["OLLAMA_HOST"] = "127.0.0.1:11435"
            env["OLLAMA_MODELS"] = OllamaRuntime.embeddedModelsDir.path
        }
        return env
    }

    /// What is on file and what is installed; nothing is changed.
    func check() async -> Status {
        guard let script = CuratorTrainer.script else { return Status() }
        let env = environment()
        let text: String = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--check"]
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
        var s = Status()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "examples": s.examples = Int(parts[1]) ?? 0
            case "minimum": s.minimum = Int(parts[1]) ?? 40
            case "python": s.python = parts[1] == "none" ? nil : parts[1]
            case "tuned": s.tuned = parts[1]
            case "stock": s.stock = parts[1]
            default: break
            }
        }
        // The app's own setting wins over what `defaults` reported.
        if let m = UserDefaults.standard.string(forKey: "curatorModel") { s.tuned = m }
        return s
    }

    /// Starts the script with these options. Lines arrive on the main
    /// thread, ANSI bold stripped, progress-bar carriage returns split.
    func start(_ args: [String]) -> Bool {
        guard !isRunning, let script = CuratorTrainer.script else { return false }
        lines = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        p.environment = environment()
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        // Read on the pipe's own thread; only whole lines cross to the main actor.
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            let out = buffer.take(chunk)
            guard !out.isEmpty else { return }
            Task { @MainActor in
                for l in out {
                    self?.lines.append(l)
                    if (self?.lines.count ?? 0) > 400 { self?.lines.removeFirst() }
                    self?.onLine(l)
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let tail = buffer.flush(rest)
            let code = proc.terminationStatus
            Task { @MainActor in
                if !tail.isEmpty { self?.lines.append(tail); self?.onLine(tail) }
                if self?.process === proc { self?.process = nil }
                OllamaClient.log("finetune.sh \(args.joined(separator: " ")) exited \(code)")
                self?.onExit(code)
            }
        }
        do {
            try p.run()
        } catch {
            OllamaClient.log("finetune.sh failed to start: \(error)")
            return false
        }
        process = p
        OllamaClient.log("finetune.sh \(args.joined(separator: " ")) started, pid \(p.processIdentifier)")
        return true
    }

    /// Stops the run: the script's trap passes the signal to whatever
    /// step it is on, so the trainer does not run on without it.
    func cancel() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Escape codes and progress-bar clutter out; text in.
    nonisolated static func strip(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1B}\\[\\?[0-9]+[hl]", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Bytes from the pipe, cut into lines at newline or carriage return.
/// Used from the pipe's reader thread only; the lock is for the flush at exit.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func take(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var out: [String] = []
        while let i = data.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(data: data[data.startIndex..<i], encoding: .utf8) ?? ""
            data.removeSubrange(data.startIndex...i)
            let clean = CuratorTrainer.strip(line)
            if !clean.isEmpty { out.append(clean) }
        }
        return out
    }

    func flush(_ rest: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        data.append(rest)
        let s = CuratorTrainer.strip(String(data: data, encoding: .utf8) ?? "")
        data = Data()
        return s
    }
}
