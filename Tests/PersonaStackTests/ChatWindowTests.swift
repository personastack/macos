import AppKit
import Testing
import WebKit
import PersonaStackCore
@testable import PersonaStack

struct ChatWindowTests {
    @MainActor
    @Test func testExpandedChatUsesNativeCornersAndCollapsedAvatarMask() {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false, defaults: preferences.defaults) {}
        defer { chat.dispose() }
        chat.window.contentView?.layoutSubtreeIfNeeded()
        chat.webView.layoutSubtreeIfNeeded()
        #expect(chat.webView.layer?.mask == nil)
        chat.apply(.collapse)
        chat.webView.layoutSubtreeIfNeeded()
        #expect((chat.webView.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath.size == NSSize(width: 64, height: 64))
    }

    @MainActor
    @Test func testNativePinReplacesHostedPinOnOlderPages() async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false, defaults: preferences.defaults) {}
        defer { chat.dispose() }
        // Use the chat's WebKit configuration with a local document and no navigation delegate.
        let hosted = WKWebView(frame: .zero, configuration: chat.webView.configuration)
        hosted.loadHTMLString("""
            <html><head><style>[data-desktop-pin] { display: inline-flex; }</style></head>
            <body><button data-desktop-pin>Always on top</button></body></html>
            """, baseURL: nil)
        var hidden = false
        for _ in 0..<40 {
            hidden = (try? await hosted.evaluateJavaScript("""
                !!document.querySelector('[data-desktop-pin]') &&
                getComputedStyle(document.querySelector('[data-desktop-pin]')).display === 'none'
                """)) as? Bool == true
            if hidden { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(hidden)
        chat.presentation.pinButton.performClick(nil)
        #expect(chat.window.level == .floating)
        #expect(chat.presentation.pinButton.state == .on)
        chat.presentation.pinButton.performClick(nil)
        #expect(chat.window.level == .normal)
        #expect(chat.presentation.pinButton.state == .off)
    }

    @Test func testStrictCommands() {
        #expect(ChatWindowCommand.parse(["version": "1", "action": "open_persona_chat", "persona_id": "p-1", "scope": "s"], main: true) == .open("p-1", "s"))
        for action in ["minimize", "close", "collapse", "expand", "pin"] {
            #expect(ChatWindowCommand.parse(["version": "1", "action": action], main: false) != nil)
            #expect(ChatWindowCommand.parse(["version": "1", "action": action, "extra": "bad"], main: false) == nil)
            #expect(ChatWindowCommand.parse(["version": "2", "action": action], main: false) == nil)
            #expect(ChatWindowCommand.parse(["version": "1", "action": action], main: true) == nil)
        }
        #expect(ChatWindowCommand.parse(["version": "1", "action": "drag", "dx": 7.0, "dy": -8.0], main: false) == .drag(7, -8))
        #expect(ChatWindowCommand.parse(["version": "1", "action": "drag", "dx": NSNumber(value: 0), "dy": NSNumber(value: 1)], main: false) == .drag(0, 1))
        #expect(ChatWindowCommand.parse(["version": "1", "action": "drag", "dx": Double.infinity, "dy": 0.0], main: false) == nil)
        #expect(ChatWindowCommand.parse(["version": "1", "action": "drag", "dx": true, "dy": 0.0], main: false) == nil)
        #expect(ChatWindowCommand.parse(["version": "1", "action": "sync", "scope": ""], main: true) == .sync(""))
        #expect(ChatWindowCommand.parse(["version": "1", "action": "open_persona_chat", "scope": "", "persona_id": "p"], main: true) == nil)
    }

    @Test func testFixedURLAndOrigin() throws {
        let base = try #require(URL(string: "https://my.personastack.ai/user?other=1#hash"))
        #expect(ChatWindowCommand.popoutURL(appURL: base, personaID: "persona-1")?.absoluteString == "https://my.personastack.ai/user/personas/chat/desktop-popout?persona_id=persona-1")
        for id in ["", "../../evil", "a&other=1", "a b", String(repeating: "a", count: 129)] {
            #expect(ChatWindowCommand.popoutURL(appURL: base, personaID: id) == nil)
        }
        #expect(ChatWindowCommand.sameOrigin(base, URL(string: "https://my.personastack.ai:443/")!))
        for value in ["http://my.personastack.ai", "https://my.personastack.ai:444", "https://evil.test"] {
            #expect(!(ChatWindowCommand.sameOrigin(base, URL(string: value)!)))
        }
        #expect(!ChatWindowCommand.permitsBridge(scheme: "https", host: "my.personastack.ai", port: 0, mainFrame: false, appURL: base))
        #expect(!ChatWindowCommand.permitsBridge(scheme: "https", host: "my.personastack.ai", port: 0, mainFrame: true, appURL: URL(string: "https://my.personastack.ai:444")!))
    }

    @Test func testStrictStackPopoutCommandAndURL() throws {
        let base = try #require(URL(string: "https://my.personastack.ai/user/stacks/settings?stack_id=other#hash"))
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_stack_view", "stack_id": "stack-1", "view": "graph"]) == .open(.graph, "stack-1"))
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_stack_view", "stack_id": "stack-1", "view": "graph", "extra": "bad"]) == nil)
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_stack_view", "stack_id": "../../evil", "view": "stream"]) == nil)
        #expect(StackWindowCommand.popoutURL(appURL: base, stackID: "stack-1", view: .stream)?.absoluteString == "https://my.personastack.ai/user/stacks/desktop-popout?stack_id=stack-1&view=stream")
    }

    @Test func testStrictPersonaActivityPopoutCommandAndURL() throws {
        let base = try #require(URL(string: "https://my.personastack.ai/user/personas/persona-1"))
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_persona_activity", "persona_id": "persona-1"]) == .openPersonaActivity("persona-1"))
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_persona_activity", "persona_id": "../bad"]) == nil)
        #expect(StackWindowCommand.parse(["version": "1", "action": "open_persona_activity", "persona_id": "persona-1", "extra": true]) == nil)
        #expect(StackWindowCommand.personaActivityURL(appURL: base, personaID: "persona-1")?.absoluteString == "https://my.personastack.ai/user/personas/activity/desktop-popout?persona_id=persona-1")
        #expect(StackWindowCommand.personaActivityURL(appURL: base, personaID: "a&other=1") == nil)
    }

    @MainActor
    @Test func testStackPopoutChromePreservesGraphAndDeduplication() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let manager = StackWindowManager(loadPages: false, defaults: preferences.defaults, presentWindows: false)
        defer { manager.invalidateSession() }
        let base = try #require(URL(string: "https://example.invalid"))
        manager.apply(.open(.graph, "stack-1"), base: base)
        let graph = try #require(manager.window(for: .graph, stackID: "stack-1"))
        #expect(graph.window.styleMask.contains([.titled, .miniaturizable, .resizable, .closable]))
        #expect(graph.presentation != nil)
        #expect(graph.webView.configuration.userContentController.userScripts.isEmpty)
        #expect(graph.window.isOpaque)
        #expect(graph.window.backgroundColor == PopoutWindowPresentation.backgroundColor)
        #expect(graph.webView.underPageBackgroundColor?.alphaComponent == 0)
        #expect(graph.webView.value(forKey: "drawsBackground") as? Bool == false)
        manager.apply(.open(.graph, "stack-1"), base: base)
        #expect(manager.window(for: .graph, stackID: "stack-1") === graph)
        let chrome = try #require(graph.presentation)
        let overlay = try #require(chrome.graphOverlay)
        let originalView = graph.webView
        let canvas = graph.window.convertToScreen(graph.window.contentLayoutRect)
        chrome.pinButton.performClick(nil)
        overlay.setPointerInside(false)
        #expect(graph.window.level == .floating)
        #expect(!graph.window.styleMask.contains(.titled))
        #expect(!graph.window.isOpaque)
        #expect(graph.window.backgroundColor == .clear)
        #expect(!graph.window.hasShadow)
        #expect(graph.window.canBecomeKey)
        #expect(chrome.pinButton.isHidden)
        #expect(graph.window.convertToScreen(graph.window.contentLayoutRect) == canvas)
        manager.apply(.open(.graph, "stack-1"), base: base)
        #expect(manager.window(for: .graph, stackID: "stack-1") === graph)
        #expect(graph.window.level == .floating)
        overlay.setPointerInside(true)
        #expect(!chrome.pinButton.isHidden)
        chrome.pinButton.performClick(nil)
        #expect(graph.window.level == .normal)
        #expect(graph.window.styleMask.contains(.titled))
        #expect(graph.window.backgroundColor == PopoutWindowPresentation.backgroundColor)
        #expect(graph.webView === originalView)
        #expect(graph.webView.url == nil)
        #expect(graph.window.convertToScreen(graph.window.contentLayoutRect) == canvas)
        #expect(preferences.defaults.object(forKey: PopoutGeometryStore.key(.stackGraph)) == nil)
        chrome.pinButton.performClick(nil)
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        #expect(graph.window.validateUserInterfaceItem(closeItem))
        graph.window.performClose(nil)
        #expect(manager.window(for: .graph, stackID: "stack-1") == nil)
        overlay.setPointerInside(true)
        chrome.togglePin()
        #expect(!graph.window.isVisible)
        #expect(overlay.isHidden)
        manager.apply(.open(.graph, "stack-1"), base: base)
        let reopened = try #require(manager.window(for: .graph, stackID: "stack-1"))
        #expect(reopened !== graph)
        #expect(reopened.window.level == .normal)
        #expect(reopened.window.styleMask.contains(.titled))
        manager.apply(.open(.stream, "stack-1"), base: base)
        let stream = try #require(manager.window(for: .stream, stackID: "stack-1"))
        #expect(stream !== graph)
        #expect(stream.webView.value(forKey: "drawsBackground") as? Bool == true)
        #expect(stream.presentation != nil)
        #expect(stream.window.contentView === stream.webView)
        #expect(stream.window.toolbar != nil)
        stream.window.performClose(nil)
        #expect(manager.window(for: .stream, stackID: "stack-1") == nil)
        manager.apply(.openPersonaActivity("persona-1"), base: base)
        let activity = try #require(manager.window(forPersonaActivity: "persona-1"))
        #expect(activity.presentation != nil)
        #expect(activity.window.contentView === activity.webView)
        manager.apply(.openPersonaActivity("persona-1"), base: base)
        #expect(manager.window(forPersonaActivity: "persona-1") === activity)
        activity.window.performClose(nil)
        #expect(manager.window(forPersonaActivity: "persona-1") == nil)
        manager.invalidateSession()
        #expect(manager.window(for: .graph, stackID: "stack-1") == nil)
        #expect(manager.window(for: .stream, stackID: "stack-1") == nil)
        #expect(manager.window(forPersonaActivity: "persona-1") == nil)
    }

    @MainActor
    @Test func testWindowIsOrdinaryAndDisposesOnce() {
        _ = NSApplication.shared
        var closes = 0
        let preferences = PopoutTestPreferences()
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid/user/personas/chat/desktop-popout?persona_id=p")!, loadPage: false, defaults: preferences.defaults) { closes += 1 }
        #expect(chat.window.styleMask.contains([.titled, .miniaturizable, .resizable, .closable]))
        #expect(chat.window.isOpaque)
        #expect(chat.window.hasShadow)
        #expect(chat.window.level == .normal)
        #expect(chat.window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(chat.window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
        chat.dispose()
        chat.dispose()
        #expect(closes == 1)
    }

    @MainActor
    @Test func testWindowLifecycleAndScopeFence() async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let manager = ChatWindowManager(loadPages: false, defaults: preferences.defaults, presentWindows: false)
        defer { manager.invalidateSession() }
        let base = URL(string: "https://example.invalid")!
        manager.apply(.open("p-1", "account-a"), base: base)
        let first = try #require(manager.chat(for: "p-1"))
        manager.apply(.open("p-1", "account-a"), base: base)
        #expect(manager.chat(for: "p-1") === first)
        manager.apply(.open("p-2", "account-a"), base: base)
        #expect(manager.chat(for: "p-2") !== first)
        manager.apply(.sync("account-a"), base: base)
        #expect(manager.chat(for: "p-1") === first)
        let frame = first.window.frame
        #expect(first.window.toolbar == nil)
        #expect(first.window.titlebarAccessoryViewControllers.first?.isHidden == false)
        #expect(first.presentation.pinButton.toolTip == "Always on top")
        first.apply(.collapse)
        #expect(first.window.frame.size == NSSize(width: 72, height: 72))
        #expect(!first.window.styleMask.contains(.resizable))
        #expect(first.window.toolbar == nil)
        #expect(first.presentation.pinButton.window == nil)
        #expect(!first.window.styleMask.contains(.titled))
        first.apply(.drag(20, 10))
        #expect(abs(first.window.frame.minX - frame.minX - 20) < 1)
        first.apply(.expand)
        #expect(first.window.frame.size == frame.size)
        #expect(abs(first.window.frame.minX - frame.minX - 20) < 1)
        #expect(first.window.toolbar == nil)
        #expect(first.window.titlebarAccessoryViewControllers.first?.isHidden == false)
        #expect(first.window.standardWindowButton(.closeButton)?.isHidden == false)
        first.presentation.pinButton.performClick(nil)
        #expect(first.window.level == .floating)
        #expect(first.presentation.pinButton.accessibilityValue() as? Int == 1)
        first.apply(.pin)
        #expect(first.window.level == .normal)
        #expect(first.presentation.pinButton.accessibilityValue() as? Int == 0)
        #expect(!first.window.isVisible)
        first.apply(.close)
        #expect(manager.chat(for: "p-1") == nil)
        manager.apply(.sync(""), base: base)
        #expect(manager.chat(for: "p-2") == nil)
    }

    @MainActor
    @Test func testCmdWCanCloseAnUnbootedDocument() {
        _ = NSApplication.shared
        var closes = 0
        let preferences = PopoutTestPreferences()
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false,
            defaults: preferences.defaults, evaluateHostedClose: { completion in completion(false) }) { closes += 1 }
        defer { chat.dispose() }
        chat.window.performClose(nil)
        #expect(closes == 1)
        #expect(chat.windowShouldClose(chat.window))
    }

    @MainActor
    @Test func testNativeCloseRetiresImmediatelyAndFinishesHostedCleanupBeforeDeadline() async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        var closes = 0
        var requests = 0
        var deadline: CheckedContinuation<Void, Never>?
        var lateReply: (@MainActor (Bool) -> Void)?
        var cleanupCancelled = false
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false,
            defaults: preferences.defaults,
            waitForCloseDeadline: {
                await withCheckedContinuation { deadline = $0 }
                cleanupCancelled = Task.isCancelled
            },
            evaluateHostedClose: { completion in
                requests += 1; lateReply = completion; completion(true)
            }) { closes += 1 }
        defer { chat.dispose(); deadline?.resume(); deadline = nil }
        chat.window.performClose(nil)
        #expect(closes == 1 && !chat.window.isVisible)
        for _ in 0..<100 where deadline == nil { await Task.yield() }
        #expect(deadline != nil)
        #expect(requests == 1 && closes == 1)
        #expect(chat.webView.navigationDelegate === chat)
        // The healthy hosted bridge disposes remaining resources and cancels cleanup's deadline.
        chat.apply(.close)
        #expect(closes == 1)
        #expect(chat.webView.navigationDelegate == nil && chat.webView.uiDelegate == nil)
        deadline?.resume(); deadline = nil
        lateReply?(false)
        for _ in 0..<100 where !cleanupCancelled { await Task.yield() }
        #expect(closes == 1 && cleanupCancelled)
    }

    @MainActor
    @Test(arguments: [true, false])
    func testNativeCloseButtonClosesImmediatelyWithoutHostedAcknowledgement(javaScriptReplies: Bool) async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        var closes = 0
        var requests = 0
        var waits = 0
        var deadline: CheckedContinuation<Void, Never>?
        var lateReply: (@MainActor (Bool) -> Void)?
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false,
            defaults: preferences.defaults,
            waitForCloseDeadline: {
                waits += 1
                await withCheckedContinuation { deadline = $0 }
            }, evaluateHostedClose: { completion in
                requests += 1; lateReply = completion
                // true models the real page with a rejected or hung API close.
                // No reply models an unresponsive WebKit process.
                if javaScriptReplies { completion(true) }
            }) { closes += 1 }
        defer { chat.dispose(); deadline?.resume(); deadline = nil }
        let nativeClose = ChatWindowCloseObserver(window: chat.window)
        defer { NotificationCenter.default.removeObserver(nativeClose) }
        let closeButton = try #require(chat.window.standardWindowButton(.closeButton))
        closeButton.performClick(nil)
        // Assert synchronously, before either JavaScript or the cleanup deadline can finish.
        #expect(closes == 1 && nativeClose.count == 1 && !chat.window.isVisible)
        #expect(chat.windowShouldClose(chat.window))
        for _ in 0..<100 where deadline == nil { await Task.yield() }
        #expect(deadline != nil && waits == 1)
        #expect(requests == 1 && closes == 1)
        #expect(chat.webView.navigationDelegate === chat)
        closeButton.performClick(nil)
        #expect(requests == 1 && waits == 1)
        deadline?.resume(); deadline = nil
        for _ in 0..<100 where chat.webView.navigationDelegate != nil { await Task.yield() }
        #expect(closes == 1)
        #expect(chat.webView.navigationDelegate == nil && chat.webView.uiDelegate == nil)
        #expect(chat.windowShouldClose(chat.window))
        // An expired page cannot dispose a replacement window through onClose.
        lateReply?(true)
        lateReply?(false)
        chat.apply(.close)
        #expect(closes == 1 && nativeClose.count == 1)
    }

    @MainActor
    @Test(arguments: ["ack", "provisional", "failed", "http", "terminated"])
    func testClosedChatCanReopenImmediatelyAndLateCleanupCannotRemoveReplacement(callback: String) async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let manager = ChatWindowManager(loadPages: false, defaults: preferences.defaults, presentWindows: false)
        defer { manager.invalidateSession() }
        let base = try #require(URL(string: "https://example.invalid"))
        manager.apply(.open("p-1", "account-a"), base: base)
        let first = try #require(manager.chat(for: "p-1"))
        first.window.performClose(nil)
        #expect(manager.chat(for: "p-1") == nil)
        manager.apply(.open("p-1", "account-a"), base: base)
        let replacement = try #require(manager.chat(for: "p-1"))
        #expect(replacement !== first)
        first.focus()
        #expect(!first.window.isVisible)
        first.apply(.pin)
        #expect(first.window.level == .normal)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        switch callback {
        case "provisional": first.webView(first.webView, didFailProvisionalNavigation: nil, withError: error)
        case "failed": first.webView(first.webView, didFail: nil, withError: error)
        case "http":
            let response = try #require(HTTPURLResponse(url: base, statusCode: 503,
                                                        httpVersion: "HTTP/1.1", headerFields: nil))
            let policy = first.navigationResponsePolicy(isMainFrame: true, response: response, canShowMIMEType: true)
            #expect(policy == .cancel)
        case "terminated": first.webViewWebContentProcessDidTerminate(first.webView)
        default: first.apply(.close)
        }
        first.apply(.close)
        first.dispose()
        #expect(manager.chat(for: "p-1") === replacement)
    }

    @MainActor
    @Test(arguments: [true, false])
    func testCloseDuringLoadingClosesImmediatelyAndBoundsDeferredCleanup(finishLoading: Bool) async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let loading = ChatLoadingState()
        var closes = 0
        var requests = 0
        var deadline: CheckedContinuation<Void, Never>?
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false,
            defaults: preferences.defaults,
            waitForCloseDeadline: { await withCheckedContinuation { deadline = $0 } },
            evaluateHostedClose: { completion in requests += 1; completion(true) },
            documentLoading: { loading.isLoading }) { closes += 1 }
        defer { chat.dispose(); deadline?.resume(); deadline = nil }
        let nativeClose = ChatWindowCloseObserver(window: chat.window)
        defer { NotificationCenter.default.removeObserver(nativeClose) }
        chat.window.performClose(nil)
        #expect(closes == 1 && nativeClose.count == 1 && requests == 0)
        for _ in 0..<100 where deadline == nil { await Task.yield() }
        #expect(deadline != nil && chat.webView.navigationDelegate === chat)
        if finishLoading {
            loading.isLoading = false
            chat.webView(chat.webView, didFinish: nil)
            chat.webView(chat.webView, didFinish: nil)
        }
        #expect(requests == (finishLoading ? 1 : 0) && closes == 1)
        deadline?.resume(); deadline = nil
        for _ in 0..<100 where chat.webView.navigationDelegate != nil { await Task.yield() }
        #expect(chat.webView.navigationDelegate == nil && chat.webView.uiDelegate == nil)
        chat.webView(chat.webView, didFinish: nil)
        #expect(requests == (finishLoading ? 1 : 0))
        #expect(closes == 1 && nativeClose.count == 1)
    }
}

@MainActor
private final class ChatWindowCloseObserver: NSObject {
    private(set) var count = 0

    init(window: NSWindow) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func didClose(_ notification: Notification) { count += 1 }
}

@MainActor
private final class ChatLoadingState { var isLoading = true }
