import Foundation

public enum NavigationPolicy {
    public static let appHosts: Set<String> = ["my.personastack.ai", "personastack.ai"]

    public static func keepsInApp(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return appHosts.contains(host) || host.hasSuffix(".personastack.ai")
    }

    public static func shouldOpenInDefaultBrowser(_ url: URL, linkWasUserActivated: Bool) -> Bool {
        linkWasUserActivated && !keepsInApp(url)
    }
}
