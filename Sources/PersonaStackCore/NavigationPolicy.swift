import Foundation

public enum NavigationPolicy {
    public static let defaultURL = URL(string: "http://personastack-ai.lan/user/personas")!
    public static let appHosts: Set<String> = ["my.personastack.ai", "personastack.ai", "personastack-ai.lan"]

    public static func keepsInApp(_ url: URL) -> Bool {
        isAppHost(url.host)
    }

    public static func isAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return appHosts.contains(host) || host.hasSuffix(".personastack.ai")
    }

    public static func shouldOpenInDefaultBrowser(_ url: URL, linkWasUserActivated: Bool) -> Bool {
        linkWasUserActivated && !keepsInApp(url)
    }
}
