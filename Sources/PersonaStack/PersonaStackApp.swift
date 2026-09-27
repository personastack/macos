import AppKit
import PersonaStackCore
import SwiftUI
import UserNotifications
import WebKit

@main
struct PersonaStackApp: App {
    @NSApplicationDelegateAdaptor(PersonaStackTerminationDelegate.self) private var terminationDelegate
    private let launchURL = LaunchConfiguration.url()

    init() {
        guard UserDefaults.standard.bool(forKey: "desktopControlRelayEnabled") else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        let paused = UserDefaults.standard.bool(forKey: "desktopControlRelayPaused")
        Task { @MainActor in
            _ = MainWebViewHost.shared
            UserDefaults.standard.set("", forKey: "desktopControlRelayError")
            UserDefaults.standard.set("", forKey: "desktopControlRepairError")
            do {
                if paused {
                    try await DesktopControlRuntime.shared.startPaused()
                } else {
                    try await DesktopControlRuntime.shared.resume()
                }
            } catch {
                UserDefaults.standard.set(error.localizedDescription, forKey: "desktopControlRelayError")
            }
        }
    }

    var body: some Scene {
        Window("PersonaStack", id: "personastack-main") {
            PersonaStackWebView(url: launchURL)
                .frame(minWidth: 1172, minHeight: 700)
                .background(Color(nsColor: WindowPresentation.canvasColor).ignoresSafeArea())
                .background(WindowPresentationConfigurator())
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }

        MenuBarExtra("PersonaStack Desktop", systemImage: "cursorarrow.motionlines") {
            DesktopControlMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class PersonaStackTerminationDelegate: NSObject, NSApplicationDelegate {
    private let shutdown: @MainActor () async -> Void
    private let reply: @MainActor (NSApplication) -> Void
    private let timeout: Duration
    private var terminating = false
    private var replied = false
    private var timeoutTask: Task<Void, Never>?

    override init() {
        shutdown = { await DesktopControlRuntime.shared.shutdownForQuit() }
        reply = { $0.reply(toApplicationShouldTerminate: true) }
        timeout = .seconds(10)
        super.init()
    }

    init(shutdown: @escaping @MainActor () async -> Void,
         reply: @escaping @MainActor (NSApplication) -> Void,
         timeout: Duration) {
        self.shutdown = shutdown
        self.reply = reply
        self.timeout = timeout
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await shutdown()
            finish(sender)
        }
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            finish(sender)
        }
        return .terminateLater
    }

    private func finish(_ sender: NSApplication) {
        guard !replied else { return }
        replied = true
        timeoutTask?.cancel()
        timeoutTask = nil
        reply(sender)
    }
}

/// The shell owns the authenticated concern stream for the app lifetime. A
/// hidden window retains its WebView when the visible window is closed.
@MainActor
final class MainWebViewHost {
    static let shared = MainWebViewHost(appURL: LaunchConfiguration.url())

    let webView: WKWebView
    let coordinator: PersonaStackWebView.Coordinator
    private let backgroundWindow: NSWindow
    private let requestNotifications: Bool
    private var notificationAuthorizationRequested = false

    init(appURL: URL, loadPage: Bool = true,
         requestNotifications: Bool = true,
         coordinator suppliedCoordinator: PersonaStackWebView.Coordinator? = nil) {
        let coordinator = suppliedCoordinator ?? PersonaStackWebView.Coordinator(appURL: appURL)
        let configuration = WKWebViewConfiguration()
        WindowPresentation.configureWebView(configuration)
        configuration.websiteDataStore = .default()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.userContentController.add(coordinator, name: "personastackConcern")
        configuration.userContentController.addScriptMessageHandler(ChatWindowManager.shared, contentWorld: .page, name: "personastackChat")
        configuration.userContentController.addScriptMessageHandler(StackWindowManager.shared, contentWorld: .page, name: "personastackStack")
        configuration.userContentController.addScriptMessageHandler(LocalSessionManager.shared, contentWorld: .page, name: "personastackLocalSession")
        configuration.userContentController.addScriptMessageHandler(DesktopControlSetupManager.shared, contentWorld: .page, name: "personastackDesktopControl")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.webView = webView
        ChatWindowManager.shared.register(webView, appURL: appURL)
        StackWindowManager.shared.register(webView, appURL: appURL)
        LocalSessionManager.shared.register(webView, appURL: appURL)
        DesktopControlSetupManager.shared.register(webView, appURL: appURL)

        let backgroundWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.contentView = webView
        self.coordinator = coordinator
        self.webView = webView
        self.backgroundWindow = backgroundWindow
        self.requestNotifications = requestNotifications
        if loadPage { coordinator.start(appURL) }
    }

