import Cocoa

/// Polls the player on the MacBook Pro and sends transport commands. Polls
/// once a second while the app is active, every five seconds otherwise; each
/// poll is one osascript spawn on the old machine, so this is deliberate.
@MainActor
final class PlayerController {
    /// `--trace-queue`: every decision about what plays next, printed. The
    /// queue is the one part of this app that cannot be checked from a
    /// screenshot — two songs apart, both plausible — so it says what it did.
    static let traceQueue = CommandLine.arguments.contains("--trace-queue")
    static func trace(_ message: @autoclosure () -> String) {
        guard traceQueue else { return }
        print("queue: \(message())")
        fflush(stdout)
    }

    var api: APIClient? {
        didSet { if api != nil { keepITunesNeutral() } }
    }

    /// Where sound comes out: iTunes on the MacBook Pro, or this Mac.
    enum Mode { case remote, local }
    private(set) var mode: Mode = .remote
    let local = LocalPlayer()
    /// Called when a locally played track ends, so the window can advance.
    var onLocalTrackFinished: () -> Void = {}
    /// Fires when the song playing on the MacBook Pro is over, so the window
    /// can play whatever its own list says comes next.
    ///
    /// It does *not* wait for iTunes to stop. `play <track>` resolves the
    /// track through `library playlist 1`, which makes the whole library
    /// iTunes' current playlist: the moment a song ends iTunes carries on
    /// through the library by itself, and a song nobody asked for played
    /// until the next poll took the step back — a second with the app in
    /// front, five with it in the background, which is what "it plays a
    /// random song for a bit" was. So the app gets in first: it knows when
    /// the song ends and steps a fraction of a second early, and the stop
    /// and takeover checks below are only the net beneath that.
    var onRemoteTrackFinished: () -> Void = {}
    /// Set while the app itself is asking iTunes to stop or pause, so that
    /// deliberate stop is not mistaken for a track ending.
    private var suppressFinish = false
    private var lastRemote: (id: String, position: Double, duration: Double, playing: Bool)?

    /// How far before the end of a song the next one is started, to beat
    /// iTunes to its own advance through the library. The last fraction of a
    /// second of a track is silence on nearly everything; a stranger's song
    /// was not.
    ///
    /// It is the round trip of the app's own last `play` — a tenth of a
    /// second of HTTP and three of iTunes finding the track by persistent ID
    /// in a 93,000-track library, or much more over the Tailscale tunnel —
    /// plus a margin. Aimed at 0.4 s flat, iTunes got its own song in first
    /// by a hair: the command was issued in time and landed just late.
    private var endLead: Double { min(3, max(0.4, lastPlayLatency + 0.3)) }
    private var lastPlayLatency = 0.9
    private var endTimer: Timer?
    private var endArmedFor: String?
    /// The track the app has already stepped away from, so that a late poll
    /// (or iTunes stopping afterwards) cannot step a second time and skip a
    /// song. Cleared whenever the app asks for a track, so Repeat One can
    /// play the same song again.
    private var finishedTrack: String?

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

    // MARK: Sync progress

    /// The daemon's current write, for the LCD. Read once a second while a
    /// rebuild or an iPod sync is running and for a few seconds after, and
    /// every ten seconds otherwise so a sync started elsewhere still shows.
    private(set) var syncProgress: SyncProgress?
    var onSyncProgress: (SyncProgress) -> Void = { _ in }
    private var watchingSync = false
    private var syncIdleSince: Date?
    private var progressInFlight = false

    /// Called when Apply or Sync is pressed: start looking straight away.
    func watchSync() {
        watchingSync = true
        syncIdleSince = nil
        Task { await pollSyncProgress() }
    }

    private func pollSyncProgress() async {
        guard let api = api, !progressInFlight else { return }
        progressInFlight = true
        defer { progressInFlight = false }
        guard let p = try? await api.syncProgress() else { return }
        let was = syncProgress
        syncProgress = p
        if p.active {
            watchingSync = true
            syncIdleSince = nil
        } else if watchingSync {
            if syncIdleSince == nil { syncIdleSince = Date() }
            if Date().timeIntervalSince(syncIdleSince!) > 5 { watchingSync = false }
        }
        if p != was { onSyncProgress(p) }
    }

