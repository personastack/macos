import AppKit
import PersonaStackCore
import WebKit

@MainActor
final class StackWindowManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = StackWindowManager()
    private var windows: [String: StackPopoutWindow] = [:]
    private let loadPages: Bool
    private let mainViews = NSMapTable<WKWebView, NSURL>.weakToStrongObjects()

    init(loadPages: Bool = true) { self.loadPages = loadPages; super.init() }

    func register(_ view: WKWebView, appURL: URL) { mainViews.setObject(appURL as NSURL, forKey: view) }

    func invalidateSession() {
        let stale = Array(windows.values)
        windows.removeAll()
        stale.forEach { $0.dispose() }
    }

    func window(for view: StackWindowView, stackID: String) -> StackPopoutWindow? { windows[key(view, stackID: stackID)] }
    func window(forPersonaActivity personaID: String) -> StackPopoutWindow? { windows["persona-activity:\(personaID)"] }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let webView = message.webView, let base = mainViews.object(forKey: webView) as URL?,
              ChatWindowManager.trusted(message, base: base), let command = StackWindowCommand.parse(message.body) else {
            replyHandler(nil, "Invalid desktop pop-out request."); return
        }
        apply(command, base: base)
        replyHandler(["ok": true], nil)
    }

    func apply(_ command: StackWindowCommand, base: URL) {
        let windowKey: String
        let url: URL?
        let transparent: Bool
        switch command {
        case .open(let view, let stackID):
            windowKey = key(view, stackID: stackID)
            url = StackWindowCommand.popoutURL(appURL: base, stackID: stackID, view: view)
            transparent = view == .graph
        case .openPersonaActivity(let personaID):
            windowKey = "persona-activity:\(personaID)"
            url = StackWindowCommand.personaActivityURL(appURL: base, personaID: personaID)
            transparent = false
        }
        if let existing = windows[windowKey] { existing.focus(); return }
        guard let url else { return }
        let popout = StackPopoutWindow(url: url, transparent: transparent, loadPage: loadPages) { [weak self] in self?.windows.removeValue(forKey: windowKey) }
        windows[windowKey] = popout
        popout.focus()
    }

    private func key(_ view: StackWindowView, stackID: String) -> String { "\(view.rawValue):\(stackID)" }
}

@MainActor
final class StackPopoutWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let window: NSWindow
    let webView: WKWebView
    private let url: URL
    private let onClose: () -> Void
    private var disposed = false

    init(url: URL, transparent: Bool, loadPage: Bool = true, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "PersonaStackDesktop/1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        webView.underPageBackgroundColor = .clear
        // The hosted graph page and the public under-page color provide the
        // transparent canvas. Do not use private WebKit drawing controls.
        _ = transparent
        window.contentView = webView
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
        window.close()
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard !disposed else { return }
        disposed = true
        webView.stopLoading()
        onClose()
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

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let destination = action.request.url else { return .cancel }
        if destination == url && action.targetFrame?.isMainFrame == true { return .allow }
        if action.navigationType == .linkActivated, ["https", "http", "mailto"].contains(destination.scheme ?? "") {
            NSWorkspace.shared.open(destination)
        } else if action.targetFrame?.isMainFrame == true {
            dispose()
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { dispose() }
}
