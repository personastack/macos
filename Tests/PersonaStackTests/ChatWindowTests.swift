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
        #expect(graph.presentation == nil)
        #expect(graph.webView.configuration.userContentController.userScripts.isEmpty)
        #expect(!graph.window.isOpaque)
        #expect(graph.window.backgroundColor == .clear)
        #expect(graph.webView.underPageBackgroundColor?.alphaComponent == 0)
        #expect(graph.webView.value(forKey: "drawsBackground") as? Bool == false)
        manager.apply(.open(.graph, "stack-1"), base: base)
        #expect(manager.window(for: .graph, stackID: "stack-1") === graph)
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
    @Test func testCmdWCanCloseAnUnbootedDocument() async throws {
        _ = NSApplication.shared
        var closed = false
        let preferences = PopoutTestPreferences()
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false, defaults: preferences.defaults) { closed = true }
        #expect(chat.windowShouldClose(chat.window) == false)
        for _ in 0..<40 where !closed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(closed)
        chat.dispose()
    }

    @MainActor
    @Test func testNativeCloseWaitsForHostedCloseAuthority() async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        var closed = false
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false, defaults: preferences.defaults) { closed = true }
        defer { chat.dispose() }
        chat.webView.navigationDelegate = nil
        chat.webView.loadHTMLString("""
            <script>window.closeRequests = 0;
            window.personastackDesktopClose = () => { window.closeRequests += 1; };</script>
            """, baseURL: nil)
        var ready = false
        for _ in 0..<60 {
            ready = (try? await chat.webView.evaluateJavaScript("typeof window.personastackDesktopClose === 'function'")) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready)
        #expect(!chat.windowShouldClose(chat.window))
        var requested = false
        for _ in 0..<40 {
            requested = (try? await chat.webView.evaluateJavaScript("window.closeRequests > 0")) as? Bool == true
            if requested { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(requested)
        #expect(!closed)
        // A failed/unfinished hosted operation sends no close acknowledgment.
        // Only the existing validated bridge's .close command disposes it.
        chat.apply(.close)
        #expect(closed)
    }
}
