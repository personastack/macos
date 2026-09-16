import Foundation

public enum NavigationPolicy {
    public static let defaultURL = URL(string: "https://my.personastack.ai/user/personas")!
    public static let appHosts: Set<String> = [
        "my.personastack.ai",
        "personastack.ai",
        "personastack.ericgreer.info",
    ]

    public static func keepsInApp(_ url: URL, appURL: URL? = nil) -> Bool {
        isAppHost(url.host) || url.host?.caseInsensitiveCompare(appURL?.host ?? "") == .orderedSame
    }

    public static func isAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return appHosts.contains(host) || host.hasSuffix(".personastack.ai")
    }

    public static func isGoogleOAuthURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "accounts.google.com"
    }

    public static func shouldOpenInDefaultBrowser(_ url: URL, linkWasUserActivated: Bool, appURL: URL? = nil) -> Bool {
        linkWasUserActivated && !keepsInApp(url, appURL: appURL)
    }
}

public enum LaunchConfiguration {
    public static func url(arguments: [String] = CommandLine.arguments) -> URL {
        guard let flagIndex = arguments.firstIndex(of: "--personastack-url"),
              arguments.indices.contains(flagIndex + 1),
              let url = URL(string: arguments[flagIndex + 1]),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return NavigationPolicy.defaultURL
        }
        return url
    }
}
