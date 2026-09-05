import Cocoa

// Command line, for development and screenshots:
//   --host H --port P --token T   use these instead of the saved settings (not persisted)
//   --snapshot PATH               render the main window to PATH after the first load, then quit
//   --snapshot-device NAME        open that device's Music pane first, so the pane can be checked
//   --snapshot-lcd player|sync    with --snapshot-device: force the display's view before capturing
//   --source recent|curator|device:NAME  open that source at launch (device: with no name takes the first)
//   --view list|coverflow|albumlist|grid  start in that view (saved, like clicking the switcher)
//   --select-album "Artist|Album"        select that album in the grid or Cover Flow once albums load

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var main: MainWindowController!
    private var setup: SetupAssistant?
    private var browserSubmenu: NSMenu?
    private var columnsSubmenu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === browserSubmenu { main?.buildBrowserMenu(menu) }
        if menu === columnsSubmenu { main?.buildColumnMenu(menu) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenu()

        let args = CommandLine.arguments
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        // `--view list|coverflow|albumlist|grid` sets the view before the
        // window is built; it is saved like a click on the switcher would be.
        if let v = arg("--view"), let mode = ["list": 0, "coverflow": 1, "albumlist": 2, "grid": 3][v.lowercased()] {
            UserDefaults.standard.set(mode, forKey: "viewMode")
        }
        main = MainWindowController()
        main.snapshotPath = arg("--snapshot")
        main.snapshotDevice = arg("--snapshot-device")
        main.snapshotLCD = arg("--snapshot-lcd")
        main.initialFlowIndex = arg("--flow-index").flatMap { Int($0) }
        main.initialSource = arg("--source")
        main.initialAlbum = arg("--select-album")
        main.curateScript = zip(args, args.dropFirst()).filter { $0.0 == "--curate" }.map { $0.1 }
        main.curateSaveName = arg("--curate-save")
        main.curateApproveName = arg("--curate-approve")
        main.openMissingArtwork = args.contains("--missing-art")
        main.likeAlbum = arg("--like")
        if args.contains("--mini") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak main] in main?.toggleMiniPlayer(nil) }
        }
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // A development run with its own token stays out of the keychain.
        if arg("--token") != nil { TokenStore.enabled = false }
        var settings = ServerSettings.load()
        var overridden = false
        if let h = arg("--host") { settings.host = h; overridden = true }
        if let p = arg("--port"), let n = Int(p) { settings.port = n; overridden = true }
        if let t = arg("--token") { settings.token = t; overridden = true }

        // `--pair host[:port] --pair-code NNNNNN`: pairs with a daemon without
        // the assistant, saves the settings (the token into this app's own
        // keychain item) and connects. For re-pairing from a script.
        if let target = arg("--pair"), let code = arg("--pair-code") {
            let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
            let host = parts[0]
            let port = parts.count > 1 ? (Int(parts[1]) ?? 8765) : 8765
            Task { @MainActor in
                do {
                    let r = try await APIClient.pair(host: host, port: port, code: code)
                    var chosen = ServerSettings(host: r.tailscaleName.isEmpty ? host : r.tailscaleName,
                                                lanHost: host, port: port, token: r.token)
                    chosen.name = r.name.isEmpty ? host : r.name
                    chosen.backend = AppIdentity.backend
                    chosen.save()
                    print("pair: ok, \(chosen.name) at \(chosen.lanHost):\(chosen.port), away via \(chosen.host)")
                    fflush(stdout)
                    self.connect(with: chosen)
                } catch {
                    print("pair: failed: \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
            return
        }
        if let code = arg("--setup-demo") {
            let assistant = SetupAssistant(settings: settings)
            assistant.onFinish = { [weak self] chosen in
                print("finished: home=\(chosen.lanHost) away=\(chosen.host) port=\(chosen.port) token=\(chosen.token == settings.token ? "same" : "different")")
                fflush(stdout)
                self?.connect(with: chosen)
            }
            setup = assistant
            assistant.run()
            assistant.demo(code: code)
            return
        }
        // The Apple Music library on this Mac needs no pairing: the daemon
        // runs as the same user, so its token is read from its own config.
        // First use installs the daemon (bundled) when it is not answering.
        if CommandLine.arguments.contains("--setup-this-mac") || (ServerSettings.isMusicProfile && settings.token.isEmpty && !overridden) {
            setupThisMac(settings)
            return
        }
        if settings.token.isEmpty && !overridden {
            // Nothing paired yet: the assistant finds the other Mac and
            // pairs, then connects. Cancelling leaves the window open with
            // File ▸ Set Up… and Connect… to try again.
            runSetup(settings)
            return
        }
        connect(with: settings)
    }

    @objc func showSetup(_ sender: Any?) {
        runSetup(ServerSettings.load())
    }

    /// Exactly what the assistant's "This Mac" row does, without the
    /// window: installs the bundled daemon if none answers, reads its token,
    /// saves the settings for the Apple Music library and connects.
    private func setupThisMac(_ settings: ServerSettings) {
        Task { @MainActor in
            var hello = try? await APIClient.hello(host: LocalDaemon.host, port: LocalDaemon.port)
            if hello == nil, LocalDaemon.available {
                self.main.flashStatus("Installing the library reader for Music on this Mac… If macOS asks whether “Python” may control “Music”, click OK.")
                if (try? await LocalDaemon.install()) != nil {
                    hello = await LocalDaemon.waitForHello(seconds: 90)
                }
            }
            if let h = hello, let token = LocalDaemon.token {
                var s = settings
                s.lanHost = LocalDaemon.host
                s.host = LocalDaemon.host
                s.port = h.port
                s.token = token
                s.name = h.name
                s.backend = h.backend
                s.save()
                print("set up with this Mac: \(h.name), \(h.backend) \(h.itunesVersion)"); fflush(stdout)
                self.connect(with: s)
            } else {
                self.runSetup(settings)
            }
        }
    }

    // MARK: Switching libraries

    /// File ▸ Library ▸ …: the other library, in a fresh copy of the app.
    /// Relaunching is what keeps the two apart — the curator index, the
    /// artwork cache, the queue and the connection all start over from the
    /// other library's own settings, and nothing is carried across.
    @objc func useITunesLibrary(_ sender: Any?) { switchLibrary(to: "itunes") }
    @objc func useMusicLibrary(_ sender: Any?) { switchLibrary(to: "music") }

    // MARK: Appearance

    /// View ▸ Appearance ▸ …: the other look, in a fresh copy of the app.
    /// Every control reads the choice once at launch, so a relaunch is the
    /// clean way to change all of them at once.
    @objc func useClassicLook(_ sender: Any?) { switchAppearance(to: "classic") }
    @objc func useModernLook(_ sender: Any?) { switchAppearance(to: "modern") }

    private func switchAppearance(to look: String) {
        let modern = look == "modern"
        guard modern != Theme.isModern else { return }
        UserDefaults.standard.set(look, forKey: "appearance")
        relaunch()
    }

    private func relaunch() {
        UserDefaults.standard.synchronize()
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func switchLibrary(to profile: String) {
        guard profile != ServerSettings.profile else { return }
        let alert = NSAlert()
        let target = profile == "music" ? "the Apple Music library on this Mac" : "iTunes on the \(ServerSettings.itunesName)"
        alert.messageText = "Switch to \(target)?"
        alert.informativeText = "\(AppIdentity.name) quits and reopens with that library. The two are kept apart: each has its own connection, queue and curator, and nothing from one shows in the other."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ServerSettings.profile = profile
        relaunch()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(useClassicLook(_:)) { item.state = Theme.isModern ? .off : .on }
        if item.action == #selector(useModernLook(_:)) { item.state = Theme.isModern ? .on : .off }
        if item.action == #selector(useITunesLibrary(_:)) { item.state = ServerSettings.isMusicProfile ? .off : .on }
        if item.action == #selector(useMusicLibrary(_:)) {
            item.state = ServerSettings.isMusicProfile ? .on : .off
            return LocalDaemon.available
        }
        return true
    }

    private func runSetup(_ settings: ServerSettings) {
        let assistant = SetupAssistant(settings: settings)
        assistant.onFinish = { [weak self] chosen in
            chosen.save()
            self?.connect(with: chosen)
            self?.setup = nil
        }
        assistant.onCancel = { [weak self] in self?.setup = nil }
        setup = assistant
        assistant.run()
    }

    private func connect(with settings: ServerSettings) {
        guard let url = settings.baseURL else { return }
        main.connect(APIClient(baseURL: url, token: settings.token))
        if let lan = settings.lanURL, lan != url {
            main.startConnectionMonitor(lanURL: lan, token: settings.token)
        }
    }

    @objc func showConnectPanel(_ sender: Any?) {
        let current = ServerSettings.load()
        guard let chosen = ConnectPanel(settings: current).run() else { return }
        chosen.save()
        connect(with: chosen)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        CuratorTrainer.shared.cancel()
        OllamaRuntime.shared.stop()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppIdentity.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Get Info", action: #selector(MainWindowController.showGetInfo(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Find Missing Artwork…", action: #selector(MainWindowController.showMissingArtwork(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Set Up \(AppIdentity.name)…", action: #selector(showSetup(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Connect…", action: #selector(showConnectPanel(_:)), keyEquivalent: "k")
        fileMenu.addItem(.separator())
        // Two libraries, never mixed: the app reopens with the one chosen.
        let libraryMenu = NSMenu(title: "Library")
        libraryMenu.addItem(withTitle: "iTunes on the \(ServerSettings.itunesName)", action: #selector(useITunesLibrary(_:)), keyEquivalent: "")
        libraryMenu.addItem(withTitle: "Apple Music on This Mac", action: #selector(useMusicLibrary(_:)), keyEquivalent: "")
        let libraryItem = NSMenuItem(title: "Library", action: nil, keyEquivalent: "")
        libraryItem.submenu = libraryMenu
        fileMenu.addItem(libraryItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(MainWindowController.focusSearch(_:)), keyEquivalent: "f")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewMenu = NSMenu(title: "View")
        viewMenu.autoenablesItems = false
        let browserItem = NSMenuItem(title: "Column Browser", action: nil, keyEquivalent: "")
        let browserSub = NSMenu()
        browserSub.delegate = self
        browserItem.submenu = browserSub
        viewMenu.addItem(browserItem)
        browserSubmenu = browserSub
        let columnsItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        let columnsSub = NSMenu()
        columnsSub.delegate = self
        columnsItem.submenu = columnsSub
        viewMenu.addItem(columnsItem)
        columnsSubmenu = columnsSub
        viewMenu.addItem(.separator())
        // A way back to the order the source is stored in, since a playlist's
        // own order is not reproducible from any column.
        let resetSortItem = viewMenu.addItem(withTitle: "Clear Column Sort",
                                             action: #selector(MainWindowController.resetSort(_:)),
                                             keyEquivalent: "0")
        resetSortItem.keyEquivalentModifierMask = [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option]
        viewMenu.addItem(.separator())
        // Ticked when the CURATOR section is in the sidebar; untick to hide it.
        let lookMenu = NSMenu(title: "Appearance")
        lookMenu.addItem(withTitle: "Classic iTunes 10", action: #selector(useClassicLook(_:)), keyEquivalent: "")
        lookMenu.addItem(withTitle: "Modern Glass", action: #selector(useModernLook(_:)), keyEquivalent: "")
        let lookItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        lookItem.submenu = lookMenu
        viewMenu.addItem(lookItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "AI Features", action: #selector(MainWindowController.toggleAIFeatures(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Playlist Curator", action: #selector(MainWindowController.toggleCuratorVisible(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Show Duplicates", action: #selector(MainWindowController.toggleDuplicatesVisible(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        for (i, title) in ["as List", "as Album List", "as Grid", "as Cover Flow"].enumerated() {
            let item = viewMenu.addItem(withTitle: title,
                                        action: #selector(MainWindowController.pickViewMode(_:)),
                                        keyEquivalent: String(i + 3))
            item.keyEquivalentModifierMask = [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option]
            item.tag = i
        }
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Controls, as iTunes had it: the queue commands live here as well as
        // in the track context menu, so they have keyboard shortcuts.
        let controlsMenu = NSMenu(title: "Controls")
        let playNext = controlsMenu.addItem(withTitle: "Play Next",
                                            action: #selector(MainWindowController.playNext(_:)), keyEquivalent: "n")
        playNext.keyEquivalentModifierMask = [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option]
        let addUpNext = controlsMenu.addItem(withTitle: "Add to Up Next",
                                             action: #selector(MainWindowController.addToUpNext(_:)), keyEquivalent: "e")
        addUpNext.keyEquivalentModifierMask = [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option]
        controlsMenu.addItem(.separator())
        let showQueue = controlsMenu.addItem(withTitle: "Show Up Next",
                                             action: #selector(MainWindowController.showUpNext(_:)), keyEquivalent: "u")
        showQueue.keyEquivalentModifierMask = [NSEvent.ModifierFlags.command, NSEvent.ModifierFlags.option]
        let identify = controlsMenu.addItem(withTitle: "Identify What’s Playing…",
                                            action: #selector(MainWindowController.identifyPlaying(_:)), keyEquivalent: "i")
        identify.keyEquivalentModifierMask = [.command, .shift]
        controlsMenu.addItem(withTitle: "Notify on Song Change",
                             action: #selector(MainWindowController.toggleSongNotifications(_:)), keyEquivalent: "")
        controlsMenu.addItem(.separator())
        let curatorItem = controlsMenu.addItem(withTitle: "Playlist Curator",
                                               action: #selector(MainWindowController.showCurator(_:)), keyEquivalent: "k")
        curatorItem.keyEquivalentModifierMask = [.command, .shift]
        controlsMenu.addItem(withTitle: "Train Curator on My Edits…",
                             action: #selector(MainWindowController.showTraining(_:)), keyEquivalent: "")
        controlsMenu.addItem(.separator())
        if !ServerSettings.isMusic {
            controlsMenu.addItem(withTitle: "Find iPod…",
                                 action: #selector(MainWindowController.findIPod(_:)), keyEquivalent: "")
        }
        controlsMenu.addItem(withTitle: "Restart \(ServerSettings.appName) on the \(ServerSettings.name)…",
                             action: #selector(MainWindowController.restartITunes(_:)), keyEquivalent: "")
        let controlsItem = NSMenuItem()
        controlsItem.submenu = controlsMenu
        mainMenu.addItem(controlsItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let mini = windowMenu.addItem(withTitle: "Switch to Mini Player", action: #selector(MainWindowController.toggleMiniPlayer(_:)), keyEquivalent: "M")
        mini.keyEquivalentModifierMask = [.command, .shift]
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
