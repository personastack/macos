import AppKit
import PersonaStackCore
import SwiftUI
import UserNotifications
import WebKit

@main
@MainActor
enum DesktopEntryPoint {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--personastack-unregister-login"] {
            do { try DesktopLoginItemRegistration.unregisterForUninstall() }
            catch {
                fputs("PersonaStack could not unregister Login Items. Quit PersonaStack and retry uninstall.\n", stderr)
                exit(1)
            }
            return
        }
        if DesktopCrashRecoverySupervisor.dispatchSupervisorIfRequested() { return }
        if CommandLine.arguments.contains("--personastack-permission-diagnostics") {
            DesktopAccessibilityPermission.printDiagnostics()
            return
        }
        if !CommandLine.arguments.contains(DesktopCrashRecoverySupervisor.recoveryLaunchArgument) {
            DesktopCrashRecoveryPolicy.resumeAfterExplicitLaunch()
        }
        guard DesktopApplicationInstanceLock.acquireOrActivateExisting() else { return }
        PersonaStackApp.main()
    }
}

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
            || DesktopApplicationRestart.resumesPermissionSetup
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
                    .overlay {
                        MainWebViewLoadRecoveryOverlay(coordinator: MainWebViewHost.shared.coordinator)
                    }
                DesktopUpdateToast()
                    .padding(18)
            }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
        .commands {
            DesktopServerSettingsCommands()
            DesktopUpdateCommands()
            CommandGroup(replacing: .appTermination) {
                Button("Close to Menu Bar") {
                    terminationDelegate.closeToMenuBar(NSApp)
                }
                .keyboardShortcut("q", modifiers: [.command])
                .help("Hide PersonaStack windows and keep Desktop Control running. Quit PersonaStack from its menu bar icon to stop the app.")
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }

        MenuBarExtra {
            DesktopControlMenu()
        } label: {
            DesktopControlStatusIcon(image: menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("PersonaStack Servers", id: "desktop-server-settings") {
            DesktopServerSettingsWindow()
        }
        .defaultSize(width: 600, height: 480)
        .windowResizability(.contentSize)
    }
}

private struct DesktopControlStatusIcon: View {
    let image: NSImage
    @ObservedObject private var presentation = DesktopControlPresentationStore.shared

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .overlay(alignment: .bottomTrailing) {
                if presentation.snapshot.activity != nil {
                    Circle().fill(.blue).frame(width: 7, height: 7)
                } else if presentation.snapshot.state == .needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .accessibilityLabel("PersonaStack Desktop. \(presentation.snapshot.message)")
    }
}

/// The shell owns the authenticated concern stream for the app lifetime. A
/// hidden window retains its WebView when the visible window is closed.
@MainActor
final class MainWebViewHost {
    private(set) static var shared = MainWebViewHost(appURL: LaunchConfiguration.selectedURL(), resumePermissionSetup: DesktopApplicationRestart.resumesPermissionSetup)

    static func replaceSharedHost(with appURL: URL) -> MainWebViewHost {
        let oldHost = shared
        oldHost.retire()
        let newHost = MainWebViewHost(appURL: appURL)
        shared = newHost
        return oldHost
    }

    static func showMainWindow(openWindow: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
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
        NSApp.unhide(nil)
        openWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    let webView: WKWebView
    let coordinator: PersonaStackWebView.Coordinator
    private let backgroundWindow: NSWindow
    private let requestNotifications: Bool
    private let authorizeNotifications: () -> Void
    private var notificationAuthorizationRequested = false

    init(appURL: URL, loadPage: Bool = true, resumePermissionSetup: Bool = false,
         requestNotifications: Bool = true,
         authorizeNotifications: @escaping () -> Void = { DesktopNotificationCoordinator.shared.requestAuthorization() },
         coordinator suppliedCoordinator: PersonaStackWebView.Coordinator? = nil) {
        let coordinator = suppliedCoordinator ?? PersonaStackWebView.Coordinator(appURL: appURL)
        let configuration = WKWebViewConfiguration()
        WindowPresentation.configureWebView(configuration)
        configuration.websiteDataStore = .default()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.userContentController.add(coordinator, name: "personastackConcern")
        configuration.userContentController.addScriptMessageHandler(coordinator, contentWorld: .page, name: DesktopMediaCapturePermission.bridgeName)
        configuration.userContentController.addScriptMessageHandler(ChatWindowManager.shared, contentWorld: .page, name: "personastackChat")
        configuration.userContentController.addScriptMessageHandler(StackWindowManager.shared, contentWorld: .page, name: "personastackStack")
        configuration.userContentController.addScriptMessageHandler(LocalSessionManager.shared, contentWorld: .page, name: "personastackLocalSession")
        configuration.userContentController.addScriptMessageHandler(DesktopSkillsManager.shared, contentWorld: .page, name: "personastackSkills")
        configuration.userContentController.addScriptMessageHandler(DesktopControlSetupManager.shared, contentWorld: .page, name: "personastackDesktopControl")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.webView = webView
        ChatWindowManager.shared.register(webView, appURL: appURL)
        StackWindowManager.shared.register(webView, appURL: appURL)
        LocalSessionManager.shared.register(webView, appURL: appURL)
        DesktopSkillsManager.shared.register(webView, appURL: appURL)
        DesktopControlSetupManager.shared.register(webView, appURL: appURL)

        let backgroundWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        backgroundWindow.isReleasedWhenClosed = false
        backgroundWindow.contentView = webView
        self.coordinator = coordinator
        self.webView = webView
        self.backgroundWindow = backgroundWindow
        self.requestNotifications = requestNotifications
        self.authorizeNotifications = authorizeNotifications
        requestNotificationAuthorizationIfNeeded()
        if loadPage { coordinator.start(DesktopApplicationRestart.initialPageURL(appURL, resume: resumePermissionSetup)) }
    }

    func openDesktopFlow(path: String, query: [String: String]) {
        guard ["/user/desktop/harnesses", "/user/desktop/skills"].contains(path),
              var components = URLComponents(url: coordinator.appURL, resolvingAgainstBaseURL: false) else { return }
        components.path = path
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        components.fragment = nil
        guard let url = components.url else { return }
        coordinator.start(url)
    }

    func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        backgroundWindow.contentView = NSView(frame: backgroundWindow.contentView?.bounds ?? .zero)
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        if let window = container.window {
            MainWindowNavigation.install(on: window, webView: webView)
        }
        requestNotificationAuthorizationIfNeeded()
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard requestNotifications, !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        authorizeNotifications()
    }

    func retire() {
        ChatWindowManager.shared.unregister(webView)
        StackWindowManager.shared.unregister(webView)
        LocalSessionManager.shared.invalidate(webView)
        DesktopSkillsManager.shared.unregister(webView)
        DesktopControlSetupManager.shared.unregister(webView)
        coordinator.retire()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for name in ["personastackConcern", "personastackChat", "personastackStack", "personastackLocalSession", "personastackSkills", "personastackDesktopControl"] {
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
                MainWindowNavigation.install(on: window, webView: MainWebViewHost.shared.webView)
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
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        weak var webView: WKWebView?
        let appURL: URL
        let loadRecovery = MainWebViewLoadRecovery()
        private let scheduleNotification: (UNNotificationRequest) -> Void
        private let concernNotificationsEnabled: () -> Bool
        private let cancelPermissionVerification: () -> Void
        private let loadRequest: @MainActor (WKWebView, URLRequest) -> AnyObject?
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
        private(set) var isRetired = false
        private(set) var documentGeneration = UUID()
        private let mediaPermission: DesktopMediaCapturePermission

        init(
            appURL: URL,
            notificationCoordinator: UNUserNotificationCenterDelegate? = DesktopNotificationCoordinator.shared,
            configureNotificationCenter: @escaping (UNUserNotificationCenterDelegate) -> Void = { delegate in
                UNUserNotificationCenter.current().delegate = delegate
            },
            scheduleNotification: @escaping (UNNotificationRequest) -> Void = { request in
                UNUserNotificationCenter.current().add(request)
            },
            loadRequest: @escaping @MainActor (WKWebView, URLRequest) -> AnyObject? = { webView, request in
                webView.load(request)
            },
            cancelPermissionVerification: @escaping () -> Void = {
                DesktopPermissionChecklist.shared.cancelVerification()
            },
            concernNotificationsEnabled: @escaping () -> Bool = { DesktopConcernNotificationSettings.isEnabled() },
            mediaPermission: DesktopMediaCapturePermission = .shared
        ) {
            self.appURL = appURL
            self.scheduleNotification = scheduleNotification
            self.loadRequest = loadRequest
            self.concernNotificationsEnabled = concernNotificationsEnabled
            self.cancelPermissionVerification = cancelPermissionVerification
            self.mediaPermission = mediaPermission
            super.init()
            if let notificationCoordinator {
                configureNotificationCenter(notificationCoordinator)
            }
        }

        func start(_ url: URL) {
            guard !isRetired, let webView else { return }
            let request = URLRequest(url: url)
            guard let navigation = loadRequest(webView, request) else { return }
            loadRecovery.navigationStarted(navigation)
        }

        func retry() {
            start(appURL)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard webView === self.webView else { return }
            invalidateDocumentVerification()
            retry()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === self.webView, let navigation else { return }
            invalidateDocumentVerification()
            loadRecovery.navigationStarted(navigation)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === self.webView, let navigation else { return }
            loadRecovery.navigationSucceeded(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard webView === self.webView, let navigation else { return }
            loadRecovery.navigationFailed(navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard webView === self.webView, let navigation else { return }
            loadRecovery.navigationFailed(navigation, error: error)
        }

        private func invalidateDocumentVerification() {
            mediaPermission.cancel(owner: documentGeneration)
            documentGeneration = UUID()
            if let webView { DesktopSkillsManager.shared.invalidate(webView) }
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
                  concernNotificationsEnabled(),
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

            if NavigationPolicy.shouldDownload(url, requested: navigationAction.shouldPerformDownload, appURL: appURL) {
                return .download
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
            }

            if navigationAction.targetFrame == nil {
                if NavigationPolicy.isGoogleOAuthURL(url) {
                    return .allow
                }
                if NavigationPolicy.canOpenExternally(url) { NSWorkspace.shared.open(url) }
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

            return NavigationPolicy.canLoadInWebView(url) ? .allow : .cancel
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
                if let url = navigationAction.request.url, NavigationPolicy.canOpenExternally(url) {
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
            loadRecovery.reset()
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
            webView?.setMicrophoneCaptureState(.none)
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: DesktopMediaCapturePermission.bridgeName, contentWorld: .page)
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            let owner = documentGeneration
            mediaPermission.decide(origin: origin, frame: frame, type: type, appURL: appURL,
                owner: owner, isCurrent: { [weak self, weak webView] in
                    guard let self, let webView else { return false }
                    return !self.isRetired && webView === self.webView && self.documentGeneration == owner
                }, completion: decisionHandler)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            let owner = documentGeneration
            mediaPermission.handleMessage(message.body, owner: owner,
                trusted: message.name == DesktopMediaCapturePermission.bridgeName &&
                    DesktopMediaCapturePermission.trusted(origin: message.frameInfo.securityOrigin,
                                                          frame: message.frameInfo, appURL: appURL),
                isCurrent: { [weak self, weak view = message.webView] in
                    guard let self, let view else { return false }
                    return !self.isRetired && view === self.webView && self.documentGeneration == owner
                }, reply: replyHandler)
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
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
            return DesktopDownloadDestination.choose(suggestedFilename: suggestedFilename, directory: downloads)
        }
    }
}