    private var tickCount = 0

    /// Away from the LAN every poll crosses the tunnel, so the player is
    /// read every three seconds instead of every one. The display clock
    /// still advances between polls.
    var away = false

    private func tick() {
        tickCount += 1
        // A sync iTunes starts on its own (the iPod plugged in) is found by
        // the daemon's sensor; asking every five seconds puts it on the LCD
        // soon enough.
        if watchingSync || tickCount % 5 == 0 {
            Task { await pollSyncProgress() }
        }
        // Out of the way of the handoff: the daemon runs one AppleScript at a
        // time, so a poll started now would be in front of the play command
        // that has to land before the song ends.
        if let fire = endTimer?.fireDate, fire.timeIntervalSinceNow < 1.5 {
            onChange()
            return
        }
        // In the last seconds of a song the reading has to be fresh: the
        // step is aimed from it, and aiming from a five-second-old position
        // is how you end up hearing iTunes' idea of what comes next.
        let ending = nearEndOfTrack
        if away && mode == .remote && !ending && tickCount % 3 != 0 {
            onChange()
            return
        }
        if mode == .local {
            // No HTTP poll needed; AVFoundation reports its own time.
            if tickCount % 30 == 0 { Task { await refresh() } }   // keep iTunes' state warm
            return
        }
        if !NSApp.isActive && !ending && tickCount % 5 != 0 {
            onChange()   // still advance the local clock for the display
            return
        }
        Task { await refresh() }
    }

    /// Within a few seconds of the end of the song on the MacBook Pro.
    private var nearEndOfTrack: Bool {
        guard mode == .remote, let s = remoteState, s.isPlaying,
              let d = s.track?.duration, d > 0 else { return false }
        return d - displayPosition < 8
    }

