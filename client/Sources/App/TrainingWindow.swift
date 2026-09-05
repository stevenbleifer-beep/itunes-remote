import AppKit

/// Controls ▸ Train Curator on My Edits…: the window that runs the
/// fine-tune from inside the app. It says what is on file, asks before
/// fetching anything, shows the run's progress, and can stop it. The run
/// itself belongs to CuratorTrainer, so closing this window does not end it.
@MainActor
final class TrainingWindow: NSObject, NSWindowDelegate {
    private static let W: CGFloat = 560, H: CGFloat = 430
    let window: NSWindow
    private let content: ChromeView
    private let trainer = CuratorTrainer.shared

    private let titleLabel = NSTextField(labelWithString: "Train the Curator on Your Edits")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(wrappingLabelWithString: "")
    private let stageLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let logScroll = NSScrollView()
    private let log = NSTextView()
    private let startButton = AquaPushButton(title: "Train", isDefault: true)
    private let stopButton = AquaPushButton(title: "Stop")
    private let revertButton = AquaPushButton(title: "Use Stock Picker")
    private let deleteButton = AquaPushButton(title: "Delete Training Data")
    private let closeButton = AquaPushButton(title: "Close")

    private var status = CuratorTrainer.Status()
    private var totalIters = 0
    private var fetchingPython = false
    private var force = false
    private var lastCheck = Date.distantPast

    override init() {
        content = ChromeView(frame: NSRect(x: 0, y: 0, width: TrainingWindow.W, height: TrainingWindow.H))
        content.gradientTop = Theme.ink(0.93)
        content.gradientBottom = Theme.ink(0.88)
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Train the Curator"
        window.contentView = content
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        build()
    }

    private func build() {
        let W = TrainingWindow.W, H = TrainingWindow.H
        titleLabel.font = Aqua.font(15, bold: true)
        titleLabel.textColor = Theme.ink(0.2)
        titleLabel.frame = NSRect(x: 24, y: H - 48, width: W - 48, height: 22)
        content.addSubview(titleLabel)

        bodyLabel.font = Aqua.font(12)
        bodyLabel.textColor = Theme.ink(0.25)
        bodyLabel.stringValue = "Every playlist you save teaches the curator: the songs you kept, the ones you took out, and what you said. "
            + "Training turns those into a picker of its own, made on this Mac from the base model Qwen 2.5 7B. "
            + "Nothing about your library leaves the Mac; only the base model and the training tools are downloaded.\n\n"
            + "A run takes several hours and keeps the graphics chip busy, so the curator answers slowly meanwhile. "
            + "It is worth running once a few hundred playlists are on file."
        bodyLabel.frame = NSRect(x: 24, y: H - 178, width: W - 48, height: 124)
        content.addSubview(bodyLabel)

        countLabel.font = Aqua.font(12, bold: true)
        countLabel.textColor = Theme.ink(0.2)
        countLabel.frame = NSRect(x: 24, y: H - 218, width: W - 48, height: 34)
        content.addSubview(countLabel)

        stageLabel.font = Aqua.font(11)
        stageLabel.textColor = Theme.ink(0.3)
        stageLabel.lineBreakMode = .byTruncatingTail
        stageLabel.frame = NSRect(x: 24, y: H - 244, width: W - 48, height: 16)
        content.addSubview(stageLabel)

        progress.style = .bar
        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 1
        progress.frame = NSRect(x: 24, y: H - 264, width: W - 48, height: 16)
        progress.isHidden = true
        content.addSubview(progress)

        log.isEditable = false
        log.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        log.textColor = Theme.ink(0.3)
        log.backgroundColor = Theme.ink(0.97)
        log.textContainerInset = NSSize(width: 4, height: 4)
        log.isVerticallyResizable = true
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.scrollerStyle = Theme.scrollerStyle
        logScroll.verticalScroller = AquaScroller()
        logScroll.borderType = .bezelBorder
        logScroll.frame = NSRect(x: 24, y: 64, width: W - 48, height: H - 264 - 72)
        content.addSubview(logScroll)

        var x = W - 24
        for b in [closeButton, startButton, stopButton] {
            b.target = self
            let w = max(84, b.intrinsicContentSize.width)
            b.frame = NSRect(x: x - w, y: 20, width: w, height: 24)
            x -= w + 8
            content.addSubview(b)
        }
        closeButton.action = #selector(close(_:))
        startButton.action = #selector(start(_:))
        stopButton.action = #selector(stop(_:))
        x = 24
        for b in [revertButton, deleteButton] {
            b.target = self
            let w = max(84, b.intrinsicContentSize.width)
            b.frame = NSRect(x: x, y: 20, width: w, height: 24)
            x += w + 8
            content.addSubview(b)
        }
        revertButton.action = #selector(revert(_:))
        deleteButton.action = #selector(deleteData(_:))

        trainer.onLine = { [weak self] l in self?.took(line: l) }
        trainer.onExit = { [weak self] code in self?.finished(code: code) }
    }

