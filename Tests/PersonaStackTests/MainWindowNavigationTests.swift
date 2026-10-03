import AppKit
import Testing
import WebKit
@testable import PersonaStack

struct MainWindowNavigationTests {
    @MainActor @Test func clicksFollowHistoryAvailability() {
        _ = NSApplication.shared
        let webView = HistoryTestWebView()
        let navigation = MainWindowNavigation()
        navigation.bind(to: webView)
        #expect(!navigation.backButton.isEnabled)
        #expect(!navigation.forwardButton.isEnabled)
        navigation.backButton.performClick(nil)
        navigation.forwardButton.performClick(nil)
        #expect(webView.backCalls == 0)
        #expect(webView.forwardCalls == 0)

        webView.setHistory(back: true, forward: false)
        #expect(navigation.backButton.isEnabled)
        #expect(!navigation.forwardButton.isEnabled)
        navigation.backButton.performClick(nil)
        #expect(webView.backCalls == 1)
        #expect(!navigation.backButton.isEnabled)
        #expect(navigation.forwardButton.isEnabled)
        navigation.forwardButton.performClick(nil)
        #expect(webView.forwardCalls == 1)
        #expect(navigation.backButton.isEnabled)
        #expect(!navigation.forwardButton.isEnabled)
    }

    @MainActor @Test func installationReusesControlsAndRebindsReplacementHistory() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1172, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = HistoryTestWebView()
        first.setHistory(back: true, forward: false)
        MainWindowNavigation.install(on: window, webView: first)
        MainWindowNavigation.install(on: window, webView: first)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        let navigation = try #require(window.titlebarAccessoryViewControllers.first as? MainWindowNavigation)
        #expect(navigation.layoutAttribute == .left)
        #expect(navigation.backButton.isEnabled)
        #expect(navigation.backButton.accessibilityLabel() == "Back")
        #expect(navigation.forwardButton.accessibilityLabel() == "Forward")

        let replacement = HistoryTestWebView()
        replacement.setHistory(back: false, forward: true)
        MainWindowNavigation.install(on: window, webView: replacement)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titlebarAccessoryViewControllers.first === navigation)
        #expect(!navigation.backButton.isEnabled)
        #expect(navigation.forwardButton.isEnabled)
        first.setHistory(back: true, forward: true)
        #expect(!navigation.backButton.isEnabled)
        navigation.forwardButton.performClick(nil)
        #expect(replacement.forwardCalls == 1)
        #expect(first.forwardCalls == 0)
    }
}

@MainActor
private final class HistoryTestWebView: WKWebView {
    private var backAvailable = false
    private var forwardAvailable = false
    private(set) var backCalls = 0
    private(set) var forwardCalls = 0

    override var canGoBack: Bool { backAvailable }
    override var canGoForward: Bool { forwardAvailable }

    func setHistory(back: Bool, forward: Bool) {
        willChangeValue(forKey: "canGoBack")
        willChangeValue(forKey: "canGoForward")
        backAvailable = back
        forwardAvailable = forward
        didChangeValue(forKey: "canGoForward")
        didChangeValue(forKey: "canGoBack")
    }

    override func goBack() -> WKNavigation? {
        backCalls += 1
        setHistory(back: false, forward: true)
        return nil
    }

    override func goForward() -> WKNavigation? {
        forwardCalls += 1
        setHistory(back: true, forward: false)
        return nil
    }
}
