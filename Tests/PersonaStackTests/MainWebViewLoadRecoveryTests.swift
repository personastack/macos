import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack

private final class FakeNavigation {}

@Test @MainActor func navigationRecoveryIgnoresCanceledAndObsoleteFailures() {
    let recovery = MainWebViewLoadRecovery()
    let original = FakeNavigation()
    let replacement = FakeNavigation()
    let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    let canceledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

    recovery.navigationStarted(original)
    recovery.navigationFailed(original, error: canceledError)
    #expect(!recovery.isFailed)

    recovery.navigationStarted(original)
    recovery.navigationStarted(replacement)
    recovery.navigationFailed(original, error: networkError)
    #expect(!recovery.isFailed)

    recovery.navigationFailed(replacement, error: networkError)
    #expect(recovery.isFailed)

    let retry = FakeNavigation()
    recovery.navigationStarted(retry)
    #expect(!recovery.isFailed)
    recovery.navigationSucceeded(retry)
    #expect(!recovery.isFailed)
}

@Test @MainActor func initialAndCrashReloadFailuresRetryWithFreshAppGets() throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
    var requests: [URLRequest] = []
    var navigations: [FakeNavigation] = []
    let coordinator = PersonaStackWebView.Coordinator(
        appURL: appURL,
        notificationCoordinator: nil,
        loadRequest: { _, request in
            requests.append(request)
            let navigation = FakeNavigation()
            navigations.append(navigation)
            return navigation
        },
        cancelPermissionVerification: {}
    )
    let webView = WKWebView(frame: .zero)
    coordinator.webView = webView

    coordinator.start(appURL)
    #expect(requests.count == 1)
    #expect(requests[0].httpMethod == "GET")
    #expect(requests[0].url == appURL)

    let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
    coordinator.loadRecovery.navigationFailed(navigations[0], error: networkError)
    #expect(coordinator.loadRecovery.isFailed)
    coordinator.retry()
    #expect(requests.count == 2)
    #expect(requests[1].httpMethod == "GET")
    #expect(requests[1].url == appURL)
    #expect(!coordinator.loadRecovery.isFailed)

    coordinator.webViewWebContentProcessDidTerminate(webView)
    #expect(requests.count == 3)
    #expect(requests[2].httpMethod == "GET")
    #expect(requests[2].url == appURL)

    coordinator.loadRecovery.navigationFailed(navigations[2], error: networkError)
    #expect(coordinator.loadRecovery.isFailed)

    coordinator.retry()
    #expect(requests.count == 4)
    #expect(requests[3].httpMethod == "GET")
    #expect(requests[3].url == appURL)
    #expect(!coordinator.loadRecovery.isFailed)
}

@Test @MainActor func retiredCoordinatorCannotRetryOrPreserveFailurePresentation() throws {
    let appURL = try #require(URL(string: "https://my.personastack.ai/user/personas"))
    var loadCount = 0
    let coordinator = PersonaStackWebView.Coordinator(
        appURL: appURL,
        notificationCoordinator: nil,
        loadRequest: { _, _ in
            loadCount += 1
            return FakeNavigation()
        },
        cancelPermissionVerification: {}
    )
    let webView = WKWebView(frame: .zero)
    coordinator.webView = webView
    coordinator.start(appURL)
    let navigation = FakeNavigation()
    coordinator.loadRecovery.navigationStarted(navigation)
    coordinator.loadRecovery.navigationFailed(
        navigation,
        error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    )
    coordinator.retire()
    coordinator.retry()

    #expect(loadCount == 1)
    #expect(!coordinator.loadRecovery.isFailed)
}
