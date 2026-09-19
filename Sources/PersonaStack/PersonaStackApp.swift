import AppKit
import PersonaStackCore
import SwiftUI
import UserNotifications
import WebKit

@main
struct PersonaStackApp: App {
    private let launchURL = LaunchConfiguration.url()

    var body: some Scene {
        WindowGroup("PersonaStack") {
            PersonaStackWebView(url: launchURL)
                .frame(minWidth: 1172, minHeight: 700)
                .background(WindowPresentationConfigurator())
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
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
                WindowPresentation.configure(window)
            }
        }
    }
}

struct PersonaStackWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(appURL: url)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        WindowPresentation.configureWebView(configuration)
        configuration.websiteDataStore = .default()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.userContentController.add(context.coordinator, name: "personastackConcern")
        configuration.userContentController.addScriptMessageHandler(ChatWindowManager.shared, contentWorld: .page, name: "personastackChat")
        configuration.userContentController.addScriptMessageHandler(LocalSessionManager.shared, contentWorld: .page, name: "personastackLocalSession")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        ChatWindowManager.shared.register(webView, appURL: url)
        LocalSessionManager.shared.register(webView, appURL: url)
        context.coordinator.requestNotificationAuthorization()
        context.coordinator.start(url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
        weak var webView: WKWebView?
        let appURL: URL
        private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

        init(appURL: URL) {
            self.appURL = appURL
            super.init()
            UNUserNotificationCenter.current().delegate = self
        }

        func start(_ url: URL) {
            webView?.load(URLRequest(url: url))
        }

        func requestNotificationAuthorization() {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "personastackConcern",
                  message.frameInfo.isMainFrame,
                  NavigationPolicy.isAppHost(message.frameInfo.securityOrigin.host),
                  NotificationBridge.isNewConcernEvent(message.body) else {
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
            UNUserNotificationCenter.current().add(request)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }

            if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true,
               ["/login", "/logout"].contains(url.path) {
                ChatWindowManager.shared.invalidateSession()
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
