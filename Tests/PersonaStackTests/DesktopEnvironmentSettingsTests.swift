import Foundation
import PersonaStackCore
import Testing
import WebKit
@testable import PersonaStack

@Suite(.serialized)
struct DesktopEnvironmentSettingsTests {
    @Test @MainActor
    func customDiagnosticAppURLLoadsWithoutGrantingNativeServiceTrust() throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let diagnosticURL = URL(string: "http://diagnostic.example:8080/user/personas")!

        let settings = DesktopEnvironmentSettings(store: store, launchURL: diagnosticURL)

        #expect(settings.appPageURL == diagnosticURL)
        #expect(settings.hasTrustedConfiguration == false)
        #expect(settings.draftAppURL == "http://diagnostic.example:8080")
        #expect(settings.draftGatewayURL.isEmpty)
        #expect(settings.draftMCPURL.isEmpty)
        #expect(throws: DesktopEnvironmentConfigurationError.unconfiguredEnvironment) {
            try store.environment(for: diagnosticURL)
        }
    }

    @Test @MainActor
    func corruptSavedProfileUsesOnlyTheLocalFallbackUntilRepaired() throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(Data("not-json".utf8), forKey: "desktopEnvironmentConfiguration.v1")
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let packagedURL = URL(string: "https://my.personastack.ai/user/personas")!

        let settings = DesktopEnvironmentSettings(store: store, launchURL: packagedURL)

        #expect(settings.appPageURL == NavigationPolicy.defaultURL)
        #expect(settings.hasTrustedConfiguration == false)
        #expect(settings.errorMessage == DesktopEnvironmentConfigurationError.invalidStoredConfiguration.localizedDescription)
    }

    @Test @MainActor
    func wrongTypeSavedProfileIsReportedAsCorrupt() throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("not-data", forKey: "desktopEnvironmentConfiguration.v1")
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)

        #expect(throws: DesktopEnvironmentConfigurationError.invalidStoredConfiguration) { try store.current() }
    }

    @Test @MainActor
    func applyPersistsThenReplacesHostAndCompletesSwitchInOrder() async throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let lifecycle = SettingsLifecycleFixture()
        let settings = DesktopEnvironmentSettings(store: store, lifecycle: lifecycle)
        let next = try DesktopEnvironmentConfiguration(
            appURL: "http://app.example:8080/", gatewayURL: "http://gateway.example:8081/", mcpURL: "http://mcp.example:8082/"
        )

        #expect(await settings.apply(next))
        #expect(try store.load() == next)
        #expect(settings.configuration == next)
        #expect(settings.appPageURL == next.appPageURL)
        #expect(lifecycle.events == ["begin", "prepare", "wait", "replace", "complete"])
    }

    @Test @MainActor
    func cleanupFailureDoesNotPersistOrReplaceSelectedEnvironment() async throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let lifecycle = SettingsLifecycleFixture()
        lifecycle.prepareError = DesktopEnvironmentConfigurationError.invalidStoredConfiguration
        let settings = DesktopEnvironmentSettings(store: store, lifecycle: lifecycle)
        let next = try DesktopEnvironmentConfiguration(
            appURL: "http://app.example:8080", gatewayURL: "http://gateway.example:8081", mcpURL: "http://mcp.example:8082"
        )

        #expect(await settings.apply(next) == false)
        #expect(try store.load() == nil)
        #expect(settings.configuration == .production)
        #expect(lifecycle.events == ["begin", "prepare", "abort"])
    }

    @Test @MainActor
    func unchangedSaveRetriesAfterAnAbortedEnvironmentSwitch() async throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let lifecycle = SettingsLifecycleFixture()
        lifecycle.prepareError = DesktopEnvironmentConfigurationError.invalidStoredConfiguration
        let settings = DesktopEnvironmentSettings(store: store, lifecycle: lifecycle)
        let next = try DesktopEnvironmentConfiguration(
            appURL: "http://app.example:8080", gatewayURL: "http://gateway.example:8081", mcpURL: "http://mcp.example:8082"
        )

        #expect(await settings.apply(next) == false)
        lifecycle.prepareError = nil
        #expect(await settings.apply(.production))
        #expect(lifecycle.events == ["begin", "prepare", "abort", "begin", "prepare", "wait", "replace", "complete"])
        #expect(try store.load() == .production)
    }

    @Test @MainActor
    func oldBridgeCannotOpenPopoutDuringSuspendedCleanup() async throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let lifecycle = SettingsLifecycleFixture()
        lifecycle.suspendPrepare = true
        let settings = DesktopEnvironmentSettings(
            store: DesktopEnvironmentConfigurationStore(preferences: preferences), lifecycle: lifecycle
        )
        let next = try DesktopEnvironmentConfiguration(
            appURL: "http://app.example:8080", gatewayURL: "http://gateway.example:8081", mcpURL: "http://mcp.example:8082"
        )
        let applyTask = Task { await settings.apply(next) }
        while !lifecycle.isPrepareSuspended { await Task.yield() }

        #expect(lifecycle.openPopoutFromOldPage() == false)
        lifecycle.resumePrepare()
        #expect(await applyTask.value)
        #expect(lifecycle.openedPopouts == 0)
    }

    @Test @MainActor
    func overlappingApplyIsRejectedUntilTheFirstEnvironmentSwitchCompletes() async throws {
        let suite = "DesktopEnvironmentSettingsTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = DesktopEnvironmentConfigurationStore(preferences: preferences)
        let lifecycle = SettingsLifecycleFixture()
        lifecycle.suspendPrepare = true
        let settings = DesktopEnvironmentSettings(store: store, lifecycle: lifecycle)
        let next = try DesktopEnvironmentConfiguration(
            appURL: "http://app.example:8080", gatewayURL: "http://gateway.example:8081", mcpURL: "http://mcp.example:8082"
        )
        let first = Task { await settings.apply(next) }
        while !lifecycle.isPrepareSuspended { await Task.yield() }

        #expect(await settings.apply(.production) == false)
        lifecycle.resumePrepare()
        #expect(await first.value)
        #expect(lifecycle.events == ["begin", "prepare", "wait", "replace", "complete"])
    }

    @Test @MainActor
    func bridgeInvalidationRetainsPageRegistrationForTheNextNavigation() throws {
        let manager = DesktopControlSetupManager()
        let view = WKWebView()
        let appURL = URL(string: "https://my.personastack.ai")!
        manager.register(view, appURL: appURL)
        let page = try #require(manager.registeredPage(for: view))
        page.setupScope.synchronize("old-page")

        manager.invalidate(view)

        #expect(manager.registeredPage(for: view) === page)
        #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try page.setupScope.require("old-page") }
        page.setupScope.synchronize("new-page")
        try page.setupScope.require("new-page")
        manager.unregister(view)
        #expect(manager.registeredPage(for: view) == nil)
    }
}

