import AppKit
import Testing
import PersonaStackCore
@testable import PersonaStack

struct ChatWindowTests {
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

    @MainActor
    @Test func testStackPopoutWindowsAreBorderlessAndDeduplicated() throws {
        _ = NSApplication.shared
        let manager = StackWindowManager(loadPages: false)
        let base = try #require(URL(string: "https://example.invalid"))
        manager.apply(.open(.graph, "stack-1"), base: base)
        let graph = try #require(manager.window(for: .graph, stackID: "stack-1"))
        #expect(graph.window.styleMask.contains([.titled, .miniaturizable, .resizable, .closable]))
        #expect(!graph.window.isOpaque)
        #expect(graph.window.backgroundColor == .clear)
        manager.apply(.open(.graph, "stack-1"), base: base)
        #expect(manager.window(for: .graph, stackID: "stack-1") === graph)
        manager.apply(.open(.stream, "stack-1"), base: base)
        #expect(manager.window(for: .stream, stackID: "stack-1") !== graph)
        manager.invalidateSession()
        #expect(manager.window(for: .graph, stackID: "stack-1") == nil)
        #expect(manager.window(for: .stream, stackID: "stack-1") == nil)
    }

    @MainActor
    @Test func testWindowIsOrdinaryTransparentAndDisposesOnce() {
        _ = NSApplication.shared
        var closes = 0
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid/user/personas/chat/desktop-popout?persona_id=p")!, loadPage: false) { closes += 1 }
        #expect(chat.window.styleMask.contains([.titled, .miniaturizable, .resizable, .closable]))
        #expect(!(chat.window.isOpaque))
        #expect(chat.window.backgroundColor == .clear)
        #expect(chat.window.level == .normal)
        #expect(chat.window.standardWindowButton(.closeButton)?.isHidden == true)
        chat.dispose()
        chat.dispose()
        #expect(closes == 1)
    }

    @MainActor
    @Test func testWindowLifecycleAndScopeFence() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        let manager = ChatWindowManager(loadPages: false)
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
        first.apply(.collapse)
        #expect(first.window.frame.size == NSSize(width: 72, height: 72))
        #expect(!first.window.styleMask.contains(.resizable))
        first.apply(.drag(20, 10))
        #expect(abs(first.window.frame.minX - frame.minX - 20) < 1)
        first.apply(.expand)
        #expect(first.window.frame.size == frame.size)
        #expect(abs(first.window.frame.minX - frame.minX - 20) < 1)
        first.apply(.pin)
        #expect(first.window.level == .floating)
        first.apply(.pin)
        #expect(first.window.level == .normal)
        first.apply(.minimize)
        // AppKit completes Dock animations on the run loop, not synchronously.
        for _ in 0..<30 where !first.window.isMiniaturized { try await Task.sleep(for: .milliseconds(50)) }
        #expect(first.window.isMiniaturized)
        first.focus()
        #expect(!first.window.isMiniaturized)
        first.apply(.close)
        #expect(manager.chat(for: "p-1") == nil)
        manager.apply(.sync(""), base: base)
        #expect(manager.chat(for: "p-2") == nil)
    }

    @MainActor
    @Test func testCmdWCanCloseAnUnbootedDocument() async throws {
        _ = NSApplication.shared
        var closed = false
        let chat = PersonaChatWindow(url: URL(string: "https://example.invalid")!, loadPage: false) { closed = true }
        #expect(chat.windowShouldClose(chat.window) == false)
        for _ in 0..<40 where !closed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(closed)
        chat.dispose()
    }
}
