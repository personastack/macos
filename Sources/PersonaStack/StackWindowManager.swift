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
        let showsWindowChrome: Bool
        let chromeOverContent: Bool
        switch command {
        case .open(let view, let stackID):
            windowKey = key(view, stackID: stackID)
            url = StackWindowCommand.popoutURL(appURL: base, stackID: stackID, view: view)
            transparent = view == .graph
            showsWindowChrome = view == .stream
            chromeOverContent = false
        case .openPersonaActivity(let personaID):
            windowKey = "persona-activity:\(personaID)"
            url = StackWindowCommand.personaActivityURL(appURL: base, personaID: personaID)
            transparent = false
            showsWindowChrome = true
            chromeOverContent = true
        }
        if let existing = windows[windowKey] { existing.focus(); return }
        guard let url else { return }
        let popout = StackPopoutWindow(
            url: url,
            transparent: transparent,
            showsWindowChrome: showsWindowChrome,
            chromeOverContent: chromeOverContent,
            loadPage: loadPages
        ) { [weak self] in
            self?.windows.removeValue(forKey: windowKey)
        }
        windows[windowKey] = popout
        popout.focus()
    }

    private func key(_ view: StackWindowView, stackID: String) -> String { "\(view.rawValue):\(stackID)" }
}

@MainActor
final class StackPopoutWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let window: NSWindow
    let webView: WKWebView
    let windowChrome: StackPopoutWindowChrome?
    private let url: URL
    private let onClose: () -> Void
    private var disposed = false

    init(
        url: URL,
        transparent: Bool,
        showsWindowChrome: Bool = false,
        chromeOverContent: Bool = false,
        loadPage: Bool = true,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "PersonaStackDesktop/1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        windowChrome = showsWindowChrome ? StackPopoutWindowChrome(frame: .zero, overlaysContent: chromeOverContent) : nil
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
        if transparent {
            // On macOS, underPageBackgroundColor does not suppress WebKit's
            // opaque page fill. The graph needs the page itself to stay clear.
            let setter = NSSelectorFromString("_setDrawsBackground:")
            if webView.responds(to: setter) {
                webView.setValue(false, forKey: "drawsBackground")
            }
        }
        if let windowChrome {
            let contentView = NSView(frame: .zero)
            webView.translatesAutoresizingMaskIntoConstraints = false
            windowChrome.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(webView)
            contentView.addSubview(windowChrome)
            var constraints = [
                windowChrome.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                windowChrome.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                windowChrome.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ]
            constraints.append(windowChrome.heightAnchor.constraint(equalToConstant: chromeOverContent ? 48 : 36))
            constraints.append(webView.topAnchor.constraint(equalTo: chromeOverContent ? contentView.topAnchor : windowChrome.bottomAnchor))
            NSLayoutConstraint.activate(constraints)
            windowChrome.closeButton.target = self
            windowChrome.closeButton.action = #selector(closeWindow)
            window.contentView = contentView
        } else {
            window.contentView = webView
        }
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

    @objc private func closeWindow() {
        window.performClose(nil)
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

@MainActor
final class StackPopoutWindowChrome: NSView {
    let closeButton: NSButton

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    init(frame frameRect: NSRect, overlaysContent: Bool) {
        let symbol = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close window"
        ) ?? NSImage()
        symbol.isTemplate = true
        closeButton = NSButton(image: symbol, target: nil, action: nil)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = overlaysContent
            ? NSColor.clear.cgColor
            : NSColor(srgbRed: 18.0 / 255, green: 18.0 / 255, blue: 42.0 / 255, alpha: 1).cgColor
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityLabel("Close window")
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