    func run() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // A run already going: show it as it stands.
        log.string = trainer.lines.joined(separator: "\n")
        scrollLog()
        Task { await refresh() }
    }

    private func refresh() async {
        status = await trainer.check()
        lastCheck = Date()
        let n = status.examples, need = status.minimum
        var s = "\(n) approved turn\(n == 1 ? "" : "s") on file"
        s += n >= need ? ". Enough to train on." : " (it wants \(need); \(need - n) more to go)."
        s += "\nThe curator uses \(status.tuned.isEmpty ? status.stock : status.tuned)"
        s += status.hasTuned ? ", trained on your edits." : ", the stock picker."
        countLabel.stringValue = s
        updateButtons()
    }

    private func updateButtons() {
        let running = trainer.isRunning
        startButton.isHidden = running
        stopButton.isHidden = !running
        revertButton.isHidden = !status.hasTuned || running
        deleteButton.isHidden = status.examples == 0 || running
        closeButton.title = running ? "Hide" : "Close"
        progress.isHidden = !running && progress.isIndeterminate
        if !running { stageLabel.stringValue = stageLabel.stringValue.isEmpty ? "" : stageLabel.stringValue }
    }

    // MARK: Starting

    @objc private func start(_ sender: Any?) {
        Task { await beginRun() }
    }

    private func beginRun() async {
        guard !trainer.isRunning else { return }
        status = await trainer.check()
        let n = status.examples, need = status.minimum
        guard n > 0 else {
            alert("Nothing to train on yet.", "Save a curated playlist or two first; every save adds the turns that led to it.")
            return
        }
        force = false
        // Few examples: allowed, said plainly.
        if n < need {
            let a = NSAlert()
            a.messageText = "Only \(n) of the \(need) it wants"
            a.informativeText = "A fine-tune on so few will not change much, and it still takes an hour or more. Train anyway to try the pipeline, or come back after more playlists are saved."
            a.addButton(withTitle: "Train Anyway")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            force = true
        }
        // Consent for what gets fetched, spelled out, before anything is.
        let a = NSAlert()
        a.messageText = "Start training?"
        var text = "This keeps the graphics chip busy for hours; the curator will answer slowly until it is done. You can stop it at any time.\n\n"
        if status.python == nil {
            text += "It needs Python 3.12 and the training library, which this Mac does not have. They will be fetched into your home folder from astral.sh and PyPI (about 700 MB, no administrator password), along with the base model from Hugging Face (about 4.5 GB the first time)."
        } else {
            text += "The training library and the base model are fetched from PyPI and Hugging Face the first time (about 5 GB); after that nothing is downloaded."
        }
        a.informativeText = text
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // The import step needs the model server up.
        guard await OllamaRuntime.shared.ensureRunning() != nil else {
            alert("No model server.", "Ollama could not be started, so the trained model would have nowhere to go.")
            return
        }
        log.string = ""
        totalIters = 0
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        progress.isHidden = false
        if status.python == nil {
            fetchingPython = true
            stageLabel.stringValue = "Fetching Python…"
            if !trainer.start(["--fetch-python"]) { alert("Could not start.", "The training script is missing from the app.") }
        } else {
            fetchingPython = false
            launchTraining()
        }
        updateButtons()
    }

    private func launchTraining() {
        stageLabel.stringValue = "Starting…"
        var args: [String] = []
        if force { args.append("--force") }
        if !trainer.start(args) { alert("Could not start.", "The training script is missing from the app.") }
        updateButtons()
    }

    // MARK: Progress

    private func took(line: String) {
        if line.hasPrefix("@@stage ") {
            stageLabel.stringValue = String(line.dropFirst(8))
            return
        }
        if line.hasPrefix("@@iters ") {
            totalIters = Int(line.dropFirst(8)) ?? 0
            if totalIters > 0 {
                progress.stopAnimation(nil)
                progress.isIndeterminate = false
                progress.doubleValue = 0
            }
            return
        }
        // mlx-lm: "Iter 37: Train loss 1.291, ..." — the bar follows it.
        if totalIters > 0, line.hasPrefix("Iter "), line.contains("Train loss"),
           let n = Int(line.dropFirst(5).prefix { $0.isNumber }) {
            progress.doubleValue = Double(n) / Double(totalIters)
            stageLabel.stringValue = "Training: step \(n) of \(totalIters)"
        }
        log.string += (log.string.isEmpty ? "" : "\n") + line
        scrollLog()
    }

    private func scrollLog() {
        log.scrollToEndOfDocument(nil)
    }

    private func finished(code: Int32) {
        if fetchingPython {
            fetchingPython = false
            if code == 0 {
                status.python = "fetched"
                launchTraining()
                return
            }
            stageLabel.stringValue = "Could not fetch Python (see the log)."
            progress.stopAnimation(nil)
            progress.isHidden = true
            updateButtons()
            return
        }
        progress.stopAnimation(nil)
        if code == 0 {
            // The script's own default name; ITR_TUNED_NAME overrides it for tests.
            let name = ProcessInfo.processInfo.environment["ITR_TUNED_NAME"] ?? "itunes-curator"
            UserDefaults.standard.set(name, forKey: "curatorModel")
            progress.isIndeterminate = false
            progress.doubleValue = 1
            stageLabel.stringValue = "Done. The curator now uses \(name), trained on your edits."
            NSSound(named: "Glass")?.play()
        } else if code == 130 || code == 143 {
            stageLabel.stringValue = "Stopped."
            progress.isHidden = true
        } else {
            stageLabel.stringValue = "Training failed (exit \(code)); the log has the reason."
            progress.isHidden = true
        }
        Task { await refresh() }
    }

    // MARK: Other buttons

    @objc private func stop(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Stop training?"
        a.informativeText = "What has been done so far is discarded; the curator keeps the picker it has."
        a.addButton(withTitle: "Stop")
        a.addButton(withTitle: "Keep Going")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        trainer.cancel()
    }

    @objc private func revert(_ sender: Any?) {
        UserDefaults.standard.set(status.stock.isEmpty ? CuratorEngine.defaultModel : status.stock, forKey: "curatorModel")
        stageLabel.stringValue = "The curator uses the stock picker again from its next question."
        Task { await refresh() }
    }

    @objc private func deleteData(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "Delete the training data?"
        a.informativeText = "The \(status.examples) approved turn\(status.examples == 1 ? "" : "s") on file are removed. Playlists already saved in iTunes, and what the curator remembers about your edits, stay."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: base.appendingPathComponent("\(AppIdentity.supportFolder)/curator/training.jsonl"))
        Task { await refresh() }
    }

    @objc private func close(_ sender: Any?) { window.close() }

    private func alert(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}
