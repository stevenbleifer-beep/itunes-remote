import Cocoa
import MediaPlayer

/// Makes the Mac's media keys (and the Now Playing control in the menu bar
/// and Control Centre) drive this app.
///
/// There is no way to have the keys reach iTunes on the other machine — they
/// are delivered to whichever app on *this* Mac is the current "now playing"
/// app. So the app registers as that app: it publishes what is playing through
/// MPNowPlayingInfoCenter, which is what makes it eligible, and takes the key
/// presses through MPRemoteCommandCenter, forwarding them to whichever player
/// is live (iTunes over the daemon, or this Mac's own AVFoundation player).
@MainActor
final class MediaKeys {
    var onTogglePlayPause: () -> Void = {}
    var onPlay: () -> Void = {}
    var onPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }

    private var wired = false

    func start() {
        guard !wired else { return }
        wired = true
        let centre = MPRemoteCommandCenter.shared()
        // Logged, so "the keys do nothing" can be told apart from "the keys
        // never reached the app": `log stream --predicate 'process == "iTunesRemote"'`.
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            NSLog("media key: play/pause"); self?.onTogglePlayPause(); return .success
        }
        centre.playCommand.addTarget { [weak self] _ in NSLog("media key: play"); self?.onPlay(); return .success }
        centre.pauseCommand.addTarget { [weak self] _ in NSLog("media key: pause"); self?.onPause(); return .success }
        centre.nextTrackCommand.addTarget { [weak self] _ in NSLog("media key: next"); self?.onNext(); return .success }
        centre.previousTrackCommand.addTarget { [weak self] _ in NSLog("media key: previous"); self?.onPrevious(); return .success }
        centre.changePlaybackPositionCommand.isEnabled = true
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek(e.positionTime)
            return .success
        }
        for command in [centre.togglePlayPauseCommand, centre.playCommand, centre.pauseCommand,
                        centre.nextTrackCommand, centre.previousTrackCommand] {
            command.isEnabled = true
        }
    }

    /// Publishes what is playing. Being the app that does this is what earns
    /// the media keys, so it is kept current even when paused.
    func publish(title: String?, artist: String?, album: String?,
                 duration: Double?, elapsed: Double, playing: Bool, stopped: Bool) {
        let centre = MPNowPlayingInfoCenter.default()
        guard !stopped, let title = title else {
            centre.nowPlayingInfo = nil
            centre.playbackState = .stopped
            return
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let artist = artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        centre.nowPlayingInfo = info
        centre.playbackState = playing ? .playing : .paused
    }
}
