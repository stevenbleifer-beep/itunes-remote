import Cocoa

/// Polls the player on the MacBook Pro and sends transport commands. Polls
/// once a second while the app is active, every five seconds otherwise; each
/// poll is one osascript spawn on the old machine, so this is deliberate.
@MainActor
final class PlayerController {
    var api: APIClient?

    /// Where sound comes out: iTunes on the MacBook Pro, or this Mac.
    enum Mode { case remote, local }
    private(set) var mode: Mode = .remote
    let local = LocalPlayer()
    /// Called when a locally played track ends, so the window can advance.
    var onLocalTrackFinished: () -> Void = {}
    /// Fires when iTunes reaches the end of a track on its own. `play <track>`
    /// gives iTunes a one-item queue, so it stops rather than advancing; this
    /// is what lets the app carry on to the next track, and makes shuffle and
    /// repeat mean something in remote mode.
    var onRemoteTrackFinished: () -> Void = {}
    /// Set while the app itself is asking iTunes to stop or pause, so that
    /// deliberate stop is not mistaken for a track ending.
    private var suppressFinish = false
    private var lastRemote: (id: String, position: Double, duration: Double, playing: Bool)?

    private var remoteState: PlayerState?

    /// Shuffle and repeat belong to this app, not to iTunes. The window steps
    /// through its own list in both modes (`play <track>` is a one-item queue
    /// to iTunes 12), so iTunes' own settings are irrelevant to what plays;
    /// they used to be read back from iTunes, which meant they were always
    /// off while playing on this Mac. They are remembered across launches.
    private(set) var shuffle = UserDefaults.standard.bool(forKey: "shuffle")
    private(set) var repeatMode = UserDefaults.standard.string(forKey: "repeatMode") ?? "off"

    /// What the window shows: the live player, with this app's own shuffle
    /// and repeat laid over it whichever machine the sound comes from.
    var state: PlayerState? {
        guard let s = mode == .local ? local.state : remoteState else { return nil }
        return PlayerState(state: s.state, volume: s.volume, position: s.position, track: s.track,
                           playlist: s.playlist, shuffle: shuffle, repeat: repeatMode)
    }
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
        local.onTick = { [weak self] in self?.onChange() }
        local.onFinished = { [weak self] in self?.onLocalTrackFinished() }
        local.onError = { [weak self] message in
            self?.lastError = "Local playback: \(message)"
            self?.onChange()
        }
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
        if mode == .local {
            // No HTTP poll needed; AVFoundation reports its own time.
            if tickCount % 30 == 0 { Task { await refresh() } }   // keep iTunes' state warm
            return
        }
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
            let finished = reachedEnd(s)
            remoteState = s
            lastPoll = Date()
            lastError = nil
            itunesRunning = true
            if finished { onRemoteTrackFinished() }
        } catch let e as APIError where e.status == 503 {
            itunesRunning = false
            lastError = e.message
            remoteState = nil
        } catch {
            lastError = error.localizedDescription
        }
        onChange()
    }

    /// True when iTunes has just run off the end of a track by itself.
    ///
    /// A deliberate stop leaves the position anywhere; a track that played out
    /// leaves it at (or within a couple of seconds of) the duration. That is
    /// the only signal available, since iTunes reports a finished one-item
    /// queue simply as "stopped".
    private func reachedEnd(_ new: PlayerState) -> Bool {
        defer {
            if let t = new.track {
                lastRemote = (t.persistentId, new.position, t.duration, new.isPlaying)
            } else if new.state == "stopped" {
                lastRemote = nil
            }
        }
        guard mode == .remote, new.state == "stopped", new.track == nil,
              let previous = lastRemote, previous.playing, previous.duration > 0 else { return false }
        guard !suppressFinish else {
            suppressFinish = false
            return false
        }
        return previous.position >= previous.duration - 5
    }

    /// Position estimated between polls so the scrubber moves smoothly.
    var displayPosition: Double {
        if mode == .local { return local.position }
        guard let s = state else { return 0 }
        if s.isPlaying {
            return min(s.track?.duration ?? s.position, s.position + Date().timeIntervalSince(lastPoll))
        }
        return s.position
    }

    // MARK: Commands

    /// Anything the window should say out loud rather than swallow.
    var onError: (String) -> Void = { _ in }

    private func command(_ body: @escaping () async throws -> Void) {
        guard api != nil else { return }
        Task {
            do {
                try await body()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                onError(error.localizedDescription)
            }
            await refresh()
        }
    }

    func playPause() {
        if mode == .local { local.playPause(); return }
        guard let api = api else { return }
        suppressFinish = true
        command { try await api.playerCommand("playpause") }
    }

    func stop() {
        if mode == .local { local.stop(); return }
        guard let api = api else { return }
        suppressFinish = true
        command { try await api.playerCommand("stop") }
    }

    /// Plays a track wherever the current mode says. Local needs the Track
    /// itself; remote only needs its id.
    func play(_ track: Track, playlist: String?) {
        if mode == .local, let api = api {
            local.play(track, api: api)
            onChange()
        } else {
            play(track: track.persistentId, playlist: playlist)
        }
    }

    /// Switches output. Entering local mode pauses iTunes on the MacBook Pro
    /// so two things are not playing; leaving it stops local playback.
    func setMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        if new == .local {
            if remoteState?.isPlaying == true, let api = api {
                command { try await api.playerCommand("pause") }
            }
        } else {
            local.stop()
        }
        onOutputsChanged()
        onChange()
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
        if mode == .local { local.seek(to: seconds); return }
        guard let api = api else { return }
        command { try await api.setPosition(seconds) }
    }

    /// Volume changes are coalesced: the slider fires continuously while
    /// dragging, and each set is an osascript spawn.
    func setVolume(_ volume: Int) {
        if mode == .local {
            local.volume = Double(volume) / 100
            onChange()
            return
        }
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
        shuffle = on
        UserDefaults.standard.set(on, forKey: "shuffle")
        onChange()
        // Mirrored to iTunes so its own window agrees; nothing depends on it.
        if let api = api { Task { try? await api.setShuffle(on) } }
    }

    /// off -> all -> one -> off, the order the iTunes button cycled.
    func cycleRepeat() {
        let next: String
        switch repeatMode {
        case "off": next = "all"
        case "all": next = "one"
        default: next = "off"
        }
        repeatMode = next
        UserDefaults.standard.set(next, forKey: "repeatMode")
        onChange()
        if let api = api { Task { try? await api.setRepeat(next) } }
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
                // The switch failed — often because iTunes 12.9.5 cannot
                // AirPlay to a modern Mac. Re-read the real state instead of
                // leaving the menu showing a selection that never happened.
                lastError = error.localizedDescription
                onError("Could not switch output: \(error.localizedDescription)")
                await loadOutputs()
            }
            onOutputsChanged()
            onChange()
        }
    }

    /// Routes everything to one device, the way picking a single speaker did.
    func selectOnly(_ name: String) {
        guard let api = api else { return }
        Task {
            do {
                outputs = try await api.setOutputs([name])
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            onOutputsChanged()
            onChange()
        }
    }

    /// The AirPlay speaker in use, when it is not this machine's own output.
    /// Nil when iTunes is playing through the MacBook Pro itself.
    var selectedOutputName: String? {
        let chosen = outputs.filter { $0.selected && $0.kind.lowercased() != "computer" }
        guard !chosen.isEmpty else { return nil }
        return chosen.count == 1 ? chosen[0].name : "\(chosen.count) speakers"
    }

    var nonComputerOutputSelected: Bool {
        mode == .local || outputs.contains { $0.selected && $0.kind.lowercased() != "computer" }
    }
}
