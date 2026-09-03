import Cocoa

/// The Get Info sheet, for one track or for a whole selection.
///
/// Only fields the user actually edits are sent. With several tracks selected,
/// a field whose tracks disagree shows "Mixed" and is left alone unless typed
/// into, which is how iTunes behaved and is the safe default for a bulk edit.
@MainActor
final class InfoPanel: NSObject, NSTextFieldDelegate {

    private struct Row {
        let apiName: String
        let label: String
        let width: CGFloat
        let numeric: Bool
    }

    private static let rows: [Row] = [
        Row(apiName: "name", label: "Name:", width: 320, numeric: false),
        Row(apiName: "artist", label: "Artist:", width: 320, numeric: false),
        Row(apiName: "albumArtist", label: "Album Artist:", width: 320, numeric: false),
        Row(apiName: "album", label: "Album:", width: 320, numeric: false),
        Row(apiName: "composer", label: "Composer:", width: 320, numeric: false),
        Row(apiName: "genre", label: "Genre:", width: 220, numeric: false),
        Row(apiName: "year", label: "Year:", width: 80, numeric: true),
        Row(apiName: "trackNumber", label: "Track Number:", width: 80, numeric: true),
        Row(apiName: "discNumber", label: "Disc Number:", width: 80, numeric: true),
    ]

    let panel: NSPanel
    private let tracks: [Track]
    private var fields: [String: NSTextField] = [:]
    private var initial: [String: String] = [:]
    private var mixed: Set<String> = []
    private let compilation = NSButton(checkboxWithTitle: "Compilation", target: nil, action: nil)
    private var initialCompilation: NSControl.StateValue = .off
    private let statusLabel = NSTextField(labelWithString: "")
    private let okButton = AquaPushButton(title: "OK", isDefault: true)
    private let cancelButton = AquaPushButton(title: "Cancel")

    /// Called with the fields to write. The panel closes itself when the
    /// completion reports success.
    var onApply: ([String: Any], @escaping (String?) -> Void) -> Void = { _, done in done(nil) }
    /// Existing genres, for the genre field's autocomplete.
    var knownGenres: [String] = []

    init(tracks: [Track]) {
        self.tracks = tracks
        let rowHeight: CGFloat = 27
        let top: CGFloat = 46
        let height = top + CGFloat(InfoPanel.rows.count) * rowHeight + 34 + 52
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        content.gradientTop = NSColor(white: 0.93, alpha: 1)
        content.gradientBottom = NSColor(white: 0.88, alpha: 1)
        panel = NSPanel(contentRect: content.frame,
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content
        panel.title = tracks.count == 1 ? "Get Info" : "Multiple Item Information"
        super.init()

        // Heading
        let heading = NSTextField(labelWithString: headingText)
        heading.font = Aqua.font(13, bold: true)
        heading.lineBreakMode = .byTruncatingTail
        heading.frame = NSRect(x: 20, y: height - 34, width: 480, height: 18)
        content.addSubview(heading)

        var y = height - top - rowHeight
        for row in InfoPanel.rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = Aqua.font(12)
            label.alignment = .right
            label.frame = NSRect(x: 12, y: y + 3, width: 120, height: 18)
            content.addSubview(label)

            let field = NSTextField(string: "")
            field.font = Aqua.font(12)
            field.bezelStyle = .squareBezel
            field.frame = NSRect(x: 142, y: y, width: row.width, height: 22)
            field.delegate = self
            if row.numeric {
                let f = NumberFormatter()
                f.numberStyle = .none
                f.allowsFloats = false
                field.formatter = f
            }
            content.addSubview(field)
            fields[row.apiName] = field

            let (common, isMixed) = InfoPanel.commonValue(row.apiName, tracks)
            if isMixed {
                mixed.insert(row.apiName)
                field.placeholderString = "Mixed"
                initial[row.apiName] = ""
            } else {
                field.stringValue = common
                initial[row.apiName] = common
            }
            y -= rowHeight
        }

        // Compilation
        compilation.font = Aqua.font(12)
        compilation.frame = NSRect(x: 142, y: y + 2, width: 200, height: 20)
        compilation.allowsMixedState = tracks.count > 1
        let comps = Set(tracks.map { $0.compilation })
        if comps.count > 1 {
            compilation.state = .mixed
        } else {
            compilation.state = (comps.first ?? false) ? .on : .off
        }
        initialCompilation = compilation.state
        content.addSubview(compilation)

        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(white: 0.35, alpha: 1)
        statusLabel.frame = NSRect(x: 20, y: 20, width: 300, height: 16)
        content.addSubview(statusLabel)

        okButton.target = self
        okButton.action = #selector(apply)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let ok = okButton.intrinsicContentSize
        okButton.frame = NSRect(x: 520 - 16 - ok.width, y: 14, width: ok.width, height: ok.height)
        let cc = cancelButton.intrinsicContentSize
        cancelButton.frame = NSRect(x: okButton.frame.minX - cc.width - 2, y: 14, width: cc.width, height: cc.height)
        content.addSubview(okButton)
        content.addSubview(cancelButton)

        panel.initialFirstResponder = fields["name"]
    }