    func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        backgroundWindow.contentView = NSView(frame: backgroundWindow.contentView?.bounds ?? .zero)
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        if requestNotifications && !notificationAuthorizationRequested {
            notificationAuthorizationRequested = true
            coordinator.requestNotificationAuthorization()
        }
    }

    func park(from container: NSView) {
        guard webView.superview === container else { return }
        webView.removeFromSuperview()
        backgroundWindow.contentView = webView
    }
}

struct WindowPresentationConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowPresentationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowPresentationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                NSApp.setActivationPolicy(.regular)
                WindowPresentation.configure(window)
            }
        }
    }
}

struct PersonaStackWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        MainWebViewHost.shared.coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        MainWebViewHost.shared.attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        MainWebViewHost.shared.attach(to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        MainWebViewHost.shared.park(from: container)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
        weak var webView: WKWebView?
        let appURL: URL
        private let scheduleNotification: (UNNotificationRequest) -> Void
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

        init(
            appURL: URL,
            configureNotificationCenter: @escaping (UNUserNotificationCenterDelegate) -> Void = { delegate in
                UNUserNotificationCenter.current().delegate = delegate
            },
            scheduleNotification: @escaping (UNNotificationRequest) -> Void = { request in
                UNUserNotificationCenter.current().add(request)
            }
        ) {
            self.appURL = appURL
            self.scheduleNotification = scheduleNotification
            super.init()
            configureNotificationCenter(self)
        }

        func start(_ url: URL) {
            webView?.load(URLRequest(url: url))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView else { return }
            start(appURL)
        }

        func requestNotificationAuthorization() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            handleConcernMessage(
                name: message.name,
                isMainFrame: message.frameInfo.isMainFrame,
                host: message.frameInfo.securityOrigin.host,
                body: message.body
            )
        }

        func handleConcernMessage(name: String, isMainFrame: Bool, host: String?, body: Any) {
            guard name == "personastackConcern",
                  isMainFrame,
                  NavigationPolicy.isAppHost(host),
                  NotificationBridge.isNewConcernEvent(body) else {
                return
            }
            postConcernNotification()
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        private func postConcernNotification() {
            let content = UNMutableNotificationContent()
            content.title = "PersonaStack"
            content.body = "A new concern needs attention."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            scheduleNotification(request)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }

            if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true,
               NavigationPolicy.isAppHost(url.host) {
                DesktopControlSetupManager.shared.invalidate(webView)
            }

            if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true,
               ["/login", "/logout"].contains(url.path) {
                ChatWindowManager.shared.invalidateSession()
                StackWindowManager.shared.invalidateSession()
                LocalSessionManager.shared.invalidateSession()
            }

            if navigationAction.targetFrame == nil {
                if NavigationPolicy.isGoogleOAuthURL(url) {
                    return .allow
                }
                NSWorkspace.shared.open(url)
                return .cancel
            }

            if NavigationPolicy.shouldOpenInDefaultBrowser(
                url,
                linkWasUserActivated: navigationAction.navigationType == .linkActivated,
                appURL: appURL
            ) {
                NSWorkspace.shared.open(url)
                return .cancel
            }

            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            navigationResponse.canShowMIMEType ? .allow : .download
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url,
                  NavigationPolicy.isGoogleOAuthURL(url) else {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }

            WindowPresentation.configureWebView(configuration)
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let controller = NSViewController()
            controller.view = popup
            let window = NSWindow(contentViewController: controller)
            window.title = "Sign in with Google"
            window.setContentSize(NSSize(width: 520, height: 700))
            window.center()
            window.makeKeyAndOrderFront(nil)
            popupWindows[ObjectIdentifier(popup)] = window
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let window = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
            window.close()
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            return downloads.appendingPathComponent(suggestedFilename)
        }
    }
}
