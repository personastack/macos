import Foundation

public enum DesktopEnvironmentField: String, Codable, Sendable {
    case app
    case gateway
    case mcp
}

public enum DesktopEnvironmentConfigurationError: Error, Equatable, Sendable {
    case invalidURL(DesktopEnvironmentField)
    case invalidStoredConfiguration
    case unconfiguredEnvironment
}

extension DesktopEnvironmentConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(.app): "Enter an HTTP or HTTPS base URL for the PersonaStack app."
        case .invalidURL(.gateway): "Enter an HTTP or HTTPS base URL for the PersonaStack Agent Gateway."
        case .invalidURL(.mcp): "Enter an HTTP or HTTPS base URL for the PersonaStack MCP service."
        case .invalidStoredConfiguration: "Saved PersonaStack server settings are invalid. Review the three server URLs and save them again."
        case .unconfiguredEnvironment: "This app URL has no trusted Gateway or MCP settings. Enter all three service URLs in Server Settings."
        }
    }
}

public struct DesktopEnvironmentConfiguration: Codable, Equatable, Sendable {
    private static let settingsKey = "desktopEnvironmentConfiguration.v1"
    private static let productionRawValues = (
        app: "https://my.personastack.ai",
        gateway: "https://cluster-agent.personastack.ai",
        mcp: "https://mcp.personastack.ai"
    )
    private static let retiredAppHosts: Set<String> = ["my.personastack.lan"]

    public let appURL: URL
    public let gatewayURL: URL
    public let mcpURL: URL

    public init(appURL: String, gatewayURL: String, mcpURL: String) throws {
        self.appURL = try Self.baseURL(appURL, field: .app)
        self.gatewayURL = try Self.baseURL(gatewayURL, field: .gateway)
        self.mcpURL = try Self.baseURL(mcpURL, field: .mcp)
    }

    public var appPageURL: URL { endpoint(appURL, path: "/user/personas") }
    public var gatewayWebsocketURL: URL { endpoint(gatewayURL, path: "/v1/desktop-control/ws", websocket: true) }
    public var mcpEndpointURL: URL { endpoint(mcpURL, path: "/v1/mcp") }

    public var appOrigin: String { appURL.absoluteString }
    public var preferenceIdentity: String {
        [appURL.absoluteString, gatewayURL.absoluteString, mcpURL.absoluteString].joined(separator: "|")
    }

    public func permitsMCP(_ endpoint: URL, for appURL: URL) -> Bool {
        guard appURL.user == nil, appURL.password == nil,
              let selectedOrigin = Self.normalizedOrigin(appURL), selectedOrigin == appOrigin else { return false }
        return Self.sameEndpoint(endpoint, mcpEndpointURL)
    }

    public static let production: DesktopEnvironmentConfiguration = {
        // These bundled constants are fixed and parsed by the same validation path as user input.
        try! DesktopEnvironmentConfiguration(
            appURL: productionRawValues.app,
            gatewayURL: productionRawValues.gateway,
            mcpURL: productionRawValues.mcp
        )
    }()

    public static let lan: DesktopEnvironmentConfiguration = {
        try! DesktopEnvironmentConfiguration(
            appURL: "https://personastack.ericgreer.info",
            gatewayURL: "http://cluster-agent.personastack.lan",
            mcpURL: "http://mcp.personastack.lan"
        )
    }()

    public static func environment(appURL: URL) throws -> DesktopEnvironmentConfiguration {
        if let configuration = [production, lan].first(where: {
            $0.appURL.host?.lowercased() == appURL.host?.lowercased()
                && $0.appURL.scheme?.lowercased() == appURL.scheme?.lowercased()
                && $0.appURL.port == appURL.port
        }) {
            return configuration
        }
        throw DesktopEnvironmentConfigurationError.unconfiguredEnvironment
    }

    private static func baseURL(_ rawValue: String, field: DesktopEnvironmentField) throws -> URL {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw DesktopEnvironmentConfigurationError.invalidURL(field)
        }

        if field == .app, let host = parts.host?.lowercased(), retiredAppHosts.contains(host) {
            throw DesktopEnvironmentConfigurationError.invalidURL(field)
        }

