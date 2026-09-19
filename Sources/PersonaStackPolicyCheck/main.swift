import AppKit
import Foundation
import PersonaStackCore
import WebKit

let window = NSWindow(
    contentRect: .zero,
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
WindowPresentation.configure(window)
let webConfiguration = WKWebViewConfiguration()
WindowPresentation.configureWebView(webConfiguration)

let checks = [
    webConfiguration.applicationNameForUserAgent == "PersonaStackDesktop/1",
    NavigationPolicy.keepsInApp(URL(string: "https://my.personastack.ai/user/personas")!),
    LaunchConfiguration.url(arguments: ["PersonaStack"]) == NavigationPolicy.defaultURL,
    LaunchConfiguration.url(
        arguments: ["PersonaStack"],
        packagedDefaultURL: "https://personastack.ericgreer.info/user/personas"
    ).host == "personastack.ericgreer.info",
    LaunchConfiguration.url(arguments: ["PersonaStack", "--personastack-url", "https://personastack.ericgreer.info/user/personas"]).host == "personastack.ericgreer.info",
    LaunchConfiguration.url(arguments: ["PersonaStack"], packagedDefaultURL: "file:///tmp/test") == NavigationPolicy.defaultURL,
    LaunchConfiguration.url(arguments: ["PersonaStack", "--personastack-url", "file:///tmp/test"]) == NavigationPolicy.defaultURL,
    NavigationPolicy.keepsInApp(URL(string: "https://test.example/user/personas")!, appURL: URL(string: "https://test.example")!),
    NavigationPolicy.isGoogleOAuthURL(URL(string: "https://accounts.google.com/gsi/select")!),
    !NavigationPolicy.isGoogleOAuthURL(URL(string: "https://google.com/gsi/select")!),
    NavigationPolicy.keepsInApp(URL(string: "https://personastack.ai/privacy")!),
    NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "https://example.com/docs")!, linkWasUserActivated: true),
    !NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "https://accounts.google.com/o/oauth2/auth")!, linkWasUserActivated: false),
    !NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "https://test.example/user/personas")!, linkWasUserActivated: true, appURL: URL(string: "https://test.example")!),
    NotificationBridge.isNewConcernEvent(["version": "1", "event": "created"]),
    !NotificationBridge.isNewConcernEvent(["version": "1", "event": "created", "message": "private"]),
    !NotificationBridge.isNewConcernEvent(["version": "2", "event": "created"]),
    window.titleVisibility == .hidden,
    window.titlebarAppearsTransparent,
    window.styleMask.contains(.fullSizeContentView),
    window.toolbar == nil,
]

guard checks.allSatisfy({ $0 }) else {
    fputs("PersonaStack navigation policy check failed.\n", stderr)
    exit(EXIT_FAILURE)
}

print("PersonaStack navigation policy check passed.")
