import Cocoa

/// Preferences (⌘,), the way iTunes 10 laid its own out: a row of icon tabs
/// across the top — General, Playback, Radio, Advanced — groups divided by
/// rules, and Cancel and OK along the bottom. Nothing changes until OK;
/// Cancel drops it all. The menu items remain as shortcuts for the same
/// settings, and both read the same defaults.
@MainActor
final class PreferencesWindow: NSWindowController, NSToolbarDelegate {
    private unowned let main: MainWindowController

    private enum Pane: String, CaseIterable {
        case general = "General", playback = "Playback", radio = "Radio", curator = "Curator", advanced = "Advanced"
        var id: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
    }

    /// A setting: how to read it, how to flip it, and its checkbox.
    private struct Setting {
        let button: NSButton
        let read: () -> Bool
        let toggle: () -> Void
    }
    private var settings: [Pane: [Setting]] = [:]
    private var panes: [Pane: NSView] = [:]
    private var current: Pane = .general
    private let lookPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let libraryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The curator's picker: which model chooses the songs.
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelNote = NSTextField(wrappingLabelWithString: "")
    private let machineNote = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = AquaPushButton(title: "Download")
    private let downloadProgress = NSProgressIndicator()
    /// Which pickers Ollama already has on disk; empty until it answers.
    private var downloaded: Set<String> = []
    private var pulling = false
    private let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 500, height: 330))
    private let paneHost = NSView()
    private let okButton = AquaPushButton(title: "OK", isDefault: true)
    private let cancelButton = AquaPushButton(title: "Cancel")

    init(main: MainWindowController) {
        self.main = main
        content.gradientTop = Theme.ink(0.95)
        content.gradientBottom = Theme.ink(0.91)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "General"
        window.contentView = content
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "preferences")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Pane.general.id
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Opens straight onto one page, by its name: for the test flag, and
    /// for anything that wants to send the listener to a particular setting.
    func show(pane name: String) {
        show()
        guard let pane = Pane.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        showPane(pane)
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map { $0.id } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map { $0.id } }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map { $0.id } }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.rawValue
        item.image = PreferencesWindow.icon(for: pane)
        item.target = self
        item.action = #selector(paneChosen(_:))
        return item
    }

    @objc private func paneChosen(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPane(pane)
    }

    private func showPane(_ pane: Pane) {
        current = pane
        window?.title = pane.rawValue
        for (p, v) in panes { v.isHidden = p != pane }
        window?.toolbar?.selectedItemIdentifier = pane.id
    }

    /// The tab icons, drawn: a switch for General, a play disc for
    /// Playback, the sidebar's wireless set for Radio, a gear for Advanced.
    private static func icon(for pane: Pane) -> NSImage {
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let body = NSColor(srgbRed: 0.42, green: 0.50, blue: 0.62, alpha: 1)
            let dark = NSColor(srgbRed: 0.28, green: 0.35, blue: 0.46, alpha: 1)
            switch pane {
            case .general:
                // Two slider tracks with knobs.
                body.setFill()
                for (y, kx) in [(c.y + 6, c.x - 5), (c.y - 6, c.x + 5)] as [(CGFloat, CGFloat)] {
                    NSBezierPath(roundedRect: NSRect(x: c.x - 12, y: y - 2, width: 24, height: 4), xRadius: 2, yRadius: 2).fill()
                    NSGradient(starting: .white, ending: NSColor(white: 0.82, alpha: 1))!
                        .draw(in: NSBezierPath(ovalIn: NSRect(x: kx - 5, y: y - 5, width: 10, height: 10)), angle: -90)
                    dark.setStroke()
                    NSBezierPath(ovalIn: NSRect(x: kx - 5, y: y - 5, width: 10, height: 10)).stroke()
                }
            case .playback:
                NSGradient(starting: NSColor(srgbRed: 0.60, green: 0.72, blue: 0.90, alpha: 1), ending: body)!
                    .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)), angle: -90)
                dark.setStroke()
                NSBezierPath(ovalIn: NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)).stroke()
                NSColor.white.setFill()
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: c.x - 4, y: c.y - 7)); tri.line(to: NSPoint(x: c.x + 8, y: c.y)); tri.line(to: NSPoint(x: c.x - 4, y: c.y + 7)); tri.close()
                tri.fill()
            case .radio:
                body.setFill()
                NSBezierPath(roundedRect: NSRect(x: c.x - 14, y: c.y - 11, width: 28, height: 18), xRadius: 4, yRadius: 4).fill()
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x + 2, y: c.y - 8, width: 9, height: 9)).fill()
                for y in [-8.0, -4.0, 0.0] as [CGFloat] { NSRect(x: c.x - 11, y: c.y + y, width: 10, height: 2).fill() }
                dark.setStroke()
                let aerial = NSBezierPath()
                aerial.move(to: NSPoint(x: c.x - 5, y: c.y + 7)); aerial.line(to: NSPoint(x: c.x + 8, y: c.y + 15))
                aerial.lineWidth = 2.2
                aerial.stroke()
            case .curator:
                // A playlist's lines with a note standing on them.
                body.setFill()
                for y in [-11.0, -6.0, -1.0] as [CGFloat] {
                    NSBezierPath(roundedRect: NSRect(x: c.x - 13, y: c.y + y, width: 20, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
                }
                dark.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y + 4, width: 9, height: 7)).fill()
                NSBezierPath(rect: NSRect(x: c.x + 5.5, y: c.y + 7, width: 2, height: 9)).fill()
                NSBezierPath(roundedRect: NSRect(x: c.x + 5.5, y: c.y + 13, width: 8, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            case .advanced:
                body.setFill()
                let gear = NSBezierPath()
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    let tooth = NSRect(x: -3, y: 6, width: 6, height: 8)
                    var t = AffineTransform(translationByX: c.x, byY: c.y)
                    t.rotate(byRadians: a)
                    let p = NSBezierPath(roundedRect: tooth, xRadius: 1.5, yRadius: 1.5)
                    p.transform(using: t)
                    gear.append(p)
                }
                gear.append(NSBezierPath(ovalIn: NSRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)))
                gear.fill()
                NSColor(white: 0.93, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
            }
            return true
        }
        return img
    }

    // MARK: The panes

    private func build() {
        paneHost.frame = NSRect(x: 0, y: 44, width: content.bounds.width, height: content.bounds.height - 44)
        content.addSubview(paneHost)
        for pane in Pane.allCases {
            let v = NSView(frame: paneHost.bounds)
            v.isHidden = pane != .general
            paneHost.addSubview(v)
            panes[pane] = v
        }
        buildGeneral(panes[.general]!)
        buildPlayback(panes[.playback]!)
        buildRadio(panes[.radio]!)
        buildCurator(panes[.curator]!)
        buildAdvanced(panes[.advanced]!)

        // Cancel and OK, at the bottom right, as iTunes had them.
        for b in [cancelButton, okButton] {
            b.target = self
            content.addSubview(b)
        }
        okButton.action = #selector(ok(_:))
        cancelButton.action = #selector(cancel(_:))
        let ok = okButton.intrinsicContentSize, ca = cancelButton.intrinsicContentSize
        okButton.frame = NSRect(x: content.bounds.width - 14 - ok.width, y: 10, width: ok.width, height: ok.height)
        cancelButton.frame = NSRect(x: okButton.frame.minX - 2 - ca.width, y: 10, width: ca.width, height: ca.height)
        let rule = NSBox(frame: NSRect(x: 0, y: 44, width: content.bounds.width, height: 1))
        rule.boxType = .separator
        content.addSubview(rule)
    }

    private func buildGeneral(_ v: NSView) {
        var y = v.bounds.height - 30
        fieldRow("Look:", y: y, in: v) { x in
            self.lookPopup.frame = NSRect(x: x, y: 0, width: 190, height: 24)
            self.lookPopup.addItems(withTitles: ["Classic iTunes 10", "Modern Glass"])
            return self.lookPopup
        }
        y -= 8
        y -= note("Switching the look relaunches the app; nothing is lost.", x: 116, y: y, in: v) + 14
        separator(y: y, in: v); y -= 28
        label("Show:", y: y, in: v)
        let show: [(String, () -> Bool, () -> Void)] = [
            ("Playlist Curator", { !MainWindowController.curatorHidden }, { [main] in main.toggleCuratorVisible(nil) }),
            ("Duplicates", { MainWindowController.duplicatesShown }, { [main] in main.toggleDuplicatesVisible(nil) }),
            ("Radio", { !MainWindowController.radioHidden }, { [main] in main.toggleRadioVisible(nil) }),
        ]
        var col = 0
        var rowY = y
        for (i, s) in show.enumerated() {
            col = i % 2
            if i > 0 && col == 0 { rowY -= 22 }
            check(s.0, pane: .general, x: 116 + CGFloat(col) * 180, y: rowY, in: v, read: s.1, toggle: s.2)
        }
        y = rowY - 26
        separator(y: y, in: v); y -= 28
        check("Show counts beside playlists and the radio's lists", pane: .general, x: 116, y: y, in: v,
              read: { MainWindowController.sidebarCountsShown }, toggle: { [main] in main.toggleSidebarCounts(nil) })
    }

    private func buildPlayback(_ v: NSView) {
        var y = v.bounds.height - 30
        check("Announce each new song", pane: .playback, x: 30, y: y, in: v,
              read: { SongNotifier.enabled }, toggle: { [main] in main.toggleSongNotifications(nil) })
        y -= 6
        y -= note("A notification with the cover, when the window is out of sight.", x: 48, y: y, in: v) + 26
        if !ServerSettings.isMusic {
            check("Volume keys control \(ServerSettings.appName) on the other Mac", pane: .playback, x: 30, y: y, in: v,
                  read: { MainWindowController.volumeKeysEnabled }, toggle: { [main] in main.toggleVolumeKeys(nil) })
            y -= 6
            y -= note("While it is playing there. Needs the Accessibility permission once.", x: 48, y: y, in: v) + 26
        }
        separator(y: y, in: v); y -= 16
        note("Shuffle and Repeat are the buttons at the bottom of the window; they belong to this app, not to \(ServerSettings.appName).", x: 30, y: y, in: v)
    }

    private func buildRadio(_ v: NSView) {
        var y = v.bounds.height - 30
        check("Show Radio in the sidebar", pane: .radio, x: 30, y: y, in: v,
              read: { !MainWindowController.radioHidden }, toggle: { [main] in main.toggleRadioVisible(nil) })
        y -= 28
        separator(y: y, in: v); y -= 16
        y -= note("Stations come from the Radio Browser directory. Ask uses the curator's model to search it.", x: 30, y: y, in: v) + 16
        let forget = AquaPushButton(title: "Forget Refused Stations")
        forget.target = self
        forget.action = #selector(forgetRefused(_:))
        let fs = forget.intrinsicContentSize
        forget.frame = NSRect(x: 26, y: y - fs.height + 6, width: fs.width, height: fs.height)
        v.addSubview(forget)
        note("Stations \(ServerSettings.appName) could not play are remembered and go straight to this Mac; this forgets them.",
             x: 26 + fs.width + 6, y: y + 2, in: v)
    }

    /// The curator's own page: which model does the choosing, how big a
    /// download it is, and how long a turn takes on this Mac. It used to be
    /// buried in the setup assistant, which meant re-running setup to change
    /// it — and a Mac that gets replaced by a faster one keeps the picker
    /// chosen for the old one until somebody says otherwise.
    private func buildCurator(_ v: NSView) {
        var y = v.bounds.height - 30
        fieldRow("Picker:", y: y, in: v) { x in
            self.modelPopup.frame = NSRect(x: x, y: 0, width: 360, height: 24)
            self.modelPopup.target = self
            self.modelPopup.action = #selector(self.modelPicked(_:))
            return self.modelPopup
        }
        y -= 22
        modelNote.font = Aqua.font(11)
        modelNote.textColor = Theme.ink(0.45)
        let noteWidth = v.bounds.width - 132
        modelNote.preferredMaxLayoutWidth = noteWidth
        modelNote.frame = NSRect(x: 112, y: y - 30, width: noteWidth, height: 30)
        v.addSubview(modelNote)
        y -= 38
        downloadButton.target = self
        downloadButton.action = #selector(downloadModel(_:))
        let ds = downloadButton.intrinsicContentSize
        downloadButton.frame = NSRect(x: 108, y: y - ds.height, width: ds.width, height: ds.height)
        downloadButton.isHidden = true
        v.addSubview(downloadButton)
        downloadProgress.frame = NSRect(x: 112 + ds.width + 8, y: y - ds.height + 6, width: 190, height: 12)
        downloadProgress.isIndeterminate = false
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 1
        downloadProgress.controlSize = .small
        downloadProgress.style = .bar
        downloadProgress.isHidden = true
        v.addSubview(downloadProgress)
        y -= ds.height + 14
        separator(y: y, in: v); y -= 16
        y -= note("A bigger picker chooses with more taste and takes longer. Every song still comes from your own library — the picker only chooses, and it never sees the library itself.", x: 30, y: y, in: v) + 12
        machineNote.font = Aqua.font(11)
        machineNote.textColor = Theme.ink(0.45)
        machineNote.preferredMaxLayoutWidth = v.bounds.width - 50
        machineNote.frame = NSRect(x: 30, y: y - 28, width: v.bounds.width - 50, height: 28)
        v.addSubview(machineNote)
    }

    private func buildAdvanced(_ v: NSView) {
        var y = v.bounds.height - 30
        check("AI features", pane: .advanced, x: 30, y: y, in: v,
              read: { MainWindowController.aiEnabled }, toggle: { [main] in main.toggleAIFeatures(nil) })
        y -= 6
        y -= note("The Playlist Curator, More Like This, training, and Ask on the radio. Off, no model runs.", x: 48, y: y, in: v) + 18
        separator(y: y, in: v); y -= 32
        fieldRow("Library:", y: y, in: v) { x in
            self.libraryPopup.frame = NSRect(x: x, y: 0, width: 240, height: 24)
            self.libraryPopup.addItems(withTitles: ["\(ServerSettings.itunesName) — iTunes", "This Mac — Apple Music"])
            return self.libraryPopup
        }
        y -= 8
        y -= note("Two libraries that never mix; switching relaunches the app.", x: 116, y: y, in: v) + 18
        let connect = AquaPushButton(title: "Connect…")
        connect.target = self
        connect.action = #selector(connect(_:))
        let cs = connect.intrinsicContentSize
        connect.frame = NSRect(x: 106, y: y - cs.height + 6, width: cs.width, height: cs.height)
        v.addSubview(connect)
        note("The other Mac's address and token.", x: 106 + cs.width + 6, y: y + 2, in: v)
    }

    // MARK: Pieces

    private func label(_ text: String, y: CGFloat, in v: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = Aqua.font(13)
        l.textColor = Theme.ink(0.2)
        l.alignment = .right
        l.frame = NSRect(x: 20, y: y - 2, width: 88, height: 19)
        v.addSubview(l)
    }

    /// A grey explanatory line (or two) whose top edge is at `y`. Returns
    /// its height so the caller can move on below it.
    @discardableResult
    private func note(_ text: String, x: CGFloat, y: CGFloat, in v: NSView, width: CGFloat? = nil) -> CGFloat {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Aqua.font(11)
        l.textColor = Theme.ink(0.45)
        let w = min(width ?? (v.bounds.width - x - 20), v.bounds.width - x - 20)
        l.preferredMaxLayoutWidth = w
        l.frame = NSRect(x: x, y: 0, width: w, height: 30)
        // sizeThatFits, not intrinsicContentSize: the latter answers for the
        // frame as it stands and clips anything past a second line.
        let h = max(l.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height, l.intrinsicContentSize.height)
        l.frame = NSRect(x: x, y: y - h, width: w, height: h)
        v.addSubview(l)
        return h
    }

    private func separator(y: CGFloat, in v: NSView) {
        let rule = NSBox(frame: NSRect(x: 20, y: y, width: v.bounds.width - 40, height: 1))
        rule.boxType = .separator
        v.addSubview(rule)
    }

    private func fieldRow(_ title: String, y: CGFloat, in v: NSView, control: (CGFloat) -> NSView) {
        label(title, y: y, in: v)
        let c = control(0)
        c.frame.origin = NSPoint(x: 112, y: y - 4)
        if let p = c as? NSPopUpButton { p.font = Aqua.font(12) }
        v.addSubview(c)
    }

    private func check(_ title: String, pane: Pane, x: CGFloat, y: CGFloat, in v: NSView, read: @escaping () -> Bool, toggle: @escaping () -> Void) {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.font = Aqua.font(13)
        b.frame = NSRect(x: x, y: y - 2, width: v.bounds.width - x - 20, height: 20)
        v.addSubview(b)
        settings[pane, default: []].append(Setting(button: b, read: read, toggle: toggle))
    }

    // MARK: Staging

    private func refresh() {
        for list in settings.values { for s in list { s.button.state = s.read() ? .on : .off } }
        lookPopup.selectItem(at: Theme.isModern ? 1 : 0)
        libraryPopup.selectItem(at: ServerSettings.isMusicProfile ? 1 : 0)
        fillModelPopup()
        describeMachine()
        describeModel()
        Task { await self.findDownloadedModels() }
    }

    // MARK: The curator's picker

    /// Every picker this Mac has the memory for, plus a trained one if the
    /// training window made it. The chosen one is selected.
    private func fillModelPopup() {
        guard !pulling else { return }
        let chosen = UserDefaults.standard.string(forKey: "curatorModel") ?? CuratorEngine.defaultModel
        let recommended = CuratorModels.recommended()
        modelPopup.removeAllItems()
        for t in CuratorModels.available() {
            let gb = t.downloadGB == t.downloadGB.rounded() ? String(Int(t.downloadGB)) : String(format: "%.1f", t.downloadGB)
            var title = "\(t.name) — \(t.model), \(gb) GB"
            if t.model == recommended.model { title += " (recommended)" }
            modelPopup.addItem(withTitle: title)
            modelPopup.lastItem?.representedObject = t.model
        }
        if CuratorModels.tier(for: chosen) == nil {
            modelPopup.addItem(withTitle: "Trained on your edits — \(chosen)")
            modelPopup.lastItem?.representedObject = chosen
        }
        if let i = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == chosen }) {
            modelPopup.selectItem(at: i)
        }
        // `--pick-model NAME`: show the page with that picker chosen, for a
        // screenshot of a picker that is not downloaded. Nothing is saved.
        if let i = CommandLine.arguments.firstIndex(of: "--pick-model"), i + 1 < CommandLine.arguments.count,
           let j = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == CommandLine.arguments[i + 1] }) {
            modelPopup.selectItem(at: j)
        }
    }

    private var selectedModel: String {
        (modelPopup.selectedItem?.representedObject as? String)
            ?? UserDefaults.standard.string(forKey: "curatorModel") ?? CuratorEngine.defaultModel
    }

    /// The line under the picker: what it is like, and whether it is here.
    private func describeModel() {
        guard !pulling else { return }
        let model = selectedModel
        let tier = CuratorModels.tier(for: model)
        var line = tier.map { "\($0.note.prefix(1).uppercased() + $0.note.dropFirst()); \(CuratorModels.speedPhrase($0))." }
            ?? "Trained on your own edits."
        if downloaded.isEmpty {
            line += " Checking what is downloaded…"
        } else if downloaded.contains(model) {
            line += " Downloaded."
        } else if let t = tier {
            line += " Not downloaded yet — \(Int(t.downloadGB.rounded())) GB."
        } else {
            line += " Not downloaded yet."
        }
        modelNote.stringValue = line
        // The button is there only when there is something to fetch; a
        // greyed-out "Downloaded" button is just furniture.
        let needed = !downloaded.isEmpty && !downloaded.contains(model)
        downloadButton.isHidden = !needed
        downloadButton.isEnabled = needed
    }

    /// The last line: what this Mac is, and what suits it.
    private func describeMachine() {
        let chip = CuratorModels.Chip.brand
        let machine = chip.isEmpty ? "This Mac" : chip
        let rec = CuratorModels.recommended()
        var line = "\(machine), \(CuratorModels.physicalRAMGB) GB — \(rec.name) suits it."
        let chosen = UserDefaults.standard.string(forKey: "curatorModel") ?? CuratorEngine.defaultModel
        if let now = CuratorModels.tier(for: chosen), now.billions < rec.billions {
            line += " The curator is on \(now.name), which was chosen for a smaller Mac."
        }
        machineNote.stringValue = line
    }

    private func findDownloadedModels() async {
        guard let url = await OllamaRuntime.shared.ensureRunning() else {
            modelNote.stringValue = "No model server is running, so nothing can be downloaded or run. Advanced ▸ AI features turns this off entirely."
            downloadButton.isEnabled = false
            return
        }
        let have = (try? await OllamaClient(baseURL: url).models()) ?? []
        downloaded = Set(CuratorModels.tiers.map { $0.model }.filter { m in
            have.contains { $0 == m || $0.hasPrefix(m + ":") }
        })
        // A trained picker counts as here too.
        let chosen = selectedModel
        if CuratorModels.tier(for: chosen) == nil,
           have.contains(where: { $0 == chosen || $0.hasPrefix(chosen + ":") }) { downloaded.insert(chosen) }
        describeModel()
    }

    @objc private func modelPicked(_ sender: Any?) {
        describeModel()
    }

    /// Fetches the chosen picker now. Nothing else in this window acts
    /// before OK, but a download is not a setting — it is a long errand,
    /// and waiting for OK to start it would only make it longer.
    @objc private func downloadModel(_ sender: Any?) {
        guard !pulling else { return }
        let model = selectedModel
        pulling = true
        modelPopup.isEnabled = false
        downloadButton.isEnabled = false
        downloadProgress.isHidden = false
        downloadProgress.doubleValue = 0
        modelNote.stringValue = "Downloading \(model)…"
        Task { [weak self] in
            guard let self = self, let url = await OllamaRuntime.shared.ensureRunning() else {
                self?.finishDownload("The model server would not start.")
                return
            }
            do {
                try await OllamaClient(baseURL: url).pull(model: model) { [weak self] fraction, text in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if fraction >= 0 { self.downloadProgress.doubleValue = fraction }
                        self.modelNote.stringValue = "\(model): \(text)"
                    }
                }
                self.finishDownload(nil)
            } catch {
                self.finishDownload("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishDownload(_ problem: String?) {
        pulling = false
        modelPopup.isEnabled = true
        downloadProgress.isHidden = true
        if let problem = problem {
            modelNote.stringValue = problem
            downloadButton.isHidden = false
            downloadButton.isEnabled = true
            return
        }
        Task { await self.findDownloadedModels() }
    }

    /// Applies every checkbox that differs from its setting, then the two
    /// choices that relaunch — the look first, the library after — so a
    /// relaunch, if one is coming, is the last thing that happens.
    @objc private func ok(_ sender: Any?) {
        for list in settings.values {
            for s in list where s.read() != (s.button.state == .on) { s.toggle() }
        }
        // The picker takes effect on the curator's next question; nothing
        // has to relaunch for it.
        UserDefaults.standard.set(selectedModel, forKey: "curatorModel")
        close()
        let wantModern = lookPopup.indexOfSelectedItem == 1
        let wantMusic = libraryPopup.indexOfSelectedItem == 1
        if wantMusic != ServerSettings.isMusicProfile {
            NSApp.sendAction(Selector(wantMusic ? "useMusicLibrary:" : "useITunesLibrary:"), to: nil, from: self)
        } else if wantModern != Theme.isModern {
            NSApp.sendAction(Selector(wantModern ? "useModernLook:" : "useClassicLook:"), to: nil, from: self)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        refresh()
        close()
    }

    @objc private func forgetRefused(_ sender: Any?) {
        main.forgetRefusedStations()
    }

    @objc private func connect(_ sender: Any?) {
        close()
        NSApp.sendAction(Selector(("showConnectPanel:")), to: nil, from: self)
    }
}
