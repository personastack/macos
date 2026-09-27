import AppKit
import PersonaStackCore
import WebKit

@MainActor
final class ChatWindowManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ChatWindowManager()
    private var windows: [String: PersonaChatWindow] = [:]
    private var scope = ""
    private let loadPages: Bool
    private let mainViews = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

    init(loadPages: Bool = true) { self.loadPages = loadPages; super.init() }

    func register(_ view: WKWebView, appURL: URL) {
        mainViews.setObject(appURL as NSURL, forKey: view)
    }

    func invalidateSession() { sync("") }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let base = mainViews.object(forKey: view) as URL?,
              Self.trusted(message, base: base),
              let command = ChatWindowCommand.parse(message.body, main: true) else {
            replyHandler(nil, "Invalid desktop chat request."); return
        }
        apply(command, base: base)
        replyHandler(["ok": true], nil)
    }

    func chat(for persona: String) -> PersonaChatWindow? { windows[persona] }

    func apply(_ command: ChatWindowCommand, base: URL) {
        switch command {
        case .sync(let next): sync(next)
        case .open(let persona, let next):
            sync(next)
            if let existing = windows[persona] { existing.focus() }
            else if let url = ChatWindowCommand.popoutURL(appURL: base, personaID: persona) {
                let chat = PersonaChatWindow(url: url, loadPage: loadPages) { [weak self] in self?.windows.removeValue(forKey: persona) }
                windows[persona] = chat
                chat.focus()
            }
        default: return
        }
    }

    private func sync(_ next: String) {
        guard next != scope else { return }
        let stale = Array(windows.values)
        windows.removeAll()
        for chat in stale { chat.dispose() }
        scope = next
    }

    static func trusted(_ message: WKScriptMessage, base: URL) -> Bool {
        let origin = message.frameInfo.securityOrigin
        return ChatWindowCommand.permitsBridge(scheme: origin.protocol, host: origin.host, port: origin.port,
                                               mainFrame: message.frameInfo.isMainFrame, appURL: base)
    }
}

