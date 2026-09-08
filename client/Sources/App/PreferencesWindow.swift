import Cocoa

/// Preferences (⌘,): the app's lasting choices in one window, the way
/// iTunes kept them, rather than scattered through View and Controls. The
/// menu items stay as shortcuts; both read and write the same defaults, so
/// a change made in either shows in the other.
@MainActor
final class PreferencesWindow: NSWindowController {
    private unowned let main: MainWindowController
    private var checks: [(button: NSButton, read: () -> Bool, toggle: () -> Void)] = []
    private let lookPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(main: MainWindowController) {
        self.main = main
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 470, height: 486))
        content.gradientTop = Theme.ink(0.94)
        content.gradientBottom = Theme.ink(0.90)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) Preferences"
        window.contentView = content
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(in: content)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Building

    private var y: CGFloat = 0

    private func build(in v: NSView) {
        y = v.bounds.height - 22

        heading("Look", in: v)
        let row = NSView(frame: NSRect(x: 40, y: y - 26, width: 400, height: 24))
        let lookLabel = label("Appearance:", size: 13, in: row, x: 0, y: 3, width: 96)
        lookLabel.alignment = .right
        lookPopup.frame = NSRect(x: 102, y: 0, width: 200, height: 24)
        lookPopup.font = Aqua.font(12)
        lookPopup.addItems(withTitles: ["Classic iTunes 10", "Modern Glass"])
        lookPopup.target = self
        lookPopup.action = #selector(lookChanged(_:))
        row.addSubview(lookPopup)
        v.addSubview(row)
        y -= 30
        note("Switching relaunches the app; nothing is lost.", in: v)
        y -= 10

        heading("Sidebar", in: v)
        check("Show the Playlist Curator", nil, in: v,
              read: { !MainWindowController.curatorHidden }, toggle: { [main] in main.toggleCuratorVisible(nil) })
        check("Show Radio", nil, in: v,
              read: { !MainWindowController.radioHidden }, toggle: { [main] in main.toggleRadioVisible(nil) })
        check("Show Duplicates under Library", nil, in: v,
              read: { MainWindowController.duplicatesShown }, toggle: { [main] in main.toggleDuplicatesVisible(nil) })
        check("Show counts beside playlists, Favorites and Recently Played", nil, in: v,
              read: { MainWindowController.sidebarCountsShown }, toggle: { [main] in main.toggleSidebarCounts(nil) })
        y -= 10

        heading("Playing", in: v)
        check("Announce each new song", "A notification with the cover, when the window is out of sight.", in: v,
              read: { SongNotifier.enabled }, toggle: { [main] in main.toggleSongNotifications(nil) })
        if !ServerSettings.isMusic {
            check("Volume keys control \(ServerSettings.appName) on the other Mac",
                  "While it is playing there. Needs the Accessibility permission once.", in: v,
                  read: { MainWindowController.volumeKeysEnabled }, toggle: { [main] in main.toggleVolumeKeys(nil) })
        }
        y -= 10

        heading("Models", in: v)
        check("AI features", "The Playlist Curator, More Like This, training, and Ask on the radio.", in: v,
              read: { MainWindowController.aiEnabled }, toggle: { [main] in main.toggleAIFeatures(nil) })
    }

    private func heading(_ text: String, in v: NSView) {
        let l = label(text, size: 13, bold: true, in: v, x: 20, y: y - 16, width: 430)
        l.textColor = Theme.ink(0.25)
        y -= 26
    }

    private func note(_ text: String, in v: NSView) {
        let l = label(text, size: 11, in: v, x: 40, y: y - 14, width: 410)
        l.textColor = Theme.ink(0.45)
        y -= 18
    }

    @discardableResult
    private func label(_ text: String, size: CGFloat, bold: Bool = false, in v: NSView, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Aqua.font(size, bold: bold)
        l.textColor = Theme.ink(0.2)
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: x, y: y, width: width, height: size + 6)
        v.addSubview(l)
        return l
    }

    private func check(_ title: String, _ detail: String?, in v: NSView, read: @escaping () -> Bool, toggle: @escaping () -> Void) {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        b.font = Aqua.font(13)
        b.frame = NSRect(x: 40, y: y - 20, width: 420, height: 20)
        v.addSubview(b)
        checks.append((b, read, toggle))
        y -= 22
        if let d = detail {
            let l = label(d, size: 11, in: v, x: 58, y: y - 12, width: 400)
            l.textColor = Theme.ink(0.45)
            y -= 16
        }
    }

    // MARK: State

    private func refresh() {
        for c in checks { c.button.state = c.read() ? .on : .off }
        lookPopup.selectItem(at: Theme.isModern ? 1 : 0)
    }

    @objc private func checkChanged(_ sender: NSButton) {
        guard let c = checks.first(where: { $0.button === sender }) else { return }
        if c.read() != (sender.state == .on) { c.toggle() }
        refresh()
    }

    @objc private func lookChanged(_ sender: NSPopUpButton) {
        let modern = sender.indexOfSelectedItem == 1
        guard modern != Theme.isModern else { return }
        NSApp.sendAction(Selector(modern ? "useModernLook:" : "useClassicLook:"), to: nil, from: self)
    }
}