    private var headingText: String {
        if tracks.count == 1 {
            let t = tracks[0]
            return t.name.isEmpty ? "Untitled" : t.name
        }
        let albums = Set(tracks.map { $0.album }).count
        let artists = Set(tracks.map { $0.displayArtist }).count
        var parts = ["\(tracks.count) tracks"]
        if artists == 1, let a = tracks.first?.displayArtist, !a.isEmpty { parts.append(a) }
        if albums == 1, let a = tracks.first?.album, !a.isEmpty { parts.append(a) }
        return parts.joined(separator: " — ")
    }

    private static func value(_ apiName: String, _ t: Track) -> String {
        switch apiName {
        case "name": return t.name
        case "artist": return t.artist
        case "albumArtist": return t.albumArtist
        case "album": return t.album
        case "composer": return ""            // not carried in the compact row
        case "genre": return t.genre
        case "year": return t.year.map(String.init) ?? ""
        case "trackNumber": return t.trackNumber.map(String.init) ?? ""
        case "discNumber": return t.discNumber.map(String.init) ?? ""
        default: return ""
        }
    }

    private static func commonValue(_ apiName: String, _ tracks: [Track]) -> (String, Bool) {
        let values = Set(tracks.map { value(apiName, $0) })
        if values.count == 1 { return (values.first ?? "", false) }
        return ("", true)
    }

    // MARK: Actions

    @objc private func cancel() {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func apply() {
        var payload: [String: Any] = [:]
        for row in InfoPanel.rows {
            guard let field = fields[row.apiName] else { continue }
            let text = field.stringValue
            // An untouched Mixed field stays untouched.
            if mixed.contains(row.apiName) && text.isEmpty { continue }
            if text == (initial[row.apiName] ?? "") { continue }
            if row.numeric {
                payload[row.apiName] = Int(text) ?? 0
            } else {
                payload[row.apiName] = text
            }
        }
        if compilation.state != initialCompilation && compilation.state != .mixed {
            payload["compilation"] = compilation.state == .on
        }
        guard !payload.isEmpty else {
            cancel()
            return
        }
        setBusy(true, "Updating \(tracks.count) track\(tracks.count == 1 ? "" : "s")…")
        onApply(payload) { [weak self] error in
            guard let self = self else { return }
            self.setBusy(false, error ?? "")
            if error == nil {
                self.panel.sheetParent?.endSheet(self.panel, returnCode: .OK)
            }
        }
    }

    private func setBusy(_ busy: Bool, _ message: String) {
        okButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        for f in fields.values { f.isEnabled = !busy }
        compilation.isEnabled = !busy
        statusLabel.stringValue = message
    }

    // MARK: Genre completion

    func control(_ control: NSControl, textView: NSTextView,
                 completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard control === fields["genre"] else { return [] }
        let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
        guard !prefix.isEmpty else { return [] }
        return knownGenres.filter { $0.lowercased().hasPrefix(prefix) }.prefix(12).map { $0 }
    }

    // MARK: Presentation

    func present(in parent: NSWindow) {
        parent.beginSheet(panel, completionHandler: nil)
    }
}