        parts.scheme = scheme
        parts.host = host.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        parts.path = ""
        guard let url = parts.url else { throw DesktopEnvironmentConfigurationError.invalidURL(field) }
        return url
    }

    private func endpoint(_ base: URL, path: String, websocket: Bool = false) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        if websocket { parts.scheme = parts.scheme == "https" ? "wss" : "ws" }
        parts.path = path
        return parts.url!
    }

    fileprivate static func normalizedOrigin(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        var normalized = parts
        normalized.scheme = scheme
        normalized.host = parts.host?.lowercased()
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { normalized.port = nil }
        normalized.path = ""
        normalized.query = nil
        normalized.fragment = nil
        return normalized.string
    }

    private static func sameEndpoint(_ actual: URL, _ expected: URL) -> Bool {
        guard let actual = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && actual.port == expected.port
            && actual.path == expected.path
            && actual.user == nil && actual.password == nil
            && actual.query == nil && actual.fragment == nil
    }
}

/// One local settings record keeps the selected app and native service endpoints together.
public final class DesktopEnvironmentConfigurationStore: @unchecked Sendable {
    public static let shared = DesktopEnvironmentConfigurationStore()

    private let lock = NSLock()
    private let preferences: UserDefaults
    private let migrationLock = NSLock()
    private let legacyMigrationTarget: DesktopEnvironmentConfiguration?

    public init(preferences: UserDefaults = .standard,
                legacyMigrationTarget: DesktopEnvironmentConfiguration? = nil) {
        self.preferences = preferences
        self.legacyMigrationTarget = legacyMigrationTarget
            ?? (try? DesktopEnvironmentConfiguration.environment(appURL: LaunchConfiguration.url()))
        migrateLegacyPreferences()
    }

    public func load() throws -> DesktopEnvironmentConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedValue = preferences.object(forKey: "desktopEnvironmentConfiguration.v1") else { return nil }
        guard let data = storedValue as? Data else {
            throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration
        }
        guard let configuration = try? JSONDecoder().decode(DesktopEnvironmentConfiguration.self, from: data),
              (try? DesktopEnvironmentConfiguration(
                appURL: configuration.appURL.absoluteString,
                gatewayURL: configuration.gatewayURL.absoluteString,
                mcpURL: configuration.mcpURL.absoluteString
              )) == configuration else {
            throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration
        }
        return configuration
    }

    public func hasStoredValue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return preferences.object(forKey: "desktopEnvironmentConfiguration.v1") != nil
    }

    public func current(fallbackAppURL: URL = DesktopEnvironmentConfiguration.production.appPageURL) throws -> DesktopEnvironmentConfiguration {
        if let configuration = try load() { return configuration }
        return try DesktopEnvironmentConfiguration.environment(appURL: fallbackAppURL)
    }

    public func environment(for appURL: URL) throws -> DesktopEnvironmentConfiguration {
        if let configuration = try load() {
            guard DesktopEnvironmentConfiguration.normalizedOrigin(appURL) == configuration.appOrigin else {
                throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration
            }
            return configuration
        }
        let configuration = try DesktopEnvironmentConfiguration.environment(appURL: appURL)
        guard DesktopEnvironmentConfiguration.normalizedOrigin(appURL) == configuration.appOrigin else {
            throw DesktopEnvironmentConfigurationError.invalidStoredConfiguration
        }
        return configuration
    }

    public func save(_ configuration: DesktopEnvironmentConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        lock.lock()
        defer { lock.unlock() }
        preferences.set(data, forKey: "desktopEnvironmentConfiguration.v1")
    }

    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        preferences.removeObject(forKey: "desktopEnvironmentConfiguration.v1")
    }

    private func migrateLegacyPreferences() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        let marker = "desktopEnvironmentConfiguration.legacyPreferencesMigrated.v1"
        guard !preferences.bool(forKey: marker) else { return }
        for key in ["desktopControlRelayEnabled", "desktopControlRelayPaused", "desktopControlRelayError"] {
            let value = preferences.object(forKey: key)
            guard value != nil else { continue }
            if let legacyMigrationTarget {
                preferences.set(value, forKey: Self.scopedPreferenceKey(key, appOrigin: legacyMigrationTarget.preferenceIdentity))
            }
            preferences.removeObject(forKey: key)
        }
        preferences.set(true, forKey: marker)
    }

    public static func scopedPreferenceKey(_ key: String, appOrigin: String) -> String {
        "\(key).\(appOrigin)"
    }
}

public enum DesktopControlPreferenceKeys {
    public static func relayEnabled(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("desktopControlRelayEnabled", appOrigin: configuration.preferenceIdentity)
    }

    public static func relayPaused(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("desktopControlRelayPaused", appOrigin: configuration.preferenceIdentity)
    }

    public static func relayError(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("desktopControlRelayError", appOrigin: configuration.preferenceIdentity)
    }
}
