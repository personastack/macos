import AppKit
import PersonaStackCore
import Testing
import WebKit
@testable import PersonaStack

struct StackPopoutNavigationTests {
    @MainActor @Test func selectedOriginFileDownloadsPreserveStreamAndSession() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let page = URL(string: "https://example.invalid:444/user/stacks/desktop-popout?view=stream")!
        let file = URL(string: "https://example.invalid:444/user/stacks/assets/download?workspace_id=ws&stack_id=s&asset_id=a")!
        var destinations: [URL] = []
        var closes = 0
        let stream = StackPopoutWindow(url: page, transparent: false, kind: .stackStream,
            loadPage: false, defaults: preferences.defaults, navigateMainWindow: { destinations.append($0) }, openExternalURL: { _ in }) { closes += 1 }
        defer { stream.dispose() }
        let view = stream.webView
        let frame = stream.window.frame
        #expect(view.configuration.websiteDataStore === WKWebsiteDataStore.default())
        for pinned in [false, true] {
            if pinned { stream.presentation?.togglePin() }
            for mainFrame in [false, true] {
                #expect(stream.navigationPolicy(for: file, userActivated: true, mainFrame: mainFrame, downloadRequested: true) == .download)
                #expect(stream.webView === view && stream.window.frame == frame)
                #expect(stream.window.level == (pinned ? .floating : .normal))
            }
        }
        for status in [200, 401, 403, 404, 410, 500] {
            let response = try #require(HTTPURLResponse(url: file, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Disposition": "attachment; filename=brief.pdf"]))
            #expect(stream.responsePolicy(for: response, mainFrame: true, canShowMIMEType: false)
                == (status == 200 ? .download : .cancel))
        }
        #expect(destinations.isEmpty && closes == 0)
        #expect(stream.webView.navigationDelegate != nil)
        let graph = StackPopoutWindow(url: page, transparent: true, kind: .stackGraph,
            loadPage: false, defaults: preferences.defaults, navigateMainWindow: { destinations.append($0) }) {}
        defer { graph.dispose() }
        #expect(graph.navigationPolicy(for: file, userActivated: true, mainFrame: true, downloadRequested: true) == .cancel)
        #expect(destinations == [file])
        for raw in ["https://foreign.invalid/user/stacks/assets/download", "https://user:password@example.invalid:444/user/stacks/assets/download"] {
            #expect(stream.navigationPolicy(for: try #require(URL(string: raw)), userActivated: true, mainFrame: true, downloadRequested: true) == .cancel)
        }
    }

    @MainActor @Test func cancellationPreservesPopoutAndClosedWindowCannotRefocus() {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        var closes = 0
        let popout = StackPopoutWindow(url: URL(string: "https://example.invalid/stream")!,
            transparent: false, kind: .stackStream, loadPage: false, defaults: preferences.defaults) { closes += 1 }
        defer { popout.dispose() }
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        popout.webView(popout.webView, didFailProvisionalNavigation: nil, withError: cancelled)
        popout.webView(popout.webView, didFail: nil, withError: cancelled)
        #expect(closes == 0 && popout.webView.navigationDelegate != nil)
        popout.window.close()
        #expect(closes == 1)
        #expect(popout.webView.navigationDelegate == nil && popout.webView.uiDelegate == nil)
        popout.focus()
        #expect(!popout.window.isVisible)
        popout.dispose()
        #expect(closes == 1)
    }

    @MainActor @Test func personaLinksReopenMainWindowAndPreservePinnedStream() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        var destinations: [URL] = []
        var reopens = 0
        let delegate = PersonaStackTerminationDelegate(shutdown: { true }, terminate: { _ in }, timeout: .seconds(1),
            navigateMainWindow: { destinations.append($0) })
        delegate.installMainWindowReopener { reopens += 1 }
        let manager = StackWindowManager(loadPages: false, defaults: preferences.defaults, presentWindows: false)
        manager.navigateMainWindow = { delegate.openMainPage($0) }
        defer { manager.invalidateSession() }
        let base = try #require(URL(string: "https://example.invalid:444/user/stacks/settings"))
        manager.apply(.open(.stream, "stack-1"), base: base)
        let stream = try #require(manager.window(for: .stream, stackID: "stack-1"))
        let view = stream.webView
        let frame = stream.window.frame
        for pinned in [false, true] {
            if pinned { stream.presentation?.togglePin() }
            for mainFrame in [true, false] {
                let settings = try #require(URL(string: "https://example.invalid:444/user/personas/p-1?from=stacks"))
                #expect(stream.navigationPolicy(for: settings, userActivated: true, mainFrame: mainFrame) == .cancel)
                #expect(destinations.last == settings)
                #expect(manager.window(for: .stream, stackID: "stack-1") === stream)
                #expect(stream.webView === view)
                #expect(stream.window.frame == frame)
                #expect(stream.window.level == (pinned ? .floating : .normal))
            }
        }
        #expect(destinations.count == 4)
        #expect(reopens == 4)
        stream.dispose()
        let settings = try #require(URL(string: "https://example.invalid:444/user/personas/p-2"))
        #expect(stream.navigationPolicy(for: settings, userActivated: true, mainFrame: true) == .cancel)
        #expect(destinations.count == 4)
    }

    @MainActor @Test func popoutNavigationKeepsExternalOriginAndSessionBoundaries() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let page = try #require(URL(string: "https://example.invalid:444/user/stacks/desktop-popout?stack_id=stack-1&view=stream"))
        var internalLinks: [URL] = []
        var externalLinks: [URL] = []
        var closes = 0
        let stream = StackPopoutWindow(url: page, transparent: false, kind: .stackStream,
            loadPage: false, defaults: preferences.defaults,
            navigateMainWindow: { internalLinks.append($0) }, openExternalURL: { externalLinks.append($0) }) { closes += 1 }
        defer { stream.dispose() }
        #expect(stream.navigationPolicy(for: page, userActivated: false, mainFrame: true) == .allow)
        for raw in ["https://other.invalid/page", "https://example.invalid:445/user/personas/p", "http://example.invalid:444/user/personas/p", "mailto:support@example.invalid"] {
            let link = try #require(URL(string: raw))
            #expect(stream.navigationPolicy(for: link, userActivated: true, mainFrame: false) == .cancel)
            #expect(externalLinks.last == link)
        }
        #expect(externalLinks.count == 4)
        for raw in ["file:///tmp/file", "javascript:alert(1)", "https://user:password@example.invalid:444/user/personas/p"] {
            #expect(stream.navigationPolicy(for: try #require(URL(string: raw)), userActivated: true, mainFrame: true) == .cancel)
        }
        let login = try #require(URL(string: "https://example.invalid:444/login"))
        #expect(stream.navigationPolicy(for: login, userActivated: false, mainFrame: false) == .cancel)
        #expect(closes == 0)
        #expect(internalLinks.isEmpty)
        #expect(externalLinks.count == 4)
        #expect(stream.navigationPolicy(for: login, userActivated: false, mainFrame: true) == .cancel)
        #expect(closes == 1)
        #expect(internalLinks.isEmpty)
        #expect(externalLinks.count == 4)
    }
}
