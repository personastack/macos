import AppKit
import PersonaStackCore
import Testing
import WebKit
@testable import PersonaStack

@MainActor
struct MainWindowLifecycleTests {
    @Test func externalAndRejectedLinksPreserveCurrentAgentSetupScope() async throws {
        let url = URL(string: "https://my.personastack.ai/user/personas")!
        let view = WKWebView()
        let manager = AgentBridgeSetupManager.shared
        manager.register(view, appURL: url)
        defer { manager.unregister(view) }
        var external: [URL] = []
        let coordinator = PersonaStackWebView.Coordinator(appURL: url, notificationCoordinator: nil,
            cancelPermissionVerification: {}, openExternalURL: { external.append($0) })
        coordinator.webView = view
        let state = try await manager.apply(AgentBridgePageCommand.parse(["version": "2", "action": "state", "scope": ""]), view: view)
        let scope = try #require(state["scope"] as? String)
        let current = try AgentBridgePageCommand.parse(["version": "2", "action": "state", "scope": scope])
        for raw in ["https://example.invalid/help", "file:///tmp/example"] {
            let destination = try #require(URL(string: raw))
            #expect(coordinator.navigationPolicy(for: destination, in: view, mainFrame: true, userActivated: true) == .cancel)
            _ = try await manager.apply(current, view: view)
        }
        #expect(external.map(\.host) == ["example.invalid"])
        #expect(coordinator.navigationPolicy(for: url, in: view, mainFrame: true) == .allow)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(current, view: view) }
    }

    @Test func closedWindowWithRetainedSwiftUIContainerReattachesBeforePresentation() {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        fixture.attach()
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.host.openDesktopFlow(path: "/user/desktop/harnesses", query: [:])
        fixture.window.close()
        #expect(fixture.host.webView.superview !== fixture.container)
        fixture.host.show { Issue.record("Retained scene should not need a new window") }
        #expect(fixture.host.mainWindow === fixture.window)
        #expect(fixture.host.webView.superview === fixture.container)
        #expect(fixture.host.webView.window === fixture.window)
        #expect(fixture.window.isVisible)
        #expect(fixture.requests.map(\.path) == ["/user/desktop/harnesses", "/user/personas"])
    }

    @Test func oauthWindowsRetireOnNativeAndScriptCloseWithoutAffectingMainView() throws {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        let coordinator = fixture.host.coordinator
        for scriptClose in [false, true] {
            let popup = try #require(coordinator.makeOAuthPopup(configuration: WKWebViewConfiguration(), present: false))
            let window = try #require(popup.window)
            #expect(coordinator.popupWindows.count == 1)
            if scriptClose { coordinator.webViewDidClose(popup) }
            else { window.close() }
            #expect(coordinator.popupWindows.isEmpty)
            #expect(popup.navigationDelegate == nil && popup.uiDelegate == nil)
            #expect(fixture.host.webView.navigationDelegate === coordinator)
        }
        let popup = try #require(coordinator.makeOAuthPopup(configuration: WKWebViewConfiguration(), present: false))
        coordinator.retire()
        #expect(coordinator.popupWindows.isEmpty)
        #expect(popup.navigationDelegate == nil)
        #expect(coordinator.makeOAuthPopup(configuration: WKWebViewConfiguration(), present: false) == nil)
    }

    @Test func lateWindowAttachmentInstallsVisibleControlsAndRepairsDetachedAccessory() throws {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        #expect(fixture.host.mainWindow == nil)
        fixture.attach()
        #expect(fixture.host.mainWindow === fixture.window)
        let navigation = try #require(fixture.window.titlebarAccessoryViewControllers.first as? MainWindowNavigation)
        #expect(navigation.backButton.window === fixture.window)
        #expect(navigation.forwardButton.window === fixture.window)
        #expect(!navigation.backButton.isHidden && !navigation.forwardButton.isHidden)
        navigation.view.removeFromSuperview()
        #expect(navigation.view.window == nil)
        fixture.host.attach(to: fixture.container)
        let replacement = try #require(fixture.window.titlebarAccessoryViewControllers.first as? MainWindowNavigation)
        #expect(replacement.backButton.window === fixture.window)
        #expect(replacement.forwardButton.window === fixture.window)
        #expect(fixture.window.titlebarAccessoryViewControllers.count == 1)
    }

