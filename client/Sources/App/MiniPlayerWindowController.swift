import Cocoa

/// The iTunes mini player: a short gray bar with the transport buttons, the
/// volume slider, and the green display. Shares the main window's
/// PlayerController; the main window forwards state updates here.
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate {
    private let player: PlayerController
    private let previousButton = AquaRoundButton(glyph: .previous, diameter: 24)
    private let playButton = AquaRoundButton(glyph: .play, diameter: 32)
    private let nextButton = AquaRoundButton(glyph: .next, diameter: 24)
    private let volumeSlider = AquaVolumeSlider()
    private let airPlayButton = AquaAirPlayButton()
    private let display = AquaDisplayPanel()

    /// The main window owns the AirPlay menu; the mini player asks for it.
    var onAirPlay: (NSView) -> Void = { _ in }

    /// Called when the mini player closes, so the main window comes back.
    var onRestore: () -> Void = {}
    /// Called for previous / next so list-based stepping stays in one place.
    var onStep: (Int) -> Void = { _ in }

    init(player: PlayerController) {
        self.player = player
        let width: CGFloat = 520, height: CGFloat = 72
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = AppIdentity.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.appearance = Theme.appearance
        window.delegate = self
        window.setFrameAutosaveName("MiniPlayer")

        let content = ChromeView(frame: window.contentView!.bounds)
        content.bottomLine = true
        window.contentView = content

        let midY: CGFloat = height / 2 - 2
        var x: CGFloat = 78   // clear of the traffic lights
        for (button, action) in [(previousButton, #selector(previous(_:))),
                                 (playButton, #selector(togglePlay(_:))),
                                 (nextButton, #selector(next(_:)))] {
            let s = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: round(midY - s.height / 2), width: s.width, height: s.height)
            button.target = self
            button.action = action
            content.addSubview(button)
            x += s.width + 2
        }
        volumeSlider.frame = NSRect(x: x + 10, y: round(midY - 9), width: 96, height: 18)
        volumeSlider.onChange = { [weak self] v in self?.player.setVolume(Int((v * 100).rounded())) }
        content.addSubview(volumeSlider)

        let ap = airPlayButton.intrinsicContentSize
        airPlayButton.frame = NSRect(x: volumeSlider.frame.maxX + 8, y: round(midY - ap.height / 2), width: ap.width, height: ap.height)
        airPlayButton.onClick = { [weak self] sender in self?.onAirPlay(sender) }
        content.addSubview(airPlayButton)

        let dx = airPlayButton.frame.maxX + 10
        display.frame = NSRect(x: dx, y: round(midY - 22), width: width - dx - 12, height: 44)
        display.onSeek = { [weak self] s in self?.player.seek(to: s) }
        content.addSubview(display)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func togglePlay(_ sender: Any?) { player.playPause() }
    @objc private func previous(_ sender: Any?) { onStep(-1) }
    @objc private func next(_ sender: Any?) { onStep(1) }

    /// Mirrors the main window's display logic for the smaller panel.
    func update() {
        let state = player.state
        let playing = state?.isPlaying ?? false
        playButton.glyph = playing ? .pause : .play
        display.isPlaying = playing
        display.airPlayActive = player.nonComputerOutputSelected
        if let t = state?.track, state?.state != "stopped" {
            display.duration = t.duration
            display.position = player.displayPosition
            display.primary = t.name
            var parts = [t.artist, t.album].filter { !$0.isEmpty }
            if player.mode == .local { parts.append("on this Mac") }
            else if let out = player.selectedOutputName { parts.append("on \(out)") }
            display.secondary = parts.joined(separator: " — ")
        } else {
            display.duration = nil
            display.primary = AppIdentity.name
            display.secondary = player.itunesRunning ? "Nothing playing" : (player.lastError ?? "")
        }
        if let v = state?.volume, !volumeSlider.isDragging {
            volumeSlider.value = Double(v) / 100
        }
        let up = player.itunesRunning || player.mode == .local
        for b in [previousButton, playButton, nextButton] { b.isEnabled = up }
        airPlayButton.isActive = player.nonComputerOutputSelected
        airPlayButton.isEnabled = player.itunesRunning
    }

    func windowWillClose(_ notification: Notification) {
        onRestore()
    }

    @objc func toggleMiniPlayer(_ sender: Any?) {
        close()
    }

    /// The Window menu item shows a tick while the mini player is up, so it
    /// reads as the switch it is: choose it again to get the window back.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMiniPlayer(_:)) { item.state = .on }
        return true
    }
}
