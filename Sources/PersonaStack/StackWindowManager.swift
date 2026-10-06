import AppKit
import PersonaStackCore
import WebKit

@MainActor
final class StackWindowManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = StackWindowManager()
    private var windows: [String: StackPopoutWindow] = [:]
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

    func register(_ view: WKWebView, appURL: URL) { mainViews.setObject(appURL as NSURL, forKey: view) }

    func unregister(_ view: WKWebView) { mainViews.removeObject(forKey: view) }

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
        let kind: PopoutWindowKind?
        switch command {
        case .open(let view, let stackID):
            windowKey = key(view, stackID: stackID)
            url = StackWindowCommand.popoutURL(appURL: base, stackID: stackID, view: view)
            transparent = view == .graph
            kind = view == .stream ? .stackStream : .stackGraph
        case .openPersonaActivity(let personaID):
            windowKey = "persona-activity:\(personaID)"
            url = StackWindowCommand.personaActivityURL(appURL: base, personaID: personaID)
            transparent = false
            kind = .personaActivity
        }
        if let existing = windows[windowKey] { if presentWindows { existing.focus() }; return }
        guard let url else { return }
        let popout = StackPopoutWindow(
            url: url,
            transparent: transparent,
            kind: kind,
            loadPage: loadPages,
            defaults: defaults
        ) { [weak self] in
            self?.windows.removeValue(forKey: windowKey)
        }
        windows[windowKey] = popout
        if presentWindows { popout.focus() }
    }

    private func key(_ view: StackWindowView, stackID: String) -> String { "\(view.rawValue):\(stackID)" }
}

@MainActor
final class StackPopoutWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        WindowPresentation.presentUploadPanel(for: webView, parameters: parameters, completionHandler: completionHandler)
    }

    let window: NSWindow
    let webView: WKWebView
    private(set) var presentation: PopoutWindowPresentation?
    private let url: URL
    private let onClose: () -> Void
    private var disposed = false

    init(
        url: URL,
        transparent: Bool,
        kind: PopoutWindowKind? = nil,
        loadPage: Bool = true,
        defaults: UserDefaults = .standard,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        if let kind, kind != .stackGraph { PopoutWindowPresentation.advertise(in: configuration) }
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "PersonaStackDesktop/1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        let windowType: NSWindow.Type = kind == .stackGraph ? StackGraphWindow.self : NSWindow.self
        window = windowType.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // AppKit reserves title space from button visibility when the unified
        // toolbar is installed. Showing the buttons afterward overlaps its title.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = kind == nil
        }
        webView.underPageBackgroundColor = .clear
        if transparent {
            // On macOS, underPageBackgroundColor does not suppress WebKit's
            // opaque page fill. The graph needs the page itself to stay clear.
            let setter = NSSelectorFromString("_setDrawsBackground:")
            if webView.responds(to: setter) {
                webView.setValue(false, forKey: "drawsBackground")
            }
        }
        window.contentView = webView
        window.center()
        if let kind {
            window.minSize = NSSize(width: 340, height: 396)
            presentation = PopoutWindowPresentation(window: window, webView: webView, kind: kind, defaults: defaults)
        }
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
        presentation?.invalidate()
        webView.stopLoading()
        window.close()
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard !disposed else { return }
        disposed = true
        presentation?.invalidate()
        webView.stopLoading()
        onClose()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) { presentation?.fullscreenTransitionFailed() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { presentation?.fullscreenTransitionFailed() }

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
        if action.navigationType == .linkActivated, NavigationPolicy.canOpenExternally(destination) {
            NSWorkspace.shared.open(destination)
        } else if action.targetFrame?.isMainFrame == true {
            dispose()
        }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { dispose() }
}

/// Borderless graph windows retain keyboard focus and the standard close action.
@MainActor
private final class StackGraphWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if !styleMask.contains(.titled), item.action == #selector(performClose(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func performClose(_ sender: Any?) {
        if styleMask.contains(.titled) { super.performClose(sender) }
        else { close() }
    }
}
