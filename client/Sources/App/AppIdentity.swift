import Foundation

/// Which of the two apps this build is. The same source builds both:
/// "iTunes Remote" drives iTunes on another Mac, "Apple Music Remote"
/// drives Music.app on this one. `build.sh` sets the bundle name, bundle
/// identifier and the `ITRVariant` key, and everything that must differ
/// between the two — titles, the Application Support folder, the log
/// folder, the keychain item, which daemons the setup lists — reads it
/// from here, so the two never share settings or a curator index.
enum AppIdentity {
    static let name: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "iTunes Remote"
    static let bundleId: String = Bundle.main.bundleIdentifier ?? "local.stevenbleifer.itunesremote"
    static let isAppleMusic: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "ITRVariant") as? String) == "music"
    /// The daemon backend this app is for; the setup assistant lists only those.
    static var backend: String { isAppleMusic || ServerSettings.isMusicProfile ? "Music" : "iTunes" }
    /// ~/Library/Application Support/<supportFolder>/… — curator index, memory, training.
    /// The Apple Music library inside iTunes Remote keeps its curator index,
    /// lessons and training in a folder of its own, beside the iTunes one.
    static var supportFolder: String { !isAppleMusic && ServerSettings.isMusicProfile ? name + "/Apple Music" : name }
    /// ~/Library/Logs/<logFolder>/
    static var logFolder: String { isAppleMusic ? "AppleMusicRemote" : "iTunesRemote" }
}
