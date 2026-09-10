import Cocoa

/// The picker for one local model: which it is, how big a download, whether
/// it is here, and how long a turn takes on this Mac — with a Download
/// button when it is missing.
///
/// There are two of these. The Playlist Curator has its own and the radio's
/// Ask has its own, because they are not the same job: the curator reads a
/// long candidate list and chooses with taste, which rewards a bigger model,
/// while Ask turns a sentence into a handful of directory queries, which a
/// small quick one does well. So the picker is a piece of its own rather
/// than one page's furniture.
///
/// Nothing is written until `apply()`, which the Preferences window calls on
/// OK — the same bargain as every other setting in that window.
@MainActor
final class ModelChooser {
    /// The defaults key this picker writes.
    let key: String
    /// When set, the picker offers "the same as …" first, and choosing it
    /// removes the key so that other setting is followed instead.
    let follows: (key: String, label: String)?

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = AquaPushButton(title: "Download")
    private let progress = NSProgressIndicator()
    /// Which models Ollama has on disk; empty until it answers.
    private var downloaded: Set<String> = []
    private var pulling = false
    /// A word for what this picker drives, for the line underneath.
    private let purpose: String
    /// `--pick-model` and `--pick-radio-model`: preselect for a screenshot.
    private let testFlag: String

    init(key: String, purpose: String, testFlag: String, follows: (key: String, label: String)? = nil) {
        self.key = key
        self.purpose = purpose
        self.testFlag = testFlag
        self.follows = follows
    }

    /// The model this picker would use as things stand: its own setting, or
    /// the one it follows, or what suits this Mac.
    var current: String {
        if let m = UserDefaults.standard.string(forKey: key) { return m }
        if let f = follows, let m = UserDefaults.standard.string(forKey: f.key) { return m }
        return CuratorModels.recommended().model
    }

    /// Lays the row out in `v` with its top edge at `y`, and answers with
    /// the y to carry on from.
    func build(label title: String, in v: NSView, y: CGFloat, labelX: CGFloat = 20, controlX: CGFloat = 112) -> CGFloat {
        var y = y
        let l = NSTextField(labelWithString: title)
        l.font = Aqua.font(13)
        l.textColor = Theme.ink(0.2)
        l.alignment = .right
        l.frame = NSRect(x: labelX, y: y - 2, width: controlX - labelX - 8, height: 19)
        v.addSubview(l)

        popup.frame = NSRect(x: controlX, y: y - 4, width: min(360, v.bounds.width - controlX - 20), height: 24)
        popup.font = Aqua.font(12)
        popup.target = self
        popup.action = #selector(picked(_:))
        v.addSubview(popup)
        y -= 22

        note.font = Aqua.font(11)
        note.textColor = Theme.ink(0.45)
        let w = v.bounds.width - controlX - 20
        note.preferredMaxLayoutWidth = w
        // Three lines' worth, always: the line says what the model is like,
        // how long a turn takes and whether it is downloaded, and a
        // two-line box quietly cut the end off.
        note.frame = NSRect(x: controlX, y: y - 46, width: w, height: 46)
        v.addSubview(note)
        y -= 52

        downloadButton.target = self
        downloadButton.action = #selector(download(_:))
        let d = downloadButton.intrinsicContentSize
        downloadButton.frame = NSRect(x: controlX - 4, y: y - d.height, width: d.width, height: d.height)
        downloadButton.isHidden = true
        v.addSubview(downloadButton)

        progress.frame = NSRect(x: controlX + d.width + 8, y: y - d.height + 6, width: 180, height: 12)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.style = .bar
        progress.isHidden = true
        v.addSubview(progress)
        return y - d.height - 8
    }

    // MARK: Filling in

    func refresh() {
        fill()
        describe()
        Task { await self.findDownloaded() }
    }

    /// Every model this Mac has the memory for, the one it follows if it may
    /// follow one, and a trained model if the training window made one.
    private func fill() {
        guard !pulling else { return }
        let own = UserDefaults.standard.string(forKey: key)
        let recommended = CuratorModels.recommended()
        popup.removeAllItems()
        if let f = follows {
            let m = UserDefaults.standard.string(forKey: f.key) ?? recommended.model
            popup.addItem(withTitle: "The same as the \(f.label) — \(m)")
            popup.lastItem?.representedObject = ""      // empty means: follow
            popup.menu?.addItem(.separator())
        }
        for t in CuratorModels.available() {
            let gb = t.downloadGB == t.downloadGB.rounded() ? String(Int(t.downloadGB)) : String(format: "%.1f", t.downloadGB)
            var title = "\(t.name) — \(t.model), \(gb) GB"
            if t.model == recommended.model { title += " (recommended)" }
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = t.model
        }
        if let own = own, CuratorModels.tier(for: own) == nil {
            popup.addItem(withTitle: "Trained on your edits — \(own)")
            popup.lastItem?.representedObject = own
        }
        select(own ?? "")
        if let i = CommandLine.arguments.firstIndex(of: testFlag), i + 1 < CommandLine.arguments.count {
            select(CommandLine.arguments[i + 1])
        }
    }

