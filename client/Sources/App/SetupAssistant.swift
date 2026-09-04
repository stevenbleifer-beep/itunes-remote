import Cocoa

/// First run: find the Mac that runs iTunes, pair with it, and offer the
/// two optional extras. Five short pages in one Aqua window, each of which
/// can be skipped, so a person who only wants the remote on the home
/// network is done after two.
@MainActor
final class SetupAssistant: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Step: Int { case find = 0, pair, away, curator, done }

    var onFinish: (ServerSettings) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let window: NSWindow
    private let content: ChromeView
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let table = AquaTableView()
    private let tableScroll = NSScrollView()
    private let manualHost = NSTextField(string: "")
    private let manualPort = NSTextField(string: "8765")
    private let manualLabel = NSTextField(labelWithString: "Or type an address:")
    private let codeField = NSTextField(string: "")
    private let actionButton = AquaPushButton(title: "")
    private let secondButton = AquaPushButton(title: "")
    private let cancelButton = AquaPushButton(title: "Cancel")
    private let backButton = AquaPushButton(title: "Go Back")
    private let skipButton = AquaPushButton(title: "Skip")
    private let nextButton = AquaPushButton(title: "Continue", isDefault: true)

    private let browser = DaemonBrowser()
    private var step: Step = .find
    private var chosen: DaemonBrowser.Found?
    private var pairing: PairResult?
    private var draft: ServerSettings
    private var busy = false
    private var pulled = false

    private static let W: CGFloat = 560, H: CGFloat = 440
    static let curatorModels = [CuratorEngine.defaultModel, CuratorEngine.embedModel]

    init(settings: ServerSettings) {
        draft = settings
        content = ChromeView(frame: NSRect(x: 0, y: 0, width: SetupAssistant.W, height: SetupAssistant.H))
        content.gradientTop = NSColor(white: 0.93, alpha: 1)
        content.gradientBottom = NSColor(white: 0.88, alpha: 1)
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up iTunes Remote"
        window.contentView = content
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        build()
        show(.find)
    }

    // MARK: Layout

    private func build() {
        let W = SetupAssistant.W, H = SetupAssistant.H
        titleLabel.font = Aqua.font(15, bold: true)
        titleLabel.textColor = NSColor(white: 0.2, alpha: 1)
        titleLabel.frame = NSRect(x: 24, y: H - 48, width: W - 48, height: 22)
        content.addSubview(titleLabel)

        bodyLabel.font = Aqua.font(12)
        bodyLabel.textColor = NSColor(white: 0.25, alpha: 1)
        bodyLabel.frame = NSRect(x: 24, y: H - 150, width: W - 48, height: 96)
        content.addSubview(bodyLabel)

        // The list of Macs found on the network.
        table.rowHeight = 20
        table.addTableColumn(AquaTables.column("mac", title: "", width: W - 80, min: 100, sortable: false))
        AquaTables.style(table, rowHeight: 20, header: false)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(next(_:))
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = .legacy
        tableScroll.verticalScroller = AquaScroller()
        tableScroll.borderType = .bezelBorder
        tableScroll.frame = NSRect(x: 24, y: 150, width: W - 48, height: 120)
        content.addSubview(tableScroll)

        manualLabel.font = Aqua.font(12)
        manualLabel.frame = NSRect(x: 24, y: 118, width: 140, height: 18)
        content.addSubview(manualLabel)
        for (f, x, w, placeholder) in [(manualHost, 166.0, 250.0, "name or IP address"), (manualPort, 424.0, 64.0, "8765")] as [(NSTextField, CGFloat, CGFloat, String)] {
            f.font = Aqua.font(12)
            f.bezelStyle = .squareBezel
            f.placeholderString = placeholder
            f.frame = NSRect(x: x, y: 116, width: w, height: 22)
            content.addSubview(f)
        }

        codeField.font = NSFont(name: "LucidaGrande", size: 24) ?? NSFont.systemFont(ofSize: 24)
        codeField.alignment = .center
        codeField.bezelStyle = .squareBezel
        codeField.placeholderString = "000000"
        codeField.frame = NSRect(x: round(W / 2 - 90), y: 200, width: 180, height: 40)
        codeField.target = self
        codeField.action = #selector(next(_:))
        // Return submits; losing focus (or being hidden) must not, or the
        // page after this one gets skipped as the field goes away.
        codeField.cell?.sendsActionOnEndEditing = false
        content.addSubview(codeField)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.frame = NSRect(x: 24, y: 150, width: W - 48, height: 16)
        content.addSubview(progress)

        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.frame = NSRect(x: 24, y: 62, width: W - 48, height: 44)
        content.addSubview(statusLabel)

        for (b, sel) in [(actionButton, #selector(action(_:))), (secondButton, #selector(secondAction(_:))),
                         (cancelButton, #selector(cancel(_:))), (backButton, #selector(back(_:))),
                         (skipButton, #selector(skip(_:))), (nextButton, #selector(next(_:)))] {
            b.target = self
            b.action = sel
            content.addSubview(b)
        }
        placeButtons()
    }

    private func placeButtons() {
        let W = SetupAssistant.W
        func place(_ b: AquaPushButton, rightEdge: CGFloat, y: CGFloat) -> CGFloat {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: rightEdge - s.width, y: y, width: s.width, height: s.height)
            return b.frame.minX
        }
        var x = W - 16
        x = place(nextButton, rightEdge: x, y: 14) + 2
        x = place(skipButton, rightEdge: x, y: 14) + 2
        _ = place(backButton, rightEdge: x, y: 14)
        let cs = cancelButton.intrinsicContentSize
        cancelButton.frame = NSRect(x: 16, y: 14, width: cs.width, height: cs.height)
        let a = actionButton.intrinsicContentSize
        actionButton.frame = NSRect(x: 20, y: 176, width: a.width, height: a.height)
        let sb = secondButton.intrinsicContentSize
        secondButton.frame = NSRect(x: actionButton.frame.maxX + 2, y: 176, width: sb.width, height: sb.height)
    }

    // MARK: Steps

    private func show(_ s: Step) {
        step = s
        for v in [tableScroll as NSView, manualLabel, manualHost, manualPort, codeField, progress, actionButton, secondButton] {
            v.isHidden = true
        }
        statusLabel.stringValue = ""
        backButton.isHidden = s == .find || s == .done
        skipButton.isHidden = !(s == .away || s == .curator)
        nextButton.title = s == .done ? "Finish" : "Continue"
        nextButton.isEnabled = true
        switch s {
        case .find:
            titleLabel.stringValue = "Find the Mac that runs iTunes"
            bodyLabel.stringValue = "On that Mac, double-click “Install iTunes Remote Daemon.command” from the download. It prints a six-digit pairing code. Then choose it here — it appears on its own when both Macs are on the same network."
            tableScroll.isHidden = false
            manualLabel.isHidden = false
            manualHost.isHidden = false
            manualPort.isHidden = false
            statusLabel.stringValue = browser.found.isEmpty ? "Looking on the network…" : ""
            browser.onChange = { [weak self] _ in
                self?.table.reloadData()
                self?.statusLabel.stringValue = ""
                if self?.table.selectedRow ?? -1 < 0 { self?.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
            browser.start()
            table.reloadData()
            window.makeFirstResponder(table)
        case .pair:
            titleLabel.stringValue = "Enter the pairing code"
            bodyLabel.stringValue = "Type the six digits the installer printed on “\(chosen?.name ?? "the other Mac")”. Run the installer again if the window has closed; it prints the same code."
            codeField.isHidden = false
            codeField.stringValue = ""
            window.makeFirstResponder(codeField)
        case .away:
            titleLabel.stringValue = "Away from home (optional)"
            let ts = pairing?.tailscaleName ?? ""
            if ts.isEmpty {
                bodyLabel.stringValue = "“\(chosen?.name ?? "That Mac")” is not on Tailscale. To use the remote away from home, install Tailscale on both Macs and sign in to the same account; the app then finds the tunnel address on its own and switches to it whenever the home network does not answer. Nothing to do if you only need it at home."
                actionButton.title = "Get Tailscale"
                actionButton.isHidden = false
            } else {
                bodyLabel.stringValue = "“\(chosen?.name ?? "That Mac")” is on Tailscale as \(ts). Install Tailscale on this Mac and sign in to the same account, and the remote will work from anywhere: it uses the home network when that answers and the tunnel when it does not."
                let installed = FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
                statusLabel.stringValue = installed ? "Tailscale is installed on this Mac." : "Tailscale is not installed on this Mac yet."
                actionButton.title = installed ? "Open Tailscale" : "Get Tailscale"
                actionButton.isHidden = false
            }
            placeButtons()
        case .curator:
            titleLabel.stringValue = "Playlist Curator (optional)"
            bodyLabel.stringValue = "The curator builds playlists from your library with a small language model that runs on this Mac through Ollama, so nothing leaves the house. It needs Ollama and two models, about 4 GB in all. Skip this and everything else still works."
            Task { await checkOllama() }
        case .done:
            titleLabel.stringValue = "All set"
            var lines = ["Home: \(draft.lanHost), port \(draft.port)."]
            if draft.host != draft.lanHost { lines.append("Away: \(draft.host) through Tailscale.") }
            lines.append(pulled ? "Curator: ready." : "Curator: not set up; File ▸ Set Up iTunes Remote… any time.")
            bodyLabel.stringValue = lines.joined(separator: "\n") + "\n\nThe settings are kept on this Mac; run the setup again from the File menu if the other Mac changes."
        }
    }

    // MARK: Actions

    @objc private func next(_ sender: Any?) {
        guard !busy else { return }
        if sender as? NSTextField === codeField, step != .pair { return }
        switch step {
        case .find: Task { await confirmDaemon() }
        case .pair: Task { await pair() }
        case .away: show(.curator)
        case .curator: show(.done)
        case .done:
            window.close()
            onFinish(draft)
        }
    }

    @objc private func skip(_ sender: Any?) {
        guard !busy else { return }
        switch step {
        case .away: show(.curator)
        case .curator: show(.done)
        default: break
        }
    }

    @objc private func back(_ sender: Any?) {
        guard !busy, let prev = Step(rawValue: step.rawValue - 1) else { return }
        show(prev)
    }

    @objc private func cancel(_ sender: Any?) {
        window.close()
        onCancel()
    }

    @objc private func action(_ sender: Any?) {
        switch step {
        case .away:
            if actionButton.title == "Open Tailscale" {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
            } else {
                NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
            }
        case .curator:
            switch actionButton.title {
            case "Get Ollama": NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!)
            case "Check Again": Task { await checkOllama() }
            default: Task { await pullModels() }
            }
        default: break
        }
    }

    @objc private func secondAction(_ sender: Any?) {
        Task { await checkOllama() }
    }

    private func setBusy(_ on: Bool, _ text: String = "") {
        busy = on
        nextButton.isEnabled = !on
        backButton.isEnabled = !on
        skipButton.isEnabled = !on
        if !text.isEmpty || on { statusLabel.stringValue = text }
    }

    // MARK: Find

    private var manualChoice: Bool { table.selectedRow < 0 || !manualHost.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    private func confirmDaemon() async {
        let typed = manualHost.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            let port = Int(manualPort.stringValue) ?? 8765
            setBusy(true, "Asking \(typed)…")
            do {
                let h = try await APIClient.hello(host: typed, port: port)
                chosen = DaemonBrowser.Found(name: h.name, host: typed, address: typed, port: h.port, itunesVersion: h.itunesVersion)
            } catch {
                setBusy(false, "No iTunes Remote daemon answered at \(typed):\(port). Is the installer done on that Mac, and are both Macs on the same network?")
                return
            }
            setBusy(false)
        } else {
            let row = table.selectedRow
            guard row >= 0, row < browser.found.count else {
                statusLabel.stringValue = "Choose a Mac from the list, or type its address."
                return
            }
            chosen = browser.found[row]
        }
        browser.stop()
        show(.pair)
    }

    // MARK: Pair

    private func pair() async {
        guard let c = chosen else { return }
        let code = codeField.stringValue.filter { $0.isNumber }
        guard code.count == 6 else {
            statusLabel.stringValue = "The code is six digits."
            return
        }
        setBusy(true, "Pairing with \(c.name)…")
        var result: PairResult?
        var lastError = ""
        var homeHost = c.host
        // The .local name first; the address it answered on if that fails.
        for host in [c.host, c.address] where result == nil {
            do {
                result = try await APIClient.pair(host: host, port: c.port, code: code)
                homeHost = host
            } catch {
                lastError = error.localizedDescription
                if (error as? APIError)?.status == 403 || (error as? APIError)?.status == 429 { break }
            }
        }
        guard let r = result else {
            setBusy(false, lastError.isEmpty ? "Could not pair." : lastError)
            return
        }
        pairing = r
        draft.lanHost = homeHost
        draft.host = r.tailscaleName.isEmpty ? homeHost : r.tailscaleName
        draft.port = c.port
        draft.token = r.token
        setBusy(false)
        show(.away)
    }

    // MARK: Curator

    private func checkOllama() async {
        let ollama = OllamaClient(baseURL: URL(string: UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434")!)
        actionButton.isHidden = false
        secondButton.isHidden = true
        progress.isHidden = true
        guard await ollama.isUp() else {
            statusLabel.stringValue = "Ollama is not running on this Mac. Install it, open it once (it stays in the menu bar), then check again."
            actionButton.title = "Get Ollama"
            secondButton.title = "Check Again"
            secondButton.isHidden = false
            placeButtons()
            return
        }
        let have = (try? await ollama.models()) ?? []
        let missing = SetupAssistant.curatorModels.filter { m in !have.contains(where: { $0 == m || $0.hasPrefix(m + ":") }) }
        if missing.isEmpty {
            pulled = true
            statusLabel.stringValue = "Ollama is running and both models are here. The curator is ready; it indexes the library the first time its page opens."
            actionButton.isHidden = true
        } else {
            statusLabel.stringValue = "Ollama is running. Still to download: \(missing.joined(separator: ", ")) (about \(missing.count == 2 ? "4 GB" : "3 GB"))."
            actionButton.title = "Download Models"
        }
        placeButtons()
    }

    private func pullModels() async {
        let ollama = OllamaClient(baseURL: URL(string: UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434")!)
        let have = (try? await ollama.models()) ?? []
        let missing = SetupAssistant.curatorModels.filter { m in !have.contains(where: { $0 == m || $0.hasPrefix(m + ":") }) }
        setBusy(true, "Downloading…")
        actionButton.isHidden = true
        progress.isHidden = false
        progress.doubleValue = 0
        for m in missing {
            do {
                try await ollama.pull(model: m) { [weak self] fraction, text in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if fraction >= 0 { self.progress.doubleValue = fraction }
                        self.statusLabel.stringValue = "\(m): \(text)"
                    }
                }
            } catch {
                setBusy(false, "Download of \(m) failed: \(error.localizedDescription)")
                actionButton.isHidden = false
                return
            }
        }
        setBusy(false)
        await checkOllama()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { browser.found.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < browser.found.count else { return nil }
        let f = browser.found[row]
        let cell = AquaTables.labelCell(tableView, id: "found", size: 12)
        let v = f.itunesVersion.isEmpty ? "" : "  —  iTunes \(f.itunesVersion)"
        cell.textField?.stringValue = "\(f.name)\(v)   (\(f.host))"
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        AquaTables.rowView(tableView, row: row, striped: true, background: .white, selection: .blue)
    }

    // MARK: Development

    /// `--setup-demo CODE`: walks every page against the real daemon, a few
    /// seconds on each, printing the page and window number so a script
    /// outside can capture them.
    func demo(code: String) {
        func announce(_ s: String) { print("step \(s) window \(window.windowNumber)"); fflush(stdout) }
        Task { @MainActor in
            announce("find")
            var waited = 0
            while browser.found.isEmpty && waited < 60 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await confirmDaemon()
            announce("pair")
            codeField.stringValue = code
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await pair()
            announce("away")
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            show(.curator)
            announce("curator")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            show(.done)
            announce("done")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            next(nil)
            print("step finished")
            fflush(stdout)
        }
    }

    // MARK: Window

    func run() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        browser.stop()
    }
}