@MainActor
final class PersonaChatWindow: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    let window: NSWindow
    let webView: ChatWebView
    let titleBar: ChatWindowTitleBar
    private let seamFill: NSView
    private let url: URL
    private let onClose: () -> Void
    private var titleBarHeight: NSLayoutConstraint?
    private var expandedSize = NSSize(width: 440, height: 676)
    private var collapsed = false
    private var disposed = false
    private var closePending = false

    init(url: URL, loadPage: Bool = true, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "PersonaStackDesktop/1"
        webView = ChatWebView(frame: .zero, configuration: config)
        titleBar = ChatWindowTitleBar(frame: .zero)
        seamFill = NSView(frame: .zero)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 676),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "personastackChatWindow")
        window.title = "Persona chat"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 340, height: 396)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        titleBar.pinButton.target = self
        titleBar.pinButton.action = #selector(togglePin(_:))
        webView.underPageBackgroundColor = .clear
        let contentView = NSView(frame: .zero)
        seamFill.wantsLayer = true
        seamFill.layer?.backgroundColor = ChatWindowTitleBar.backgroundColor.cgColor
        seamFill.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(seamFill)
        contentView.addSubview(webView)
        contentView.addSubview(titleBar)
        let barHeight = titleBar.heightAnchor.constraint(equalToConstant: 40)
        let contentTop = webView.topAnchor.constraint(equalTo: titleBar.bottomAnchor)
        titleBarHeight = barHeight
        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            barHeight,
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentTop,
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            seamFill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            seamFill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            seamFill.topAnchor.constraint(equalTo: webView.topAnchor),
            seamFill.heightAnchor.constraint(equalToConstant: 56),
        ])
        window.contentView = contentView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.center()
        if loadPage { webView.load(URLRequest(url: url)) }
    }

    func focus() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "personastackChatWindow", contentWorld: .page)
        window.close()
        onClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if disposed { return true }
        closePending = true
        if !webView.isLoading { requestHostedClose() }
        return false
    }

    private func requestHostedClose() {
        webView.evaluateJavaScript("typeof window.personastackDesktopClose === 'function' ? (window.personastackDesktopClose(), true) : false") { [weak self] value, _ in
            guard let self, !self.disposed else { return }
            if value as? Bool != true && !self.webView.isLoading { self.dispose() }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if closePending { requestHostedClose() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { dispose() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { dispose() }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            dispose()
            return .cancel
        }
        return response.canShowMIMEType ? .allow : .cancel
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.webView === webView, ChatWindowManager.trusted(message, base: url),
              let command = ChatWindowCommand.parse(message.body, main: false) else {
            replyHandler(nil, "Invalid chat window request."); return
        }
        apply(command)
        replyHandler(["ok": true, "collapsed": collapsed, "pinned": window.level == .floating], nil)
    }

    func apply(_ command: ChatWindowCommand) {
        switch command {
        case .minimize: window.miniaturize(nil)
        case .close: dispose()
        case .collapse: resize(collapsed: true)
        case .expand: resize(collapsed: false)
        case .pin:
            window.level = window.level == .normal ? .floating : .normal
            titleBar.setPinned(window.level == .floating)
        case .drag(let dx, let dy):
            let origin = window.frame.origin
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy))
        default: return
        }
    }

    @objc private func togglePin(_ sender: NSButton) { apply(.pin) }

    private func resize(collapsed next: Bool) {
        guard next != collapsed else { return }
        let frame = window.frame
        if next { expandedSize = frame.size }
        collapsed = next
        webView.collapsed = next
        seamFill.isHidden = next
        titleBarHeight?.constant = next ? 0 : 40
        titleBar.isHidden = next
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            window.standardWindowButton(button)?.isHidden = next
        }
        window.minSize = next ? NSSize(width: 72, height: 72) : NSSize(width: 340, height: 396)
        if next { window.styleMask.remove(.resizable) } else { window.styleMask.insert(.resizable) }
        let size = next ? NSSize(width: 72, height: 72) : expandedSize
        var rect = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        if let screen = window.screen?.visibleFrame {
            rect.origin.x = max(screen.minX, min(rect.minX, screen.maxX - rect.width))
            rect.origin.y = max(screen.minY, min(rect.minY, screen.maxY - rect.height))
        }
        window.setFrame(rect, display: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let destination = action.request.url else { return .cancel }
        if action.shouldPerformDownload, destination.scheme == "blob" { return .download }
        if destination == url && action.targetFrame?.isMainFrame == true { return .allow }
        if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(destination.scheme ?? "") {
            NSWorkspace.shared.open(destination)
        } else if action.targetFrame?.isMainFrame == true {
            // Includes a session-expiry redirect. Never display a login page over a stale transcript.
            dispose()
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { dispose() }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
    }
}

@MainActor
final class ChatWindowTitleBar: NSView {
    static let backgroundColor = NSColor(srgbRed: 18.0 / 255, green: 18.0 / 255, blue: 42.0 / 255, alpha: 1)
    let pinButton = NSButton(frame: .zero)
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        pinButton.isBordered = false
        pinButton.setButtonType(.momentaryChange)
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Always on top")
        pinButton.imagePosition = .imageOnly
        pinButton.contentTintColor = .lightGray
        pinButton.toolTip = "Always on top"
        pinButton.setAccessibilityLabel("Always on top")
        pinButton.wantsLayer = true
        pinButton.layer?.cornerRadius = 14
        pinButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinButton)
        NSLayoutConstraint.activate([
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 28),
            pinButton.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPinned(_ pinned: Bool) {
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Always on top")
        pinButton.contentTintColor = pinned ? .white : .lightGray
        pinButton.layer?.backgroundColor = pinned ? NSColor(srgbRed: 52.0 / 255, green: 93.0 / 255, blue: 85.0 / 255, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.04).cgColor
        pinButton.setAccessibilityValue(pinned ? "On" : "Off")
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Public layer clipping avoids WebKit's private drawsBackground setting.
@MainActor
final class ChatWebView: WKWebView {
    var collapsed = false { didSet { needsLayout = true } }
    override func layout() {
        super.layout()
        wantsLayer = true
        let mask = CAShapeLayer()
        if collapsed {
            mask.path = CGPath(ellipseIn: bounds.insetBy(dx: 4, dy: 4), transform: nil)
        } else {
            let rect = NSRect(x: 0, y: 4, width: bounds.width, height: bounds.height - 4)
            let path = CGMutablePath()
            path.addRoundedRect(in: rect, cornerWidth: 12, cornerHeight: 12)
            path.addRect(CGRect(x: rect.minX, y: rect.maxY - 12, width: rect.width, height: 12))
            mask.path = path
        }
        layer?.mask = mask
    }
}
