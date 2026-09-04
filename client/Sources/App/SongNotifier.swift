import Cocoa
import UserNotifications

/// A notification when the song changes and the window is out of sight:
/// the app in the background, the window hidden or minimised, or the mini
/// player up. Title, artist and album, with the cover beside them.
///
/// Off and on from Controls ▸ Notify on Song Change. The first notification
/// asks the system for permission; a refusal there simply keeps them off.
@MainActor
final class SongNotifier {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "songNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "songNotifications") }
    }

    private var lastId: String?
    private var permission: Bool?
    private var asking = false

    /// Called on every player update; only a change of song does anything.
    func songChanged(id: String?, title: String, artist: String, album: String, playing: Bool,
                     outOfSight: Bool, cover: (@escaping (NSImage?) -> Void) -> Void) {
        guard id != lastId else { return }
        lastId = id
        guard let id = id, playing, outOfSight, SongNotifier.enabled else { return }
        cover { [weak self] image in
            // The song may have moved on while the cover loaded.
            guard let self = self, self.lastId == id else { return }
            self.post(id: id, title: title, artist: artist, album: album, image: image)
        }
    }

    private func post(id: String, title: String, artist: String, album: String, image: NSImage?) {
        let centre = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = artist
        content.body = album
        content.sound = nil
        if let image = image, let data = SongNotifier.jpeg(image) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("itr-cover-\(id).jpg")
            if (try? data.write(to: url)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "cover", url: url, options: nil) {
                content.attachments = [attachment]
            }
        }
        // One identifier, so the new song replaces the old banner rather
        // than piling up in Notification Centre.
        let request = UNNotificationRequest(identifier: "now-playing", content: content, trigger: nil)
        withPermission { ok in
            guard ok else { return }
            centre.add(request) { error in
                if let error = error { NSLog("notification: \(error.localizedDescription)") }
            }
        }
    }

    private func withPermission(_ then: @escaping @Sendable (Bool) -> Void) {
        if let known = permission { then(known); return }
        guard !asking else { return }
        asking = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.permission = granted
                self?.asking = false
                then(granted)
            }
        }
    }

    /// A small square JPEG, which is all a banner shows.
    private static func jpeg(_ image: NSImage) -> Data? {
        let side: CGFloat = 256
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
