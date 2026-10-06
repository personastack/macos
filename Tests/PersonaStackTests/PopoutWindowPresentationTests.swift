import AppKit
import Testing
import WebKit
@testable import PersonaStack

final class PopoutTestPreferences {
    let name = "PersonaStack.PopoutTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

struct PopoutWindowPresentationTests {
    @MainActor @Test func stackTitlesClearWindowButtonsOnInitialLayoutAndResize() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        for kind in [PopoutWindowKind.stackStream, .personaActivity] {
            let popout = StackPopoutWindow(url: URL(string: "https://example.invalid")!,
                transparent: false, kind: kind, loadPage: false, defaults: preferences.defaults) {}
            defer { popout.dispose() }
            let chrome = try #require(popout.presentation)
            chrome.updateTitle("PersonaStack.ai · \(kind.fallbackTitle)")
            for width in [900.0, 340.0, 390.0, 900.0] {
                popout.window.setFrame(NSRect(x: 50, y: 100, width: width, height: 500), display: false)
                popout.window.layoutIfNeeded()
                let frameView = try #require(popout.window.contentView?.superview)
                frameView.layoutSubtreeIfNeeded()
                let title = try #require(Self.titleField(in: frameView, text: popout.window.title))
                let titleRect = title.convert(title.bounds, to: nil)
                #expect(titleRect.width > 0)
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    let button = try #require(popout.window.standardWindowButton(type))
                    #expect(!button.isHidden)
                    #expect(button.isEnabled)
                    #expect(titleRect.minX >= button.convert(button.bounds, to: nil).maxX)
                }
                #expect(titleRect.maxX <= chrome.pinButton.convert(chrome.pinButton.bounds, to: nil).minX)
            }
        }
    }

    @MainActor private static func titleField(in view: NSView, text: String) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == text { return field }
        return view.subviews.lazy.compactMap { titleField(in: $0, text: text) }.first
    }

    @Test func geometryIsBoundedAndSeparatedByKind() {
        let preferences = PopoutTestPreferences()
        let store = PopoutGeometryStore(defaults: preferences.defaults)
        let frame = NSRect(x: -900, y: 20, width: 500, height: 700)
        store.save(frame, kind: .chat, collapsed: false, fullscreen: false)
        #expect(store.read(.chat) == frame)
        #expect(store.read(.stackStream) == nil)
        #expect(store.read(.personaActivity) == nil)
        for (collapsed, fullscreen) in [(true, false), (false, true)] {
            store.save(NSRect(x: 0, y: 0, width: 900, height: 900), kind: .chat, collapsed: collapsed, fullscreen: fullscreen)
            #expect(store.read(.chat) == frame)
        }
        for bad in [NSRect(x: 0, y: 0, width: 72, height: 72), NSRect(x: CGFloat.infinity, y: 0, width: 500, height: 700), NSRect(x: 0, y: 0, width: 20_000, height: 700)] {
            store.save(bad, kind: .chat, collapsed: false, fullscreen: false)
            #expect(store.read(.chat) == frame)
        }
        preferences.defaults.set([1, 2, 3], forKey: PopoutGeometryStore.key(.chat))
        #expect(store.read(.chat) == nil)
        preferences.defaults.set([0, 0, -1, 700], forKey: PopoutGeometryStore.key(.chat))
        #expect(store.read(.chat) == nil)
    }

    @Test func clampsRemovedDisplaysOversizedFramesAndMinimums() {
        let left = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        let right = NSRect(x: 0, y: 40, width: 1200, height: 760)
        let minimum = NSSize(width: 340, height: 396)
        let frame = NSRect(x: -1000, y: 70, width: 440, height: 676)
        #expect(PopoutGeometryStore.clamp(frame, screens: [left, right], minimum: minimum) == frame)
        #expect(right.contains(PopoutGeometryStore.clamp(frame, screens: [right], minimum: minimum)))
        #expect(PopoutGeometryStore.clamp(NSRect(x: -4000, y: 4000, width: 3000, height: 4000), screens: [right], minimum: minimum) == right)
        #expect(PopoutGeometryStore.clamp(NSRect(x: 20, y: 80, width: 20, height: 20), screens: [right], minimum: minimum).size == minimum)
        #expect(PopoutGeometryStore.clamp(frame, screens: [], minimum: minimum) == frame)
    }

    @MainActor @Test func sharedChromeAndCapabilityForEveryKind() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let standardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        standardWindow.isReleasedWhenClosed = false
        defer { standardWindow.close() }
        let standardTitlebarHeight = standardWindow.frame.height - standardWindow.contentLayoutRect.maxY
        for kind in PopoutWindowKind.allCases {
            let config = WKWebViewConfiguration()
            if kind != .stackGraph {
                PopoutWindowPresentation.advertise(in: config)
                let script = try #require(config.userContentController.userScripts.first)
                #expect(script.source == "window.personastackNativeWindowChrome = true;")
                #expect(script.injectionTime == .atDocumentStart)
                #expect(script.isForMainFrameOnly)
            } else {
                #expect(config.userContentController.userScripts.isEmpty)
            }
            let webView = WKWebView(frame: .zero, configuration: config)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.appearance = NSAppearance(named: .aqua)
            let chrome = PopoutWindowPresentation(window: window, webView: webView, kind: kind, defaults: preferences.defaults)
            defer { chrome.invalidate(); window.close() }
            #expect(window.title == kind.fallbackTitle)
            #expect(window.titleVisibility == .visible)
            #expect(window.appearance?.name == .darkAqua)
            #expect(window.toolbarStyle == (kind.usesTitlebarAccessory ? .automatic : .unified))
            #expect(!window.styleMask.contains(.fullSizeContentView))
            #expect(window.collectionBehavior.contains(.fullScreenPrimary))
            #expect(window.hasShadow)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                #expect(window.standardWindowButton(type)?.isHidden == false)
                #expect(window.standardWindowButton(type)?.isEnabled == true)
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            chrome.pinButton.superview?.layoutSubtreeIfNeeded()
            let chromeHeight = window.frame.height - window.contentLayoutRect.maxY
            if kind.usesTitlebarAccessory {
                #expect(chromeHeight == standardTitlebarHeight)
                #expect(window.toolbar == nil)
                #expect(window.titlebarAccessoryViewControllers.count == 1)
                #expect(window.titlebarAccessoryViewControllers.first?.layoutAttribute == .right)
                #expect(chrome.pinButton.controlSize == .small)
                #expect(chrome.pinButton.frame.size == NSSize(width: 24, height: 24))
            } else {
                #expect(chromeHeight >= 48 && chromeHeight <= 52)
            }
            #expect(window.contentLayoutRect.maxY == webView.frame.maxY)
            #expect(!window.isVisible)
            chrome.pinButton.performClick(nil)
            #expect(window.level == .floating)
            #expect(chrome.pinButton.state == .on)
            #expect(chrome.pinButton.accessibilityValue() as? Int == 1)
            chrome.pinButton.performClick(nil)
            #expect(window.level == .normal)
            #expect(chrome.pinButton.state == .off)
            chrome.updateTitle("  Name · Chat  ")
            #expect(window.title == "Name · Chat")
            for invalid in [nil, "", "  ", "bad\nname", String(repeating: "x", count: 1025)] {
                chrome.updateTitle(invalid)
                #expect(window.title == kind.fallbackTitle)
            }
        }
    }

    @MainActor @Test func movementResizeCollapseAndFullscreenDoNotPoisonRestore() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let url = URL(string: "https://example.invalid")!
        let chat = PersonaChatWindow(url: url, loadPage: false, defaults: preferences.defaults) {}
        defer { chat.dispose() }
        let store = PopoutGeometryStore(defaults: preferences.defaults)
        chat.window.setFrame(NSRect(x: 100, y: 100, width: 500, height: 600), display: false)
        let expanded = try #require(store.read(.chat))
        chat.apply(.collapse)
        chat.apply(.drag(20, 10))
        #expect(chat.window.frame.size == NSSize(width: 72, height: 72))
        #expect(chat.window.collectionBehavior.contains(.fullScreenNone))
        #expect(!chat.window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(store.read(.chat) == expanded)
        chat.apply(.expand)
        #expect(chat.window.frame.size == expanded.size)
        #expect(chat.window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!chat.window.collectionBehavior.contains(.fullScreenNone))
        let moved = try #require(store.read(.chat))
        #expect(moved.minX == expanded.minX + 20)
        #expect(moved.maxY == expanded.maxY - 10)
        chat.presentation.willEnterFullscreen()
        chat.window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 900), display: false)
        chat.presentation.recordGeometry()
        chat.apply(.collapse)
        let fullscreenFrame = chat.window.frame
        chat.apply(.drag(20, 20))
        #expect(chat.window.frame == fullscreenFrame)
        #expect(chat.window.styleMask.contains(.titled))
        #expect(store.read(.chat) == moved)
        chat.presentation.willExitFullscreen()
        chat.window.setFrame(moved, display: false)
        chat.presentation.didExitFullscreen()
        chat.presentation.recordGeometry()
        #expect(store.read(.chat) == moved)
        chat.dispose()
        let reopened = PersonaChatWindow(url: url, loadPage: false, defaults: preferences.defaults) {}
        defer { reopened.dispose() }
        #expect(reopened.window.frame == PopoutGeometryStore.clamp(moved, screens: NSScreen.screens.map(\.visibleFrame), minimum: reopened.window.minSize))
        reopened.presentation.willEnterFullscreen()
        reopened.windowDidFailToEnterFullScreen(reopened.window)
        #expect(reopened.presentation.canCollapse)
        let restored = reopened.window.frame
        reopened.apply(.collapse)
        reopened.dispose()
        #expect(store.read(.chat) == restored)
    }

    @MainActor @Test func titleObservationTracksDocumentUpdatesAndStopsOnDisposal() async throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = PopoutWindowPresentation(window: window, webView: webView, kind: .personaActivity, defaults: preferences.defaults)
        defer { chrome.invalidate(); window.close() }
        webView.loadHTMLString("<title>Prototype · Live Console</title>", baseURL: nil)
        for _ in 0..<60 where window.title != "Prototype · Live Console" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(window.title == "Prototype · Live Console")
        _ = try await webView.evaluateJavaScript("document.title = 'Renamed · Live Console'")
        for _ in 0..<40 where window.title != "Renamed · Live Console" { try await Task.sleep(for: .milliseconds(50)) }
        #expect(window.title == "Renamed · Live Console")
        chrome.invalidate()
        _ = try await webView.evaluateJavaScript("document.title = 'Retired'")
        #expect(window.title == "Renamed · Live Console")
    }
    @MainActor @Test func graphHoverAndPinTransitionsKeepNativeGeometryAndInput() throws {
        _ = NSApplication.shared
        let preferences = PopoutTestPreferences()
        let graph = StackPopoutWindow(url: URL(string: "https://example.invalid")!, transparent: true, kind: .stackGraph, loadPage: false, defaults: preferences.defaults) {}
        defer { graph.dispose() }
        let chrome = try #require(graph.presentation)
        let overlay = try #require(chrome.graphOverlay)
        let minimum = graph.window.minSize
        #expect(chrome.pinButton.accessibilityLabel() == "Pin graph")
        #expect(graph.window.titlebarAccessoryViewControllers.count == 1)
        #expect(overlay.isHidden)
        for width in [340.0, 390.0, 900.0] {
            graph.window.setFrame(NSRect(x: 50, y: 100, width: width, height: minimum.height), display: false)
            let canvas = graph.window.convertToScreen(graph.window.contentLayoutRect)
            for _ in 0..<3 {
                chrome.togglePin()
                graph.window.contentView?.layoutSubtreeIfNeeded()
                overlay.setPointerInside(false)
                #expect(graph.window.convertToScreen(graph.window.contentLayoutRect) == canvas)
                #expect(chrome.pinButton.accessibilityLabel() == "Unpin graph")
                #expect(chrome.pinButton.accessibilityValue() as? Int == 1)
                #expect(graph.window.toolbar == nil)
                #expect(graph.window.standardWindowButton(.closeButton) == nil)
                #expect(graph.window.collectionBehavior.contains(.fullScreenNone))
                #expect(chrome.pinButton.isHidden)
                #expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil)
                overlay.setPointerInside(true)
                #expect(!chrome.pinButton.isHidden)
                #expect(chrome.pinButton.frame.size == NSSize(width: 24, height: 24))
                #expect(chrome.pinButton.layer?.backgroundColor == PopoutWindowPresentation.backgroundColor.cgColor)
                let buttonPoint = NSPoint(x: chrome.pinButton.frame.midX, y: chrome.pinButton.frame.midY)
                #expect(overlay.hitTest(buttonPoint) === chrome.pinButton)
                #expect(overlay.hitTest(NSPoint(x: 10, y: 10)) == nil)
                chrome.togglePin()
                #expect(graph.window.convertToScreen(graph.window.contentLayoutRect) == canvas)
                #expect(graph.window.minSize == minimum)
                #expect(graph.window.titlebarAccessoryViewControllers.count == 1)
                #expect(chrome.pinButton.window === graph.window)
                #expect(!chrome.pinButton.isHidden)
                #expect(chrome.pinButton.layer?.backgroundColor == nil)
                #expect(overlay.isHidden)
                #expect(chrome.pinButton.accessibilityValue() as? Int == 0)
            }
        }
        #expect(preferences.defaults.object(forKey: PopoutGeometryStore.key(.stackGraph)) == nil)
        chrome.willEnterFullscreen()
        chrome.togglePin()
        #expect(graph.window.level == .normal)
        #expect(!chrome.pinButton.isEnabled)
        chrome.fullscreenTransitionFailed()
        #expect(chrome.pinButton.isEnabled)
        chrome.willExitFullscreen()
        chrome.togglePin()
        #expect(graph.window.level == .normal)
        chrome.didExitFullscreen()
        chrome.togglePin()
        #expect(graph.window.level == .floating)
        graph.dispose()
        overlay.setPointerInside(true)
        chrome.togglePin()
        #expect(overlay.onHover == nil)
        #expect(overlay.isHidden)
        #expect(!graph.window.isVisible)
    }

}
