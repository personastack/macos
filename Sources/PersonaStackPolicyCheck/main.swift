import AppKit
import Foundation
import PersonaStackCore

let window = NSWindow(
    contentRect: .zero,
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
WindowPresentation.configure(window)

let checks = [
    NavigationPolicy.keepsInApp(URL(string: "https://my.personastack.ai/user/personas")!),
    NavigationPolicy.keepsInApp(NavigationPolicy.defaultURL),
    NavigationPolicy.keepsInApp(URL(string: "https://personastack.ai/privacy")!),
    NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "https://example.com/docs")!, linkWasUserActivated: true),
    !NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "https://accounts.google.com/o/oauth2/auth")!, linkWasUserActivated: false),
    !NavigationPolicy.shouldOpenInDefaultBrowser(URL(string: "http://personastack-ai.lan/user/personas")!, linkWasUserActivated: true),
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
