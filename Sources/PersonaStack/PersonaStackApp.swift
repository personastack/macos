import AppKit
import PersonaStackCore
import SwiftUI
import WebKit

@main
struct PersonaStackApp: App {
    var body: some Scene {
        WindowGroup("PersonaStack") {
            PersonaStackWebView(url: URL(string: "https://my.personastack.ai/user/personas")!)
                .frame(minWidth: 1024, minHeight: 700)
        }
        .defaultSize(width: 1440, height: 960)
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.start(url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        weak var webView: WKWebView?

        func start(_ url: URL) {
            webView?.load(URLRequest(url: url))
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