@MainActor
private final class SettingsLifecycleFixture: DesktopEnvironmentSettingsLifecycle {
    private(set) var events: [String] = []
    private(set) var openedPopouts = 0
    var prepareError: Error?
    var suspendPrepare = false
    private var oldPageBridgeRegistered = true
    private var pendingPrepare: CheckedContinuation<Void, Never>?
    var isPrepareSuspended: Bool { pendingPrepare != nil }

    func beginSwitch() {
        events.append("begin")
        oldPageBridgeRegistered = false
    }
    func prepareForSwitch() async throws {
        events.append("prepare")
        if suspendPrepare {
            await withCheckedContinuation { pendingPrepare = $0 }
        }
        if let prepareError { throw prepareError }
    }
    func waitForLocalSessions() async { events.append("wait") }
    func replaceHost(with appPageURL: URL) { events.append("replace") }
    func completeSwitch() { events.append("complete") }
    func abortSwitch() {
        events.append("abort")
        oldPageBridgeRegistered = true
    }
    func openPopoutFromOldPage() -> Bool {
        guard oldPageBridgeRegistered else { return false }
        openedPopouts += 1
        return true
    }
    func resumePrepare() {
        let continuation = pendingPrepare
        pendingPrepare = nil
        continuation?.resume()
    }
}
