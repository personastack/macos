import AppKit
import PersonaStackCore
import SwiftUI
import UserNotifications
import WebKit

@main
struct PersonaStackApp: App {
    var body: some Scene {
        WindowGroup("PersonaStack") {
            PersonaStackWebView(url: NavigationPolicy.defaultURL)
                .frame(minWidth: 1024, minHeight: 700)
                .background(WindowPresentationConfigurator())
                .ignoresSafeArea(.container, edges: .top)
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
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.userContentController.add(context.coordinator, name: "personastackConcern")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.requestNotificationAuthorization()
        context.coordinator.start(url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
        weak var webView: WKWebView?

        override init() {
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

            if navigationAction.targetFrame == nil || NavigationPolicy.shouldOpenInDefaultBrowser(
                url,
                linkWasUserActivated: navigationAction.navigationType == .linkActivated
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
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
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
