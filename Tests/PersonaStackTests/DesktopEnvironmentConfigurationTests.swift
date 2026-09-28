import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopEnvironmentConfigurationTests {
    @Test
    func normalizesSchemesHostsDefaultPortsAndTrailingSlashes() throws {
        let configuration = try DesktopEnvironmentConfiguration(
            appURL: "  HTTPS://EXAMPLE.COM:443/ ",
            gatewayURL: "http://LOCALHOST:80/",
            mcpURL: "https://[::1]:8443/"
        )

        #expect(configuration.appURL.absoluteString == "https://example.com")
        #expect(configuration.gatewayURL.absoluteString == "http://localhost")
        #expect(configuration.mcpURL.absoluteString == "https://[::1]:8443")
        #expect(configuration.appPageURL.absoluteString == "https://example.com/user/personas")
        #expect(configuration.gatewayWebsocketURL.absoluteString == "ws://localhost/v1/desktop-control/ws")
        #expect(configuration.mcpEndpointURL.absoluteString == "https://[::1]:8443/v1/mcp")
    }

    @Test
    func rejectsUnsupportedOrNonBaseURLs() throws {
        for invalid in ["", "example.com", "file:///tmp/app", "ftp://example.com", "https:///missing",
                        "https://user:pass@example.com", "https://example.com/path", "https://example.com/?q=1",
                        "https://example.com/#fragment", "https://example.com:70000"] {
            #expect(throws: DesktopEnvironmentConfigurationError.invalidURL(.app)) {
                try DesktopEnvironmentConfiguration(appURL: invalid, gatewayURL: "https://gateway.example", mcpURL: "https://mcp.example")
            }
        }
        #expect(throws: DesktopEnvironmentConfigurationError.invalidURL(.app)) {
            try DesktopEnvironmentConfiguration(appURL: "http://my.personastack.lan", gatewayURL: "http://gateway.example", mcpURL: "http://mcp.example")
        }
    }

    @Test
    func customDiagnosticOriginRequiresExplicitServiceURLs() throws {
        let appURL = URL(string: "http://127.0.0.1:8080/user/personas")!
        #expect(throws: DesktopEnvironmentConfigurationError.unconfiguredEnvironment) {
            try DesktopEnvironmentConfiguration.environment(appURL: appURL)
        }

        let explicit = try DesktopEnvironmentConfiguration(
            appURL: "http://127.0.0.1:8080", gatewayURL: "http://127.0.0.1:8081", mcpURL: "http://127.0.0.1:8082"
        )
        #expect(explicit.gatewayWebsocketURL.absoluteString == "ws://127.0.0.1:8081/v1/desktop-control/ws")
        #expect(explicit.mcpEndpointURL.absoluteString == "http://127.0.0.1:8082/v1/mcp")
        #expect(!explicit.permitsMCP(URL(string: "https://mcp.personastack.ai/v1/mcp")!, for: appURL))
    }

    @Test
    func persistsCompleteConfigurationAndIsolatesEnvironmentPreferences() throws {
        let suite = "DesktopEnvironmentConfigurationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let firstStore = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let selected = try DesktopEnvironmentConfiguration(
            appURL: "http://personastack.lan/", gatewayURL: "http://gateway.lan/", mcpURL: "http://mcp.lan/"
        )
        try firstStore.save(selected)

        let reopenedStore = DesktopEnvironmentConfigurationStore(preferences: preferences)
        #expect(try reopenedStore.load() == selected)
        #expect(DesktopControlPreferenceKeys.relayEnabled(selected) != DesktopControlPreferenceKeys.relayEnabled(.production))
        #expect(DesktopControlPreferenceKeys.relayEnabled(.production) != DesktopControlPreferenceKeys.relayEnabled(.lan))
    }

    @Test
    func corruptSettingsAreReportedInsteadOfTreatedAsMissing() throws {
        let suite = "DesktopEnvironmentConfigurationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(Data("not-json".utf8), forKey: "desktopEnvironmentConfiguration.v1")
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)

        #expect(store.hasStoredValue())
        #expect(throws: DesktopEnvironmentConfigurationError.invalidStoredConfiguration) { try store.load() }
    }

    @Test
    func migratesLegacyRelayFlagsIntoProductionScopeOnlyOnce() throws {
        let suite = "DesktopEnvironmentConfigurationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "desktopControlRelayEnabled")
        preferences.set(true, forKey: "desktopControlRelayPaused")

        _ = DesktopEnvironmentConfigurationStore(preferences: preferences, legacyMigrationTarget: .production)

        #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
        #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayPaused(.production)))
        #expect(preferences.object(forKey: "desktopControlRelayEnabled") == nil)
        #expect(preferences.object(forKey: "desktopControlRelayPaused") == nil)
    }

    @Test
    func migratesLegacyRelayFlagsToTheSelectedKnownEnvironment() throws {
        let suite = "DesktopEnvironmentConfigurationTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "desktopControlRelayEnabled")

        _ = DesktopEnvironmentConfigurationStore(preferences: preferences, legacyMigrationTarget: .lan)

        #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.lan)))
        #expect(!preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
    }
}
