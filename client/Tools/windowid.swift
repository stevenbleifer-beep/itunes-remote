import CoreGraphics
import Foundation

// Prints "windowNumber x y width height title" for on-screen windows owned by
// the named process (default: iTunesRemote). Used with `screencapture -l`.
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "iTunesRemote"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == name {
    guard let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    if layer != 0 && layer != 3 { continue }   // normal and floating windows
    print("\(id) \(b["X"] ?? 0) \(b["Y"] ?? 0) \(b["Width"] ?? 0) \(b["Height"] ?? 0) \(w[kCGWindowName as String] as? String ?? "")")
}
