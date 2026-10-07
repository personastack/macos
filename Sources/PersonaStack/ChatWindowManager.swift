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
    var navigateMainWindow: (URL) -> Void = { _ in }

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
                let chat = PersonaChatWindow(url: url, loadPage: loadPages, defaults: defaults,
                    navigateMainWindow: { [weak self] in self?.navigateMainWindow($0) }) { [weak self] in self?.windows.removeValue(forKey: persona) }
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
    private let navigateMainWindow: (URL) -> Void
    private var expandedSize = NSSize(width: 440, height: 676)
    private var collapsed = false
    private var disposed = false
    private var closePending = false
    private var documentGeneration = UUID()
    private let mediaPermission = DesktopMediaCapturePermission.shared
    init(url: URL, loadPage: Bool = true, defaults: UserDefaults = .standard,
         navigateMainWindow: @escaping (URL) -> Void = { _ in },
         onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        self.navigateMainWindow = navigateMainWindow
        let config = WKWebViewConfiguration()
        PopoutWindowPresentation.advertise(in: config)
        config.userContentController.addUserScript(WKUserScript(
            source: "window.personastackDesktopPersonaSettings = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: DesktopMediaCapturePermission.bridgeName)
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
        guard !disposed, !closePending else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        mediaPermission.cancel(owner: documentGeneration)
        webView.setMicrophoneCaptureState(.none)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: DesktopMediaCapturePermission.bridgeName, contentWorld: .page)
        presentation.invalidate()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "personastackChatWindow", contentWorld: .page)
        if !closePending {
            window.close()
            onClose()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if disposed { return true }
        closePending = true
        // Closing a view never asks hosted JavaScript to close shared product state.
        dispose()
        onClose()
        return true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { dispose() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { dispose() }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        navigationResponsePolicy(isMainFrame: response.isForMainFrame, response: response.response,
                                 canShowMIMEType: response.canShowMIMEType)
    }

    func navigationResponsePolicy(isMainFrame: Bool, response: URLResponse,
                                  canShowMIMEType: Bool) -> WKNavigationResponsePolicy {
        if isMainFrame, let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            dispose()
            return .cancel
        }
        return canShowMIMEType ? .allow : .cancel
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        if message.name == DesktopMediaCapturePermission.bridgeName {
            let owner = documentGeneration
            mediaPermission.handleMessage(message.body, owner: owner,
                trusted: DesktopMediaCapturePermission.trusted(origin: message.frameInfo.securityOrigin,
                                                              frame: message.frameInfo, appURL: url),
                isCurrent: { [weak self, weak view = message.webView] in
                    guard let self, let view else { return false }
                    return !self.disposed && !self.closePending && view === self.webView && self.documentGeneration == owner
                }, reply: replyHandler)
            return
        }
        guard message.webView === webView, ChatWindowManager.trusted(message, base: url),
              let command = ChatWindowCommand.parse(message.body, main: false) else {
            replyHandler(nil, "Invalid chat window request."); return
        }
        apply(command)
        replyHandler(["ok": true, "collapsed": collapsed, "pinned": window.level == .floating], nil)
    }

    func apply(_ command: ChatWindowCommand) {
        if command == .close { dispose(); return }
        guard !disposed, !closePending else { return }
        switch command {
        case .minimize: window.miniaturize(nil)
        case .collapse: resize(collapsed: true)
        case .expand: resize(collapsed: false)
        case .pin: presentation.togglePin()
        case .settings:
            if let destination = ChatWindowCommand.settingsURL(popoutURL: url) {
                navigateMainWindow(destination)
            }
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
        if NavigationPolicy.shouldDownload(destination, requested: action.shouldPerformDownload, appURL: url) { return .download }
        if destination == url && action.targetFrame?.isMainFrame == true { return .allow }
        if action.navigationType == .linkActivated, NavigationPolicy.canOpenExternally(destination) {
            NSWorkspace.shared.open(destination)
        } else if action.targetFrame?.isMainFrame == true {
            // Includes a session-expiry redirect. Never display a login page over a stale transcript.
            dispose()
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        mediaPermission.cancel(owner: documentGeneration)
        documentGeneration = UUID()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { dispose() }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let owner = documentGeneration
        mediaPermission.decide(origin: origin, frame: frame, type: type, appURL: url,
            owner: owner, isCurrent: { [weak self, weak webView] in
                guard let self, let webView else { return false }
                return !self.disposed && !self.closePending && webView === self.webView && self.documentGeneration == owner
            }, completion: decisionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        WindowPresentation.presentUploadPanel(for: webView, parameters: parameters, completionHandler: completionHandler)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        return DesktopDownloadDestination.choose(suggestedFilename: suggestedFilename, directory: downloads)
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
