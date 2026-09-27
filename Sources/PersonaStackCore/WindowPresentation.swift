import AppKit
import WebKit

@MainActor
public enum WindowPresentation {
    public static let canvasColor = NSColor(srgbRed: 10.0 / 255, green: 10.0 / 255, blue: 20.0 / 255, alpha: 1)

    public static func configureWebView(_ configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = "PersonaStackDesktop/1"
    }

    public static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.formUnion([.fullSizeContentView, .resizable])
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbar = nil
        window.backgroundColor = canvasColor
        window.appearance = NSAppearance(named: .darkAqua)
    }
}