    func refresh() async {
        guard let api = api, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let s = try await api.playerState()
            // iTunes moved on by itself: it was playing our song, and now it
            // is playing another one we never asked for. Treat our song as
            // finished and let the window choose what follows.
            // The play never took: iTunes is on something else seconds after
            // being asked. Ask again rather than leaving its choice playing.
            if let expected = expectedTrack, let now = s.track?.persistentId, now != expected, s.isPlaying,
               let since = pendingSince, Date().timeIntervalSince(since) < 8, pendingRetries < 3 {
                pendingRetries += 1
                Self.trace("iTunes is on \(s.track?.name ?? now), not what was asked for — asking again (\(pendingRetries))")
                remoteState = s
                lastPoll = Date()
                lastRemote = (now, s.position, s.track?.duration ?? 0, true)
                sendPendingPlay()
                onChange()
                return
            }
            if let expected = expectedTrack, let now = s.track?.persistentId, now != expected, s.isPlaying,
               lastRemote?.id == expected {
                expectedTrack = nil
                remoteState = s
                lastPoll = Date()
                lastRemote = (now, s.position, s.track?.duration ?? 0, true)
                onChange()
                onRemoteTrackFinished()
                return
            }
            // It landed.
            if s.track?.persistentId == expectedTrack, s.isPlaying {
                pendingPlay = nil
                pendingSince = nil
            }
            if s.track?.persistentId == expectedTrack, s.state == "stopped" { expectedTrack = nil }
            let finished = reachedEnd(s)
            // Playing again means the stop the flag was waiting for never
            // came (play/pause pressed to resume): let it go, or the next
            // real end of a track would be swallowed and nothing would follow.
            if s.isPlaying { suppressFinish = false }
            remoteState = s
            lastPoll = Date()
            lastError = nil
            itunesRunning = true
            armEndOfTrack(s)
            if finished, s.track?.persistentId != finishedTrack { onRemoteTrackFinished() }
        } catch let e as APIError where e.status == 503 {
            itunesRunning = false
            lastError = e.message
            remoteState = nil
            disarmEndOfTrack()
        } catch {
            lastError = error.localizedDescription
        }
        onChange()
    }

    /// Aims the end-of-track timer at the song now playing. Every poll
    /// re-aims it, so a seek, a pause or a song started at the Pro itself
    /// moves it too. The timer runs on real time from the last poll, which
    /// is why this still works while the app sits in the background polling
    /// once every five seconds.
    private func armEndOfTrack(_ s: PlayerState) {
        // Only for a song this app started. If someone put something on at
        // the MacBook Pro itself, iTunes' queue is theirs and the app has no
        // business stepping out of it.
        guard mode == .remote, s.isPlaying, let t = s.track, t.duration > 0,
              t.persistentId == lastOwnTrack, t.persistentId != finishedTrack else {
            disarmEndOfTrack()
            return
        }
        endTimer?.invalidate()
        endArmedFor = t.persistentId
        let fire = max(t.duration - s.position - endLead, 0.05)
        endTimer = Timer.scheduledTimer(withTimeInterval: fire, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endOfTrackReached() }
        }
        Self.trace(String(format: "armed for %@ in %.2fs (at %.2f of %.2f, lead %.2f)", t.name, fire, s.position, t.duration, endLead))
    }

    private func disarmEndOfTrack() {
        endTimer?.invalidate()
        endTimer = nil
        endArmedFor = nil
    }

    private func endOfTrackReached() {
        guard mode == .remote, let id = endArmedFor, id != finishedTrack,
              remoteState?.isPlaying == true else { return }
        disarmEndOfTrack()
        finishedTrack = id
        Self.trace("end of track reached for \(remoteState?.track?.name ?? id)")
        onRemoteTrackFinished()
    }

    /// Nothing follows in the window's list, so iTunes has to be stopped
    /// before it wanders off into the library on its own.
    func stopAfterList() {
        guard mode == .remote, let api = api else { return }
        Self.trace("nothing follows in the list — stopping iTunes")
        suppressFinish = true
        command { try await api.playerCommand("stop") }
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
              let previous = lastRemote, previous.playing, previous.duration > 0,
              previous.id != finishedTrack else { return false }
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
        // Only a pause is a deliberate stop; resuming is not.
        if remoteState?.isPlaying == true { suppressFinish = true }
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
    /// The song this app last asked for. When a poll shows iTunes playing
    /// something else that nobody here asked for, iTunes has advanced on
    /// its own — its queue, its shuffle — and the app takes the step back.
    private(set) var lastOwnTrack: String?
    private var expectedTrack: String?

    /// Takes over a song that was already playing — iTunes was left running
    /// when the app was closed, say. From here the app owns the queue: the
    /// end-of-track handoff arms for this song like any it started itself.
    func adopt(_ id: String) {
        Self.trace("adopted \(remoteState?.track?.name ?? id)")
        lastOwnTrack = id
        expectedTrack = id
        finishedTrack = nil
    }

    func play(_ track: Track, playlist: String?) {
        lastOwnTrack = track.persistentId
        expectedTrack = track.persistentId
        finishedTrack = nil
        disarmEndOfTrack()
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
            // Every switch to this Mac starts at full volume.
            local.volume = 1
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
        guard api != nil else { return }
        pendingPlay = (track, playlist)
        pendingSince = Date()
        pendingRetries = 0
        sendPendingPlay()
    }

    /// The song asked for, until iTunes is seen playing it. A handoff at the
    /// end of a track can miss: the daemon runs one AppleScript at a time, so
    /// a play can queue behind a library fetch long enough for iTunes to get
    /// its own next song in — and, before this, nothing asked again, so
    /// iTunes' choice simply played on.
    private var pendingPlay: (track: String, playlist: String?)?
    private var pendingSince: Date?
    private var pendingRetries = 0

    private func sendPendingPlay() {
        guard let api = api, let p = pendingPlay else { return }
        let asked = Date()
        command { [weak self] in
            try await api.play(track: p.track, playlist: p.playlist)
            // What it costs to put a song on is what the next handoff has to
            // be aimed ahead by.
            self?.lastPlayLatency = Date().timeIntervalSince(asked)
        }
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
        // Not mirrored to iTunes any more: with its own shuffle on, iTunes
        // followed a one-item queue with random songs of its own. Its
        // shuffle and repeat stay off; this app is the queue.
        keepITunesNeutral()
    }

    /// iTunes' own shuffle and repeat off, so a one-item queue ends when the
    /// song does and the app decides what follows.
    private func keepITunesNeutral() {
        guard let api = api else { return }
        Task {
            try? await api.setShuffle(false)
            try? await api.setRepeat("off")
        }
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
        keepITunesNeutral()
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
