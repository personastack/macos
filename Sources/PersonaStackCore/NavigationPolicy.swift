import Foundation

public enum NavigationPolicy {
    // Unpackaged development builds stay on localhost. Installer builds replace
    // this value with the environment-specific URL from PersonaStackDefaultURL.
    public static let defaultURL = URL(string: "http://127.0.0.1:8080/user/personas")!
    public static let appHosts: Set<String> = [
        "my.personastack.ai",
        "personastack.ai",
        "personastack.ericgreer.info",
    ]

    public static func keepsInApp(_ url: URL, appURL: URL? = nil) -> Bool {
        guard let appURL else { return isAppHost(url.host) }
        guard let target = normalizedOrigin(url), target == normalizedOrigin(appURL) else { return false }
        return true
    }

    public static func isAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return appHosts.contains(host) || host.hasSuffix(".personastack.ai")
    }

    public static func isGoogleOAuthURL(_ url: URL) -> Bool {
        canOpenExternally(url) && url.scheme?.lowercased() == "https" && url.host?.lowercased() == "accounts.google.com"
    }

    public static func canOpenExternally(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host != nil && url.user == nil && url.password == nil
        case "mailto":
            return !url.path.isEmpty
        default:
            return false
        }
    }

    public static func canLoadInWebView(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return canOpenExternally(url)
        case "about", "blob", "data": return true
        default: return false
        }
    }

    public static func shouldDownload(_ url: URL, requested: Bool, appURL: URL) -> Bool {
        guard requested else { return false }
        if url.scheme?.lowercased() == "blob" {
            guard let originURL = URL(string: String(url.absoluteString.dropFirst(5))) else { return false }
            return keepsInApp(originURL, appURL: appURL)
        }
        return keepsInApp(url, appURL: appURL)
    }

    private static func normalizedOrigin(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }

    public static func shouldOpenInDefaultBrowser(_ url: URL, linkWasUserActivated: Bool, appURL: URL? = nil) -> Bool {
        linkWasUserActivated && canOpenExternally(url) && !keepsInApp(url, appURL: appURL)
    }
}

public enum LaunchConfiguration {
    public static func selectedEnvironment() throws -> DesktopEnvironmentConfiguration {
        try DesktopEnvironmentConfigurationStore.shared.current(fallbackAppURL: url())
    }

    public static func selectedURL() -> URL {
        let store = DesktopEnvironmentConfigurationStore.shared
        do {
            if let configuration = try store.load() { return configuration.appPageURL }
        } catch {
            return NavigationPolicy.defaultURL
        }
        return store.hasStoredValue() ? NavigationPolicy.defaultURL : url()
    }

    public static func url(arguments: [String] = CommandLine.arguments) -> URL {
        url(
            arguments: arguments,
            packagedDefaultURL: Bundle.main.object(forInfoDictionaryKey: "PersonaStackDefaultURL") as? String
        )
    }

    public static func url(arguments: [String], packagedDefaultURL: String?) -> URL {
        let overrideURL = arguments.firstIndex(of: "--personastack-url")
            .flatMap { arguments.indices.contains($0 + 1) ? validHTTPURL(arguments[$0 + 1]) : nil }
        return overrideURL ?? validHTTPURL(packagedDefaultURL) ?? NavigationPolicy.defaultURL
    }

    private static func validHTTPURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            return nil
        }
        return url
    }
}
