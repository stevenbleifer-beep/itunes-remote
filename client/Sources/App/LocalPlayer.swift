import AVFoundation
import Cocoa

/// Plays a track on this Mac's own output by streaming its file from the
/// daemon. iTunes 12.9.5 cannot AirPlay to a modern Mac (error -15022), so
/// "Play on This Mac" bypasses AirPlay entirely: the file comes over HTTP
/// with range requests, and AVFoundation decodes it here.
@MainActor
final class LocalPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let player = AVPlayer()
    private(set) var current: Track?
    /// The song a stream is carrying, from its ICY metadata.
    private(set) var streamTitle: String?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// The item whose status is being watched, so the observer comes off
    /// before the item is replaced: an observed item deallocated with its
    /// observer still on crashes.
    private var observedItem: AVPlayerItem?

    var onTick: () -> Void = {}
    var onFinished: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        // Full, as Steven wants it whenever sound switches to this Mac; the
        // slider then works down from there.
        player.volume = 1.0
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

    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                                    from track: AVPlayerItemTrack?) {
        var title: String?
        for g in groups {
            for item in g.items {
                let id = item.identifier
                if id == .icyMetadataStreamTitle || id == .commonIdentifierTitle || id == .id3MetadataTitleDescription,
                   let v = item.value as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = v.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard let t = title else { return }
        Task { @MainActor in
            if self.streamTitle != t { self.streamTitle = t; self.onTick() }
        }
    }

    func play(_ track: Track, api: APIClient) {
        current = track
        streamTitle = nil
        let asset = AVURLAsset(url: api.audioURL(for: track.persistentId), options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(api.token)"],
        ])
        let item = AVPlayerItem(asset: asset)
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFinished() }
        }
        stopObserving()
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        observedItem = item
        player.replaceCurrentItem(with: item)
        player.play()
        onTick()
    }

    /// A live stream on this Mac's speakers. The "track" shown is the
    /// station: AVFoundation reports no duration for a live stream, so the
    /// display shows the time listened and nothing to count down.
    func playStream(_ station: RadioStation) {
        guard let url = URL(string: station.url) else {
            onError("the station's address is not a URL")
            return
        }
        current = Track(persistentId: "radio:" + station.uuid, name: station.name, artist: station.place,
                        album: "Internet Radio", albumArtist: "", genre: station.tagLine, year: nil,
                        trackNumber: nil, discNumber: nil, totalTime: nil, size: nil, compilation: false)
        let item = AVPlayerItem(url: url)
        streamTitle = nil
        // Icecast/Shoutcast streams carry "Artist - Title" between the
        // frames; HLS carries ID3 timed metadata. Both land here.
        let meta = AVPlayerItemMetadataOutput(identifiers: nil)
        meta.setDelegate(self, queue: .main)
        item.add(meta)
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onFinished() }
        }
        stopObserving()
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        observedItem = item
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
        Task { @MainActor in if self.observedItem === item { self.stopObserving() } }
    }

    private func stopObserving() {
        guard let item = observedItem else { return }
        item.removeObserver(self, forKeyPath: "status")
        observedItem = nil
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
        stopObserving()
        player.replaceCurrentItem(with: nil)
        current = nil
        streamTitle = nil
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
                        album: $0.album, duration: duration, streamTitle: streamTitle)
        }
        return PlayerState(state: s, volume: Int((volume * 100).rounded()), position: position,
                           track: track, playlist: nil, shuffle: false, repeat: "off")
    }
}
