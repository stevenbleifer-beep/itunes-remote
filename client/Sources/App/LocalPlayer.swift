import AVFoundation
import Cocoa

/// Plays a track on this Mac's own output by streaming its file from the
/// daemon. iTunes 12.9.5 cannot AirPlay to a modern Mac (error -15022), so
/// "Play on This Mac" bypasses AirPlay entirely: the file comes over HTTP
/// with range requests, and AVFoundation decodes it here.
@MainActor
final class LocalPlayer: NSObject {
    private let player = AVPlayer()
    private(set) var current: Track?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    var onTick: () -> Void = {}
    var onFinished: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        player.volume = 0.75
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    var isPlaying: Bool { player.rate > 0 && player.error == nil }
    var position: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }
    var duration: Double {
        if let d = player.currentItem?.duration.seconds, d.isFinite { return d }
        return Double(current?.totalTime ?? 0) / 1000
    }
    var volume: Double {
        get { Double(player.volume) }
        set { player.volume = Float(min(1, max(0, newValue))) }
    }

    func play(_ track: Track, api: APIClient) {
        current = track
        let asset = AVURLAsset(url: api.audioURL(for: track.persistentId), options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(api.token)"],
        ])
        let item = AVPlayerItem(asset: asset)
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFinished() }
        }
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        player.replaceCurrentItem(with: item)
        player.play()
        onTick()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "status", let item = object as? AVPlayerItem else { return }
        if item.status == .failed {
            let message = item.error?.localizedDescription ?? "could not play this file"
            Task { @MainActor in self.onError(message) }
        }
        item.removeObserver(self, forKeyPath: "status")
    }

    func playPause() {
        guard player.currentItem != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        onTick()
    }

    func pause() {
        player.pause()
        onTick()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        onTick()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        onTick()
    }

    /// The same shape the daemon reports, so the window code needs no branches.
    var state: PlayerState {
        let s = current == nil ? "stopped" : (isPlaying ? "playing" : "paused")
        let track = current.map {
            PlayerTrack(persistentId: $0.persistentId, name: $0.name, artist: $0.artist,
                        album: $0.album, duration: duration)
        }
        return PlayerState(state: s, volume: Int((volume * 100).rounded()), position: position,
                           track: track, playlist: nil, shuffle: false, repeat: "off")
    }
}
