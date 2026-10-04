import AppKit
import WebKit

@MainActor
final class MainWindowNavigation: NSTitlebarAccessoryViewController {
    let refreshButton = NSButton()
    let backButton = NSButton()
    let forwardButton = NSButton()
    private weak var webView: WKWebView?
    private var historyObservations: [NSKeyValueObservation] = []

    static func install(on window: NSWindow, webView: WKWebView) {
        if let navigation = window.titlebarAccessoryViewControllers.compactMap({ $0 as? MainWindowNavigation }).first {
            navigation.bind(to: webView)
            return
        }
        let navigation = MainWindowNavigation()
        navigation.bind(to: webView)
        window.addTitlebarAccessoryViewController(navigation)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        let controls = NSStackView(views: [refreshButton, backButton, forwardButton])
        controls.orientation = .horizontal
        controls.spacing = 2
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        controls.frame = NSRect(x: 0, y: 0, width: 88, height: 22)
        view = controls
        configure(refreshButton, symbol: "arrow.clockwise", label: "Refresh", action: #selector(refreshPage))
        configure(backButton, symbol: "chevron.left", label: "Back", action: #selector(goBack))
        configure(forwardButton, symbol: "chevron.right", label: "Forward", action: #selector(goForward))
    }

    required init?(coder: NSCoder) { return nil }

    func bind(to webView: WKWebView) {
        guard self.webView !== webView else { return }
        historyObservations.removeAll()
        self.webView = webView
        historyObservations = [
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateAvailability() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateAvailability() }
            },
        ]
        updateAvailability()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("main-navigation-\(label.lowercased())")
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func updateAvailability() {
        refreshButton.isEnabled = webView != nil
        backButton.isEnabled = webView?.canGoBack == true
        forwardButton.isEnabled = webView?.canGoForward == true
    }

    @objc private func refreshPage() {
        webView?.reload()
    }

    @objc private func goBack() {
        guard let webView, webView.canGoBack else { return }
        webView.goBack()
    }

    @objc private func goForward() {
        guard let webView, webView.canGoForward else { return }
        webView.goForward()
    }
}
