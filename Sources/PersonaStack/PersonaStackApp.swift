import AppKit
import PersonaStackCore
import SwiftUI
import UserNotifications
import WebKit

@main
struct PersonaStackApp: App {
    @NSApplicationDelegateAdaptor(PersonaStackTerminationDelegate.self) private var terminationDelegate
    @ObservedObject private var serverSettings = DesktopEnvironmentSettings.shared
    private let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage()
        image.size = NSSize(width: 21.6, height: 21.6)
        return image
    }()
    init() {
        let foregroundUpdateRelaunch = UserDefaults.standard.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        guard let configuration = try? LaunchConfiguration.selectedEnvironment(),
              UserDefaults.standard.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(configuration)) else { return }
        if DesktopUpdatePolicy.shouldUseAccessoryActivation(relayEnabled: true,
                                                            foregroundUpdateRelaunch: foregroundUpdateRelaunch) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        let paused = UserDefaults.standard.bool(forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
        Task { @MainActor in
            _ = MainWebViewHost.shared
            await DesktopControlRuntime.shared.startAtLaunch(configuration: configuration, paused: paused)
        }
    }

    var body: some Scene {
        Window("PersonaStack", id: "personastack-main") {
            ZStack(alignment: .topTrailing) {
                PersonaStackWebView(url: serverSettings.appPageURL)
                    .id(serverSettings.generation)
                    .frame(minWidth: 1172, minHeight: 700)
                    .background(Color(nsColor: WindowPresentation.canvasColor).ignoresSafeArea())
                    .background(WindowPresentationConfigurator(applicationDelegate: terminationDelegate))
                DesktopUpdateToast()
                    .padding(18)
            }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
        .commands {
            DesktopServerSettingsCommands()
            DesktopUpdateCommands()
            CommandGroup(after: .toolbar) {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }

        MenuBarExtra {
            DesktopControlMenu()
            DesktopUpdatesMenuSection()
        } label: {
            Image(nsImage: menuBarIcon)
                .renderingMode(.original)
                .accessibilityLabel("PersonaStack Desktop")
        }
        .menuBarExtraStyle(.menu)

        Window("PersonaStack Servers", id: "desktop-server-settings") {
            DesktopServerSettingsWindow()
        }
        .defaultSize(width: 600, height: 480)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class PersonaStackTerminationDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (@MainActor () -> Void)?
    private var shouldRestoreMainWindowAfterUpdate = false
    private let shutdown: @MainActor () async -> Void
    private let reply: @MainActor (NSApplication) -> Void
    private let timeout: Duration
    private var terminating = false
    private var replied = false
    private var timeoutTask: Task<Void, Never>?

    override init() {
        shutdown = {
            await LocalRunManager.shared.shutdown()
            await DesktopControlRuntime.shared.shutdownForQuit()
        }
        reply = { $0.reply(toApplicationShouldTerminate: true) }
        timeout = .seconds(10)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DesktopLoginItemRegistration.enableOnFirstLaunch()
        DesktopNotificationCoordinator.shared.install()
        DesktopUpdater.shared.start()
        guard UserDefaults.standard.bool(forKey: DesktopUpdater.foregroundUpdateRelaunchKey) else { return }
        UserDefaults.standard.removeObject(forKey: DesktopUpdater.foregroundUpdateRelaunchKey)
        shouldRestoreMainWindowAfterUpdate = true
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor [weak self] in
            await Task.yield()
            NSApp.activate(ignoringOtherApps: true)
            self?.restoreMainWindowAfterUpdateIfNeeded()
        }
    }

    func installMainWindowReopener(_ action: @escaping @MainActor () -> Void) {
        reopenMainWindow = action
        restoreMainWindowAfterUpdateIfNeeded()
    }

    private func restoreMainWindowAfterUpdateIfNeeded() {
        guard shouldRestoreMainWindowAfterUpdate, let reopenMainWindow else { return }
        shouldRestoreMainWindowAfterUpdate = false
        reopenMainWindow()
    }

    init(shutdown: @escaping @MainActor () async -> Void,
         reply: @escaping @MainActor (NSApplication) -> Void,
         timeout: Duration) {
        self.shutdown = shutdown
        self.reply = reply
        self.timeout = timeout
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let reopenMainWindow else { return true }
        reopenMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating { DesktopUpdater.shared.applicationWillTerminate() }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await shutdown()
            finish(sender)
        }
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !LocalRunManager.shared.hasActiveSessions else { return }
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
    private(set) static var shared = MainWebViewHost(appURL: LaunchConfiguration.selectedURL())

    static func replaceSharedHost(with appURL: URL) -> MainWebViewHost {
        let oldHost = shared
        oldHost.retire()
        let newHost = MainWebViewHost(appURL: appURL)
        shared = newHost
        return oldHost
    }

    static func showMainWindow(openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { $0.title == "PersonaStack" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showServerSettingsWindow(openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

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
        configuration.userContentController.addScriptMessageHandler(LocalRunManager.shared, contentWorld: .page, name: "personastackLocalRun")
        configuration.userContentController.addScriptMessageHandler(DesktopControlSetupManager.shared, contentWorld: .page, name: "personastackDesktopControl")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.webView = webView
        ChatWindowManager.shared.register(webView, appURL: appURL)
        StackWindowManager.shared.register(webView, appURL: appURL)
        LocalSessionManager.shared.register(webView, appURL: appURL)
        LocalRunManager.shared.register(webView, appURL: appURL)
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
            DesktopNotificationCoordinator.shared.requestAuthorization()
        }
    }

    func retire() {
        ChatWindowManager.shared.unregister(webView)
        StackWindowManager.shared.unregister(webView)
        LocalSessionManager.shared.invalidate(webView)
        LocalRunManager.shared.invalidate(webView)
        DesktopControlSetupManager.shared.unregister(webView)
        coordinator.retire()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for name in ["personastackConcern", "personastackChat", "personastackStack", "personastackLocalSession", "personastackLocalRun", "personastackDesktopControl"] {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.removeFromSuperview()
        backgroundWindow.contentView = nil
        coordinator.webView = nil
    }

    func park(from container: NSView) {
        guard webView.superview === container else { return }
        webView.removeFromSuperview()
        backgroundWindow.contentView = webView
    }
}

struct WindowPresentationConfigurator: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let applicationDelegate: PersonaStackTerminationDelegate

    func makeNSView(context: Context) -> NSView {
        let action = openWindow
        applicationDelegate.installMainWindowReopener {
            MainWebViewHost.showMainWindow { action(id: "personastack-main") }
        }
        return WindowPresentationView()
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
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let appURL: URL
        private let scheduleNotification: (UNNotificationRequest) -> Void
        private let cancelPermissionVerification: () -> Void
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
        private(set) var isRetired = false
        private(set) var documentGeneration = UUID()

        init(
            appURL: URL,
            notificationCoordinator: UNUserNotificationCenterDelegate? = DesktopNotificationCoordinator.shared,
            configureNotificationCenter: @escaping (UNUserNotificationCenterDelegate) -> Void = { delegate in
                UNUserNotificationCenter.current().delegate = delegate
            },
            scheduleNotification: @escaping (UNNotificationRequest) -> Void = { request in
                UNUserNotificationCenter.current().add(request)
            },
            cancelPermissionVerification: @escaping () -> Void = {
                DesktopPermissionChecklist.shared.cancelVerification()
            }
        ) {
            self.appURL = appURL
            self.scheduleNotification = scheduleNotification
            self.cancelPermissionVerification = cancelPermissionVerification
            super.init()
            if let notificationCoordinator {
                configureNotificationCenter(notificationCoordinator)
            }
        }

        func start(_ url: URL) {
            webView?.load(URLRequest(url: url))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView else { return }
            invalidateDocumentVerification()
            start(appURL)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === self.webView else { return }
            invalidateDocumentVerification()
        }

        private func invalidateDocumentVerification() {
            documentGeneration = UUID()
            cancelPermissionVerification()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            handleConcernMessage(
                name: message.name,
                isMainFrame: message.frameInfo.isMainFrame,
                host: message.frameInfo.securityOrigin.host,
                body: message.body,
                appURL: Self.url(for: message.frameInfo.securityOrigin)
            )
        }

        func handleConcernMessage(name: String, isMainFrame: Bool, host: String?, body: Any, appURL messageURL: URL? = nil) {
            guard !isRetired,
                  name == "personastackConcern",
                  isMainFrame,
                  host?.lowercased() == self.appURL.host?.lowercased(),
                  messageURL.map({ ChatWindowCommand.sameOrigin($0, self.appURL) }) == true,
                  NotificationBridge.isNewConcernEvent(body) else {
                return
            }
            postConcernNotification()
        }

    private static func url(for origin: WKSecurityOrigin) -> URL? {
            var parts = URLComponents()
            parts.scheme = origin.protocol
            parts.host = origin.host
            if origin.port > 0 { parts.port = origin.port }
            return parts.url
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
            guard !isRetired else { return .cancel }
            guard let url = navigationAction.request.url else {
                return .cancel
            }

            if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true,
               ChatWindowCommand.sameOrigin(url, appURL) {
                DesktopControlSetupManager.shared.invalidate(webView)
            }

            if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true,
               ["/login", "/logout"].contains(url.path) {
                ChatWindowManager.shared.invalidateSession()
                StackWindowManager.shared.invalidateSession()
                LocalSessionManager.shared.invalidateSession()
                LocalRunManager.shared.invalidateSession()
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

        func retire() {
            guard !isRetired else { return }
            isRetired = true
            invalidateDocumentVerification()
            for window in popupWindows.values {
                if let popup = window.contentViewController?.view as? WKWebView {
                    popup.stopLoading()
                    popup.navigationDelegate = nil
                    popup.uiDelegate = nil
                    for name in ["personastackConcern", "personastackChat", "personastackStack", "personastackLocalSession", "personastackDesktopControl"] {
                        popup.configuration.userContentController.removeScriptMessageHandler(forName: name)
                    }
                }
                window.close()
            }
            popupWindows.removeAll()
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            decisionHandler(DesktopMediaCapturePermission.decide(
                origin: origin, frame: frame, type: type, appURL: appURL,
                activeView: !isRetired && webView === self.webView
            ))
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
            WindowPresentation.presentUploadPanel(for: webView, parameters: parameters, completionHandler: completionHandler)
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
