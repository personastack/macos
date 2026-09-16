import AppKit
import WebKit

@MainActor
public enum WindowPresentation {
    public static func configureWebView(_ configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = "PersonaStackDesktop/1"
    }

    public static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
    }
}
