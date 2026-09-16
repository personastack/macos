import AppKit
import Foundation
import Testing
import WebKit
@testable import PersonaStack

// Explicit consumer-edge acceptance only. Ordinary tests never open a network connection.
@MainActor
struct HostedChatSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERSONASTACK_CHAT_FIXTURE_URL"] != nil))
    func hostedControlsReachRealNativeWindows() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["PERSONASTACK_CHAT_FIXTURE_URL"] ?? ""))
        #expect(base.host == "127.0.0.1")
        guard base.host == "127.0.0.1" else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        let manager = ChatWindowManager()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.addScriptMessageHandler(manager, contentWorld: .page, name: "personastackChat")
        let main = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        manager.register(main, appURL: base)
        defer {
            manager.invalidateSession()
            main.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "personastackChat", contentWorld: .page)
        }
        main.load(URLRequest(url: base.appendingPathComponent("main")))
        try await waitFor { await self.evaluate(main, "document.readyState === 'complete' && !!document.querySelector('[data-persona-chat-launch]')") }
        _ = await evaluate(main, "document.querySelector('button').click(); true")
        try await waitFor { manager.chat(for: "persona-1") != nil }
        let chat = try #require(manager.chat(for: "persona-1"))
        try await waitFor { await self.evaluate(chat.webView, "!!document.querySelector('.persona-chat-dock-embedded-avatar')") }
        let expanded = chat.window.frame.size
        _ = await evaluate(chat.webView, "document.querySelector('[data-chat-input]').value='unsent draft'; document.querySelector('.persona-chat-dock-embedded-avatar').click(); true")
        try await waitFor { chat.window.frame.width == 72 }
        try await waitFor { await self.evaluate(chat.webView, "document.body.classList.contains('is-collapsed')") }
        _ = await evaluate(chat.webView, "document.querySelector('.persona-chat-dock-embedded-avatar').click(); true")
        try await waitFor { chat.window.frame.size == expanded }
        #expect(await evaluate(chat.webView, "document.querySelector('[data-chat-input]').value === 'unsent draft'"))
        _ = await evaluate(chat.webView, "document.querySelector('[data-desktop-pin]').click(); true")
        try await waitFor { chat.window.level == .floating }
        _ = await evaluate(chat.webView, "document.querySelector('[data-desktop-minimize]').click(); true")
        try await waitFor { chat.window.isMiniaturized }
        _ = await evaluate(main, "document.querySelector('button').click(); true")
        try await waitFor { !chat.window.isMiniaturized }
        #expect(manager.chat(for: "persona-1") === chat)
        _ = await evaluate(chat.webView, "document.querySelector('[data-desktop-close]').click(); true")
        try await waitFor { manager.chat(for: "persona-1") == nil }
        _ = await evaluate(main, "document.querySelector('button').click(); true")
        try await waitFor { manager.chat(for: "persona-1") != nil }
        let second = try #require(manager.chat(for: "persona-1"))
        try await waitFor { await self.evaluate(second.webView, "typeof window.personastackDesktopClose === 'function'") }
        second.window.performClose(nil)
        try await waitFor { manager.chat(for: "persona-1") == nil }
    }

    private func evaluate(_ view: WKWebView, _ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value as? Bool == true) }
        }
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await condition(), "Native-hosted fixture condition did not become true within five seconds")
    }
}
