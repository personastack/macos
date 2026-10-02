import AppKit
import PersonaStackCore
import WebKit

@MainActor
final class ChatWindowManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ChatWindowManager()
    private var windows: [String: PersonaChatWindow] = [:]
    private var scope = ""
    private let loadPages: Bool
    private let defaults: UserDefaults
    private let presentWindows: Bool
    private let mainViews = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

    init(loadPages: Bool = true, defaults: UserDefaults = .standard, presentWindows: Bool = true) {
        self.loadPages = loadPages
        self.defaults = defaults
        self.presentWindows = presentWindows
        super.init()
    }

    func register(_ view: WKWebView, appURL: URL) {
        mainViews.setObject(appURL as NSURL, forKey: view)
    }

    func unregister(_ view: WKWebView) { mainViews.removeObject(forKey: view) }

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
            if let existing = windows[persona] { if presentWindows { existing.focus() } }
            else if let url = ChatWindowCommand.popoutURL(appURL: base, personaID: persona) {
                let chat = PersonaChatWindow(url: url, loadPage: loadPages, defaults: defaults) { [weak self] in self?.windows.removeValue(forKey: persona) }
                windows[persona] = chat
                if presentWindows { chat.focus() }
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
    private(set) var presentation: PopoutWindowPresentation!
    private let url: URL
    private let onClose: () -> Void
    private var expandedSize = NSSize(width: 440, height: 676)
    private var collapsed = false
    private var disposed = false
    private var closePending = false

    init(url: URL, loadPage: Bool = true, defaults: UserDefaults = .standard, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        let config = WKWebViewConfiguration()
        PopoutWindowPresentation.advertise(in: config)
        // The native title bar owns pinning, including when the hosted page is older.
        config.userContentController.addUserScript(WKUserScript(source: """
            (() => {
                const style = document.createElement('style');
                style.textContent = '[data-desktop-pin] { display: none !important; }';
                document.head.appendChild(style);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "PersonaStackDesktop/1"
        webView = ChatWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 676),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "personastackChatWindow")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 340, height: 396)
        webView.underPageBackgroundColor = .clear
        window.contentView = webView
        presentation = PopoutWindowPresentation(window: window, webView: webView, kind: .chat, defaults: defaults)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if loadPage { webView.load(URLRequest(url: url)) }
    }

    func focus() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        presentation.invalidate()
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
        case .pin: presentation.togglePin()
        case .drag(let dx, let dy):
            guard presentation.canCollapse else { return }
            let origin = window.frame.origin
            window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y - dy))
        default: return
        }
    }

    private func resize(collapsed next: Bool) {
        guard next != collapsed, presentation.canCollapse else { return }
        let frame = window.frame
        if next { expandedSize = frame.size }
        collapsed = next
        webView.collapsed = next
        // Fence all intermediate toolbar/style frame notifications before resizing.
        if next { presentation.setCollapsed(true) }
        window.minSize = next ? NSSize(width: 72, height: 72) : NSSize(width: 340, height: 396)
        window.styleMask = next ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
        window.isOpaque = !next
        window.backgroundColor = next ? .clear : PopoutWindowPresentation.backgroundColor
        window.hasShadow = !next
        if !next { presentation.setCollapsed(false) }
        let size = next ? NSSize(width: 72, height: 72) : expandedSize
        var rect = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        rect = PopoutGeometryStore.clamp(rect, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize)
        window.setFrame(rect, display: true)
        presentation.finishResize()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { presentation.fullscreenTransitionFailed() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { presentation.fullscreenTransitionFailed() }

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

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(DesktopMediaCapturePermission.decide(
            origin: origin, frame: frame, type: type, appURL: url,
            activeView: !disposed && webView === self.webView
        ))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        WindowPresentation.presentUploadPanel(for: webView, parameters: parameters, completionHandler: completionHandler)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
    }
}

/// Public layer clipping avoids WebKit's private drawsBackground setting.
@MainActor
final class ChatWebView: WKWebView {
    var collapsed = false { didSet { needsLayout = true } }
    override func layout() {
        super.layout()
        wantsLayer = true
        if collapsed {
            let mask = CAShapeLayer()
            mask.path = CGPath(ellipseIn: bounds.insetBy(dx: 4, dy: 4), transform: nil)
            layer?.mask = mask
        } else {
            layer?.mask = nil
        }
    }
}