    private func select(_ model: String) {
        if let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == model }) {
            popup.selectItem(at: i)
        }
    }

    /// The model the popup is showing: empty when it is set to follow.
    private var selection: String { (popup.selectedItem?.representedObject as? String) ?? "" }

    /// What the popup's choice would actually run.
    private var selectedModel: String {
        let s = selection
        if !s.isEmpty { return s }
        if let f = follows { return UserDefaults.standard.string(forKey: f.key) ?? CuratorModels.recommended().model }
        return CuratorModels.recommended().model
    }

    /// The line underneath: what the model is like, how long a turn takes,
    /// and whether it is on this Mac yet.
    private func describe() {
        guard !pulling else { return }
        let model = selectedModel
        var line = ""
        if let t = CuratorModels.tier(for: model) {
            line = "\(t.note.prefix(1).uppercased() + t.note.dropFirst()); \(CuratorModels.speedPhrase(t))."
        } else {
            line = "Trained on your own edits."
        }
        line = "\(purpose) \(line)"
        if downloaded.isEmpty {
            line += " Checking what is downloaded…"
        } else if downloaded.contains(model) {
            line += " Downloaded."
        } else if let t = CuratorModels.tier(for: model) {
            line += " Not downloaded yet — \(Int(t.downloadGB.rounded())) GB."
        } else {
            line += " Not downloaded yet."
        }
        note.stringValue = line
        // The button is there only when there is something to fetch; a
        // greyed-out "Downloaded" button is just furniture.
        let needed = !downloaded.isEmpty && !downloaded.contains(model)
        downloadButton.isHidden = !needed
        downloadButton.isEnabled = needed
    }

    private func findDownloaded() async {
        guard let url = await OllamaRuntime.shared.ensureRunning() else {
            note.stringValue = "No model server is running, so nothing can be downloaded or run. Advanced ▸ AI features turns this off altogether."
            downloadButton.isHidden = true
            return
        }
        let have = (try? await OllamaClient(baseURL: url).models()) ?? []
        var found = Set(CuratorModels.tiers.map { $0.model }.filter { m in
            have.contains { $0 == m || $0.hasPrefix(m + ":") }
        })
        // A trained picker counts as here too.
        let model = selectedModel
        if CuratorModels.tier(for: model) == nil, have.contains(where: { $0 == model || $0.hasPrefix(model + ":") }) {
            found.insert(model)
        }
        downloaded = found
        describe()
    }

    @objc private func picked(_ sender: Any?) { describe() }

    /// Fetches the chosen model now. Nothing else in the window acts before
    /// OK, but a download is not a setting — it is a long errand, and
    /// waiting for OK to start it would only make it longer.
    @objc private func download(_ sender: Any?) {
        guard !pulling else { return }
        let model = selectedModel
        pulling = true
        popup.isEnabled = false
        downloadButton.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = 0
        note.stringValue = "Downloading \(model)…"
        Task { [weak self] in
            guard let self = self, let url = await OllamaRuntime.shared.ensureRunning() else {
                self?.finished("The model server would not start.")
                return
            }
            do {
                try await OllamaClient(baseURL: url).pull(model: model) { [weak self] fraction, text in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if fraction >= 0 { self.progress.doubleValue = fraction }
                        self.note.stringValue = "\(model): \(text)"
                    }
                }
                self.finished(nil)
            } catch {
                self.finished("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func finished(_ problem: String?) {
        pulling = false
        popup.isEnabled = true
        progress.isHidden = true
        if let problem = problem {
            note.stringValue = problem
            downloadButton.isHidden = false
            downloadButton.isEnabled = true
            return
        }
        Task { await self.findDownloaded() }
    }

    /// Writes the choice. An empty selection means "follow the other one",
    /// which is the absence of the key rather than a value.
    func apply() {
        let s = selection
        if s.isEmpty, follows != nil {
            UserDefaults.standard.removeObject(forKey: key)
        } else if !s.isEmpty {
            UserDefaults.standard.set(s, forKey: key)
        }
    }
}
