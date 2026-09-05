import Cocoa

/// A one-field Aqua sheet, used for naming a new playlist.
@MainActor
final class NamePrompt: NSObject {
    let panel: NSPanel
    private let field = NSTextField(string: "")
    private let okButton: AquaPushButton
    private let cancelButton = AquaPushButton(title: "Cancel")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Called with the entered name. Report an error string to keep the sheet
    /// open, or nil to close it.
    var onAccept: (String, @escaping (String?) -> Void) -> Void = { _, done in done(nil) }

    init(title: String, prompt: String, placeholder: String, acceptTitle: String, initialValue: String? = nil) {
        okButton = AquaPushButton(title: acceptTitle, isDefault: true)
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        content.gradientTop = Theme.ink(0.93)
        content.gradientBottom = Theme.ink(0.88)
        let sheet = PromptPanel(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel = sheet
        panel.contentView = content
        panel.title = title
        super.init()
        sheet.onCancel = { [weak self] in self?.cancel() }

        let label = NSTextField(labelWithString: prompt)
        label.font = Aqua.font(13, bold: true)
        label.frame = NSRect(x: 20, y: 104, width: 380, height: 18)
        content.addSubview(label)

        field.font = Aqua.font(13)
        field.bezelStyle = .squareBezel
        field.placeholderString = placeholder
        // Return in the field creates; the drawn buttons have no key
        // equivalents of their own.
        field.target = self
        field.action = #selector(accept)
        field.frame = NSRect(x: 20, y: 72, width: 380, height: 24)
        if let v = initialValue { field.stringValue = v }
        content.addSubview(field)

        statusLabel.font = Aqua.font(11)
        statusLabel.textColor = NSColor(srgbRed: 0.6, green: 0.1, blue: 0.1, alpha: 1)
        statusLabel.frame = NSRect(x: 20, y: 20, width: 250, height: 16)
        content.addSubview(statusLabel)

        okButton.target = self
        okButton.action = #selector(accept)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let ok = okButton.intrinsicContentSize
        okButton.frame = NSRect(x: 420 - 16 - ok.width, y: 14, width: ok.width, height: ok.height)
        let cc = cancelButton.intrinsicContentSize
        cancelButton.frame = NSRect(x: okButton.frame.minX - cc.width - 2, y: 14, width: cc.width, height: cc.height)
        content.addSubview(okButton)
        content.addSubview(cancelButton)
        panel.initialFirstResponder = field
    }

    /// Called when the sheet is dismissed without a name.
    var onCancel: () -> Void = {}

    @objc private func cancel() {
        onCancel()
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func accept() {
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusLabel.stringValue = "Enter a name."
            return
        }
        okButton.isEnabled = false
        cancelButton.isEnabled = false
        field.isEnabled = false
        statusLabel.stringValue = ""
        onAccept(name) { [weak self] error in
            guard let self = self else { return }
            self.okButton.isEnabled = true
            self.cancelButton.isEnabled = true
            self.field.isEnabled = true
            if let error = error {
                self.statusLabel.stringValue = error
            } else {
                self.panel.sheetParent?.endSheet(self.panel, returnCode: .OK)
            }
        }
    }

    func present(in parent: NSWindow) {
        parent.beginSheet(panel, completionHandler: nil)
    }
}

/// Escape closes the sheet, as it does every other sheet.
final class PromptPanel: NSPanel {
    var onCancel: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
