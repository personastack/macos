import AppKit
import Testing
import WebKit
import PersonaStackCore
@testable import PersonaStack

struct MainWindowNavigationTests {
    @MainActor @Test func chromeIconRenderingPreservesShapeAndColorAcrossStates() throws {
        _ = NSApplication.shared
        let button = WindowChromeButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.appearance = NSAppearance(named: .darkAqua)
        button.imagePosition = .imageOnly
        button.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.white.setFill()
            rect.insetBy(dx: 4, dy: 4).fill()
            return true
        }
        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            context.cgContext.translateBy(x: 0, y: 24)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            WindowPresentation.canvasColor.setFill()
            button.bounds.fill()
            button.draw(button.bounds)
            context.flushGraphics()
            return try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        func matches(_ actual: NSColor, _ expected: NSColor) -> Bool {
            abs(actual.redComponent - expected.redComponent) < 0.01
                && abs(actual.greenComponent - expected.greenComponent) < 0.01
                && abs(actual.blueComponent - expected.blueComponent) < 0.01
        }
        for state in [NSControl.StateValue.off, .on] {
            button.state = state
            #expect(try matches(pixel(12, 12), WindowPresentation.headerForeground))
            #expect(try matches(pixel(5, 5), WindowPresentation.canvasColor))
        }
        button.isEnabled = false
        #expect(try matches(pixel(12, 12), WindowPresentation.headerSecondary))
        #expect(try matches(pixel(5, 5), WindowPresentation.canvasColor))
        button.isEnabled = true
        button.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
            trackingNumber: 0, userData: nil)))
        #expect(try matches(pixel(5, 5), WindowPresentation.headerHover))
        let window = NSWindow(contentRect: button.bounds, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = button
        #expect(window.makeFirstResponder(button))
        #expect(try matches(pixel(1, 12), WindowPresentation.headerAccent))
        window.makeFirstResponder(nil)
        button.mouseExited(with: try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2,
            trackingNumber: 0, userData: nil)))
        // An asymmetric upper marker detects inversion inside flipped native controls.
        button.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 4, y: 8, width: 8, height: 4).fill()
            return true
        }
        #expect(try matches(pixel(12, 9), WindowPresentation.headerForeground))
        #expect(try matches(pixel(12, 15), WindowPresentation.canvasColor))
    }

    @MainActor @Test func clicksFollowHistoryAvailability() {
        _ = NSApplication.shared
        let webView = HistoryTestWebView()
        let navigation = MainWindowNavigation()
        navigation.bind(to: webView)
        #expect(navigation.refreshButton.isEnabled)
        navigation.refreshButton.performClick(nil)
        #expect(webView.reloadCalls == 1)
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
        #expect(navigation.refreshButton.accessibilityLabel() == "Refresh")

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
        navigation.refreshButton.performClick(nil)
        #expect(replacement.reloadCalls == 1)
        #expect(first.reloadCalls == 0)
    }
}

@MainActor
private final class HistoryTestWebView: WKWebView {
    private var backAvailable = false
    private var forwardAvailable = false
    private(set) var backCalls = 0
    private(set) var forwardCalls = 0
    private(set) var reloadCalls = 0

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

    override func reload() -> WKNavigation? {
        reloadCalls += 1
        return nil
    }
}
