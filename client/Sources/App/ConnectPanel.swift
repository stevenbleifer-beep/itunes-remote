import Cocoa

/// Modal panel for the daemon's host, port, and token.
final class ConnectPanel: NSObject {
    private let panel: NSPanel
    private let host = NSTextField(string: "")
    private let port = NSTextField(string: "")
    private let token = NSTextField(string: "")
    private var result: ServerSettings?

    init(settings: ServerSettings) {
        let content = ChromeView(frame: NSRect(x: 0, y: 0, width: 380, height: 190))
        panel = NSPanel(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Connect to iTunes"
        panel.contentView = content
        super.init()

        func label(_ s: String, y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.font = Aqua.font(13)
            l.alignment = .right
            l.frame = NSRect(x: 16, y: y, width: 70, height: 20)
            content.addSubview(l)
        }
        func field(_ f: NSTextField, y: CGFloat, value: String) {
            f.font = Aqua.font(13)
            f.stringValue = value
            f.frame = NSRect(x: 96, y: y, width: 268, height: 22)
            f.bezelStyle = .squareBezel
            content.addSubview(f)
        }
        label("Host:", y: 144); field(host, y: 143, value: settings.host)
        label("Port:", y: 110); field(port, y: 109, value: String(settings.port))
        label("Token:", y: 76); field(token, y: 75, value: settings.token)

        let cancel = AquaPushButton(title: "Cancel")
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        let connect = AquaPushButton(title: "Connect", isDefault: true)
        connect.target = self
        connect.action = #selector(connectPressed)
        let cs = connect.intrinsicContentSize
        connect.frame = NSRect(x: 380 - 16 - cs.width + 4, y: 14, width: cs.width, height: cs.height)
        let cc = cancel.intrinsicContentSize
        cancel.frame = NSRect(x: connect.frame.minX - cc.width - 4, y: 14, width: cc.width, height: cc.height)
        content.addSubview(cancel)
        content.addSubview(connect)
        panel.initialFirstResponder = host
    }

    @objc private func cancelPressed() {
        result = nil
        NSApp.stopModal()
    }

    @objc private func connectPressed() {
        result = ServerSettings(host: host.stringValue.trimmingCharacters(in: .whitespaces),
                                port: Int(port.stringValue) ?? 8765,
                                token: token.stringValue.trimmingCharacters(in: .whitespaces))
        NSApp.stopModal()
    }

    /// Runs modally. Returns nil on cancel.
    func run() -> ServerSettings? {
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }
}
