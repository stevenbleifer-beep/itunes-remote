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


/// The keyboard's own volume keys (and, while it is playing there, the
/// play/pause and track keys) for iTunes on the other Mac.
///
/// The system never sends volume keys to an app: they set *this* Mac's
/// volume, which is silent while the sound is coming out of the MacBook
/// Pro. So while iTunes over there is playing, the app takes the keys
/// itself, before the system does, with an event tap on the hardware key
/// events, and turns them into iTunes' volume. When it is not playing there
/// the keys pass straight through and do what they always did.
///
/// A tap that swallows events needs the Accessibility permission (System
/// Settings ▸ Privacy & Security ▸ Accessibility). Signed with the Team ID,
/// the grant survives rebuilds; ad-hoc builds lose it every time.
final class MediaKeyTap {
    /// NX_KEYTYPE_* values carried in the event.
    enum Key: Int { case soundUp = 0, soundDown = 1, mute = 7, play = 16, next = 17, previous = 18 }

    /// Asked on every key: true means the app takes it.
    var shouldHandle: () -> Bool = { false }
    /// A key that was taken, on key down, on the main thread.
    var onKey: (Key) -> Void = { _ in }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { port != nil }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Puts up the system's "would like to control this computer" dialog,
    /// which sends the user to the Accessibility list.
    static func askForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Starts listening. False when the system refused, which means the
    /// permission is missing.
    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        let systemDefined: CGEventType = CGEventType(rawValue: 14)!   // NX_SYSDEFINED
        let mask = CGEventMask(1 << systemDefined.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, refcon in
                                            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                                            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                                            return tap.handle(type: type, event: event)
                                        }, userInfo: me) else {
            NSLog("media key tap: could not be created (Accessibility permission missing?)")
            return false
        }
        port = p
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, p, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        NSLog("media key tap: listening")
        return true
    }

    func stop() {
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let p = port { CGEvent.tapEnable(tap: p, enable: false) }
        source = nil
        port = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system switches a slow tap off; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)   // not an aux-control key
        }
        let data = ns.data1
        let code = (data & 0xFFFF0000) >> 16
        let flags = data & 0xFFFF
        let down = ((flags & 0xFF00) >> 8) == 0xA
        guard let key = Key(rawValue: code), shouldHandle() else { return Unmanaged.passUnretained(event) }
        if down { onKey(key) }
        return nil   // taken: the system's own volume and Now Playing never see it
    }
}
