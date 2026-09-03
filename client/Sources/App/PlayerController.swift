import Cocoa

/// Polls the player on the MacBook Pro and sends transport commands. Polls
/// once a second while the app is active, every five seconds otherwise; each
/// poll is one osascript spawn on the old machine, so this is deliberate.
@MainActor
final class PlayerController {
    var api: APIClient?

    private(set) var state: PlayerState?
    private(set) var outputs: [Output] = []
    private(set) var lastError: String?
    private(set) var itunesRunning = true

    var onChange: () -> Void = {}
    var onOutputsChanged: () -> Void = {}

    private var timer: Timer?
    private var inFlight = false
    private var lastPoll = Date()
    private var pendingVolume: Int?
    private var volumeTimer: Timer?

    // MARK: Polling

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await refresh() }
        Task { await loadOutputs() }
    }

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        if !NSApp.isActive && tickCount % 5 != 0 {
            onChange()   // still advance the local clock for the display
            return
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let api = api, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let s = try await api.playerState()
            state = s
            lastPoll = Date()
            lastError = nil
            itunesRunning = true
        } catch let e as APIError where e.status == 503 {
            itunesRunning = false
            lastError = e.message
            state = nil
        } catch {
            lastError = error.localizedDescription
        }
        onChange()
    }

    /// Position estimated between polls so the scrubber moves smoothly.
    var displayPosition: Double {
        guard let s = state else { return 0 }
        if s.isPlaying {
            return min(s.track?.duration ?? s.position, s.position + Date().timeIntervalSince(lastPoll))
        }
        return s.position
    }

    // MARK: Commands

    private func command(_ body: @escaping () async throws -> Void) {
        guard api != nil else { return }
        Task {
            do {
                try await body()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            await refresh()
        }
    }

    func playPause() {
        guard let api = api else { return }
        command { try await api.playerCommand("playpause") }
    }

    func next() {
        guard let api = api else { return }
        command { try await api.playerCommand("next") }
    }

    func previous() {
        guard let api = api else { return }
        command { try await api.playerCommand("previous") }
    }

    func play(track: String, playlist: String?) {
        guard let api = api else { return }
        command { try await api.play(track: track, playlist: playlist) }
    }

    func seek(to seconds: Double) {
        guard let api = api else { return }
        command { try await api.setPosition(seconds) }
    }

    /// Volume changes are coalesced: the slider fires continuously while
    /// dragging, and each set is an osascript spawn.
    func setVolume(_ volume: Int) {
        pendingVolume = volume
        volumeTimer?.invalidate()
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let api = self.api, let v = self.pendingVolume else { return }
                self.pendingVolume = nil
                self.command { try await api.setVolume(v) }
            }
        }
    }

    func setShuffle(_ on: Bool) {
        guard let api = api else { return }
        command { try await api.setShuffle(on) }
    }

    /// off -> all -> one -> off, the order the iTunes button cycled.
    func cycleRepeat() {
        guard let api = api else { return }
        let next: String
        switch state?.repeatMode ?? "off" {
        case "off": next = "all"
        case "all": next = "one"
        default: next = "off"
        }
        command { try await api.setRepeat(next) }
    }

    func launchITunes() {
        guard let api = api else { return }
        command { try await api.launchITunes() }
    }

    // MARK: Outputs

    func loadOutputs() async {
        guard let api = api else { return }
        do {
            outputs = try await api.outputs()
            onOutputsChanged()
        } catch {
            lastError = error.localizedDescription
            onChange()
        }
    }

    /// Toggles one device in the current set. Choosing Computer alone resets
    /// to the local output; an empty set falls back to Computer.
    func toggleOutput(_ name: String) {
        guard let api = api else { return }
        var selected = Set(outputs.filter { $0.selected }.map { $0.name })
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
        }
        if selected.isEmpty { selected = ["Computer"] }
        let names = outputs.map { $0.name }.filter { selected.contains($0) }
        Task {
            do {
                outputs = try await api.setOutputs(names)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            onOutputsChanged()
            onChange()
        }
    }

    var nonComputerOutputSelected: Bool {
        outputs.contains { $0.selected && $0.kind.lowercased() != "computer" }
    }
}
