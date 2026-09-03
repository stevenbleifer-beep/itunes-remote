import Cocoa

// Command line, for development and screenshots:
//   --host H --port P --token T   use these instead of the saved settings (not persisted)
//   --snapshot PATH               render the main window to PATH after the first load, then quit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenu()

        let args = CommandLine.arguments
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        main = MainWindowController()
        main.snapshotPath = arg("--snapshot")
        main.initialFlowIndex = arg("--flow-index").flatMap { Int($0) }
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        var settings = ServerSettings.load()
        var overridden = false
        if let h = arg("--host") { settings.host = h; overridden = true }
        if let p = arg("--port"), let n = Int(p) { settings.port = n; overridden = true }
        if let t = arg("--token") { settings.token = t; overridden = true }

        if settings.token.isEmpty && !overridden {
            guard let chosen = ConnectPanel(settings: settings).run() else { return }
            settings = chosen
            settings.save()
        }
        connect(with: settings)
    }

    private func connect(with settings: ServerSettings) {
        guard let url = settings.baseURL else { return }
        main.connect(APIClient(baseURL: url, token: settings.token))
    }

    @objc func showConnectPanel(_ sender: Any?) {
        let current = ServerSettings.load()
        guard let chosen = ConnectPanel(settings: current).run() else { return }
        chosen.save()
        connect(with: chosen)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iTunes Remote", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iTunes Remote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Get Info", action: #selector(MainWindowController.showGetInfo(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Connect…", action: #selector(showConnectPanel(_:)), keyEquivalent: "k")
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

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
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