    @Test func closeReopensPersonasOnceAtConfiguredOriginAndPreservesReceiver() {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        fixture.attach()
        fixture.host.openDesktopFlow(path: "/user/desktop/harnesses", query: ["mode": "configure"])
        fixture.window.close()
        #expect(fixture.host.mainWindow == nil)
        #expect(fixture.host.webView.window !== fixture.window)
        #expect(fixture.host.webView.window != nil)
        #expect(fixture.host.webView.navigationDelegate === fixture.host.coordinator)
        // A stale SwiftUI update must not reattach to the already closed window.
        fixture.host.attach(to: fixture.container)
        #expect(fixture.host.mainWindow == nil)
        fixture.host.prepareToShow()
        fixture.host.prepareToShow()
        #expect(fixture.requests.map(\.path) == ["/user/desktop/harnesses", "/user/personas"])
        #expect(fixture.requests.last?.absoluteString == "https://example.invalid:8443/user/personas")
    }

    @Test func explicitDestinationsAfterCloseWinOverDefaultReopen() {
        for useMenu in [false, true] {
            let fixture = WindowFixture()
            defer { fixture.dispose() }
            fixture.attach()
            fixture.window.close()
            if useMenu {
                fixture.host.openDesktopFlow(path: "/user/desktop/harnesses", query: ["mode": "configure"])
            } else {
                fixture.host.navigate(to: URL(string: "https://example.invalid:8443/user/personas/p-1")!)
            }
            fixture.host.prepareToShow()
            #expect(fixture.requests.count == 1)
            #expect(fixture.requests.first?.path == (useMenu ? "/user/desktop/harnesses" : "/user/personas/p-1"))
        }
    }

    @Test func ordinaryFocusHideAndOtherWindowCloseDoNotResetPage() {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        fixture.attach()
        fixture.window.title = "A hosted title must not change window identity"
        fixture.host.openDesktopFlow(path: "/user/desktop/skills", query: [:])
        fixture.window.orderOut(nil)
        let other = WindowFixture.makeWindow()
        other.title = "PersonaStack"
        other.close()
        fixture.host.prepareToShow()
        #expect(fixture.requests.count == 1)
        #expect(fixture.host.mainWindow === fixture.window)
    }

    @Test func recreatedWindowResetsWithoutMenuReopenerAndRetiredHostCannotReattach() throws {
        let fixture = WindowFixture()
        defer { fixture.dispose() }
        fixture.attach()
        fixture.window.close()
        let replacementWindow = WindowFixture.makeWindow()
        defer { replacementWindow.close() }
        let replacementContainer = MainWebViewContainer(host: fixture.host)
        replacementWindow.contentView = replacementContainer
        #expect(fixture.host.mainWindow === replacementWindow)
        #expect(fixture.requests.map(\.path) == ["/user/personas"])
        #expect(fixture.host.webView.window === replacementWindow)
        fixture.host.retire()
        fixture.host.attach(to: replacementContainer)
        fixture.host.prepareToShow()
        fixture.host.show { Issue.record("Retired host reopened a window") }
        #expect(fixture.host.webView.superview == nil)
        #expect(fixture.host.mainWindow == nil)
        #expect(fixture.requests.count == 1)
    }
}

@MainActor
private final class WindowFixture {
    var requests: [URL] = []
    let window: NSWindow
    private(set) var host: MainWebViewHost!
    private(set) var container: MainWebViewContainer!

    init() {
        _ = NSApplication.shared
        window = Self.makeWindow()
        let url = URL(string: "https://example.invalid:8443/diagnostic?original=true#section")!
        let coordinator = PersonaStackWebView.Coordinator(appURL: url, notificationCoordinator: nil,
            configureNotificationCenter: { _ in }, scheduleNotification: { _ in },
            loadRequest: { [weak self] _, request in
                if let url = request.url { self?.requests.append(url) }
                return NSObject()
            }, cancelPermissionVerification: {})
        host = MainWebViewHost(appURL: url, loadPage: false, requestNotifications: false, coordinator: coordinator)
        container = MainWebViewContainer(host: host)
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1172, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func attach() { window.contentView = container }
    func dispose() { host.retire(); window.close() }
}
