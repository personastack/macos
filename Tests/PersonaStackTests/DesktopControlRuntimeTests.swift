import AppKit
import Foundation
@testable import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack


private func waitForCredentialRead(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private actor DesktopControlInstallerFixture: DesktopControlDriverInstalling {
    private let errors: [any Error]
    private(set) var repairArguments: [Bool] = []

    init(errors: [any Error]) { self.errors = errors }

    func discoverExisting() async throws -> CuaDriverInstallation? {
        repairArguments.append(false)
        throw errors.first ?? CuaDriverInstallError.invalidLayout
    }
    func install() async throws -> CuaDriverInstallation {
        repairArguments.append(true)
        throw errors.first ?? CuaDriverInstallError.invalidLayout
    }
}


private struct EmptyDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

private final class PermissionPreparationCredentialStore: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let installation: DesktopControlInstallation?
    init(installation: DesktopControlInstallation?) { self.installation = installation }
    var readCount: Int { lock.withLock { reads } }
    func load() throws -> DesktopControlInstallation? { lock.withLock { reads += 1; return installation } }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Permission preparation cannot save enrollment") }
    func delete() throws { Issue.record("Permission preparation cannot delete enrollment") }
}

private struct DeniedDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
    func delete() throws {}
}

private struct MainThreadRejectingCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? {
        if Thread.isMainThread { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        return nil
    }
    func delete() throws {}
}

private final class SuspendedDesktopControlCredentialStore: DesktopControlCredentialStoring, @unchecked Sendable {
    let readStarted = DispatchSemaphore(value: 0)
    let continueRead = DispatchSemaphore(value: 0)
    private let installation: DesktopControlInstallation
    private let waitSeconds: Double

    init(installation: DesktopControlInstallation, waitSeconds: Double = 2) {
        self.installation = installation
        self.waitSeconds = waitSeconds
    }

    func save(_ installation: DesktopControlInstallation) throws {}

    func load() throws -> DesktopControlInstallation? {
        readStarted.signal()
        guard continueRead.wait(timeout: .now() + waitSeconds) == .success else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        return installation
    }

    func delete() throws {}
}


@Test @MainActor func startupReadsKeychainAwayFromTheMainActor() async {
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: MainThreadRejectingCredentialStore()
    )
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await runtime.resume() }
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await runtime.startPaused() }
}

@Test @MainActor func setupStateReadsKeychainAwayFromTheMainActor() async throws {
    let appURL = URL(string: "https://my.personastack.ai")!
    let credentials = MainThreadRejectingCredentialStore()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    let runtimeState = try await DesktopControlSetupManager(runtime: runtime).apply(.state(scope: ""), page: page)
    #expect(runtimeState["installation_id"] is NSNull)

    let injectedState = try await DesktopControlSetupManager(
        runtime: DesktopControlSetupRuntimeFixture(), credentials: credentials
    ).apply(.state(scope: ""), page: page)
    #expect(injectedState["installation_id"] is NSNull)
}

@Test @MainActor func unregisterFencesQueuedSetupCallbacks() async throws {
    let appURL = URL(string: "https://my.personastack.ai")!
    let runtime = DesktopControlSetupRuntimeFixture()
    let manager = DesktopControlSetupManager(runtime: runtime)
    let view = WKWebView()
    manager.register(view, appURL: appURL)
    let page = try #require(manager.registeredPage(for: view))
    var replyError: String?

    manager.dispatch(["version": "1", "action": "sync", "scope": ""], page: page) { _, error in
        replyError = error
    }
    manager.unregister(view)
    await Task.yield()

    #expect(replyError != nil)
    #expect(runtime.finishSetupCalls == 0)
    #expect(manager.registeredPage(for: view) == nil)
}

@Test @MainActor func localStopFencesAdmissionBeforeAsyncCleanupStarts() async throws {
    let connection = UUID()
    let installation = try boundKeychainRecoveryInstallation()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: EmptyDesktopControlCredentialStore(),
        connectionID: connection, installation: installation, connected: true, readiness: "ready", sessionLockState: .unlocked)
    let generation = try #require(runtime.beginPause())
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(throws: CancellationError.self) { try runtime.beginResume() }
    #expect(throws: CancellationError.self) { try runtime.beginRepair() }
    #expect(runtime.beginPause() == nil)
    #expect(runtime.isCurrentLifecycle(generation))
    let target = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace", configID: "config",
                                      personaID: "persona", runID: "run", generation: 1)
    let frame = DesktopControlFrame(type: "command", requestID: "stopped", target: target,
                                     operation: "desktop_control_acquire", arguments: .object([:]),
                                     deadlineAt: Date().addingTimeInterval(30))
    #expect(await runtime.handleForTesting(frame, connectionID: connection).errorCode == "desktop_paused")
    await runtime.pause(generation: generation)
    #expect(throws: Never.self) { try runtime.beginResume() }
}


private struct SavedDesktopControlCredentialStore: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation

    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { installation }
    func delete() throws {}
}

@Test @MainActor func quitFencesTheRelayAndLeavesEnrollmentForNextLaunch() async throws {
    let payload = Data(#"{"installation_id":"installation-quit","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let executor = DesktopControlCommandExecutor()
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace", configID: "config",
                                     personaID: "persona", runID: "run", generation: 1, configVersion: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "quit-power-acquire", target: owner,
                                      operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: Date().addingTimeInterval(45))
    #expect(await executor.handle(acquire, proxy: nil).type == "result")
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        executor: executor, installation: installation, connected: true, readiness: "ready")
    let generation = try runtime.beginResume()

    await runtime.shutdownForQuit()

    #expect(!runtime.isCurrentLifecycle(generation))
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasActiveInstallation)
    #expect(executor.currentLease == nil)
}


@Test @MainActor func environmentSwitchStopsLocalControlButKeepsTheOldEnrollment() async throws {
    let payload = Data(#"{"installation_id":"installation-switch","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        installation: installation,
        connected: true,
        readiness: "ready"
    )

    try await runtime.prepareForEnvironmentSwitch()

    #expect(runtime.paused)
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasActiveInstallation)
    #expect(runtime.readiness == "unknown")
    #expect(try await runtime.savedInstallationForTesting()?.installationID == installation.installationID)
}

@Test @MainActor func setupCredentialReadCannotRestoreOldInstallationAfterEnvironmentSwitch() async throws {
    let payload = Data(#"{"installation_id":"installation-late-read","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(DesktopEnvironmentConfiguration.production.appPageURL,
                                     configuration: .production)
    // The read is released explicitly after environment cleanup. Allow the
    // parallel AppKit suite to run without the fixture manufacturing an error.
    let credentials = SuspendedDesktopControlCredentialStore(installation: installation, waitSeconds: 10)
    let changed = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai",
        gatewayURL: "https://gateway-alt.example",
        mcpURL: "https://mcp-alt.example"
    )
    var selectedConfiguration = DesktopEnvironmentConfiguration.production
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: credentials,
        configurationProvider: { selectedConfiguration }
    )
    let finishingSetup = Task { @MainActor in try await runtime.finishSetupIfIdle() }
    let readStarted = await Task.detached { waitForCredentialRead(credentials.readStarted) }.value
    #expect(readStarted)

    try await runtime.prepareForEnvironmentSwitch()
    selectedConfiguration = changed
    runtime.completeEnvironmentSwitch()
    credentials.continueRead.signal()
    await #expect(throws: CancellationError.self) { try await finishingSetup.value }

    #expect(!runtime.hasActiveInstallation)
}

@Test @MainActor func savedInstallationValidatesProfileBeforeCachingCredential() async throws {
    let payload = Data(#"{"installation_id":"installation-wrong-gateway","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://unrelated.example/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation)
    )

    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await runtime.savedInstallation(for: URL(string: "https://my.personastack.ai/user/personas")!)
    }

    #expect(!runtime.hasActiveInstallation)
}


@MainActor
private final class DesktopControlSetupRuntimeFixture: DesktopControlSetupRuntime {
    func refreshCuaReadiness() async -> Bool { ready }
    private(set) var attempts = 0
    private(set) var repairAttempts = 0
    private(set) var gatewayConnected = false
    private(set) var paused = false
    private(set) var ready = false
    private(set) var connectedInstallationID = ""
    private(set) var finishSetupCalls = 0
    private(set) var disconnectCalls = 0
    var permissionGranted = false
    var disconnectError: (any Error)?
    private var generation = UUID()
    var readiness: String { ready ? "ready" : "permission_required" }

    func isCuaReady() -> Bool { ready }

    func beginResume() throws -> UUID {
        generation = UUID()
        return generation
    }

    func resume(generation: UUID) async throws {
        guard isCurrentLifecycle(generation) else { throw CancellationError() }
        attempts += 1
        guard permissionGranted else { throw CuaMCPProxyError.permissionsRequired }
        ready = true
        paused = false
    }

    func resumeForSetup(generation: UUID) async throws {
        try await resume(generation: generation)
    }

    func finishSetupIfIdle() async throws { finishSetupCalls += 1 }
    func disconnect() async throws {
        disconnectCalls += 1
        if let disconnectError { throw disconnectError }
    }

    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID {
        repairAttempts += 1
        throw CuaMCPProxyError.functionalProbeFailed
    }

    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async {
        connectedInstallationID = installation.installationID
        gatewayConnected = true
    }

    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation? { nil }
}


private final class AuthorizingDesktopControlCredentialStore: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var authorizations = 0
    let installation: DesktopControlInstallation

    init(installation: DesktopControlInstallation) { self.installation = installation }
    var counts: (reads: Int, authorizations: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (reads, authorizations)
    }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Recovery must not replace credentials") }
    func delete() throws { Issue.record("Recovery must not delete credentials") }
    func load() throws -> DesktopControlInstallation? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        throw DesktopControlEnrollmentError.credentialAccessRequired
    }
    func loadWithUserInteraction() throws -> DesktopControlInstallation? {
        lock.lock()
        defer { lock.unlock() }
        authorizations += 1
        #expect(!Thread.isMainThread)
        return installation
    }
}

private func boundKeychainRecoveryInstallation() throws -> DesktopControlInstallation {
    let data = Data(#"{"installation_id":"installation-recovery","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
    try installation.bindEnvironment(DesktopEnvironmentConfiguration.production.appPageURL, configuration: .production)
    return installation
}

@Test @MainActor func pageAndStartupKeychainReadsNeverAuthorizeAndExposeExistingMenuRetry() async throws {
    let suite = "keychain-passive-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, preferences: preferences)
    await #expect(throws: DesktopControlEnrollmentError.credentialAccessRequired) { try await runtime.resume() }
    for _ in 0..<2 {
        await #expect(throws: DesktopControlEnrollmentError.credentialAccessRequired) {
            try await runtime.savedInstallation(for: DesktopEnvironmentConfiguration.production.appPageURL)
        }
    }
    #expect(credentials.counts.reads == 3 && credentials.counts.authorizations == 0)
    #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
    let error = preferences.string(forKey: DesktopControlPreferenceKeys.relayError(.production))
    #expect(error == DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription)
    #expect(!preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
}

@Test @MainActor func explicitKeychainRecoveryCachesSameIdentityWithoutResumingPausedRelay() async throws {
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, readiness: "paused", paused: true)
    let generation = try runtime.beginResume()
    try await runtime.authorizeSavedInstallation(generation: generation)
    try await runtime.authorizeSavedInstallation(generation: generation)
    let saved = try await runtime.savedInstallation(for: DesktopEnvironmentConfiguration.production.appPageURL)
    #expect(saved == credentials.installation)
    #expect(credentials.counts.reads == 0 && credentials.counts.authorizations == 1)
    #expect(runtime.paused && runtime.readiness == "paused")
    #expect(!runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await runtime.savedInstallation(for: DesktopEnvironmentConfiguration.lan.appPageURL)
    }
    #expect(credentials.counts.authorizations == 1)
}

@Test @MainActor func explicitKeychainRecoveryRejectsWrongProfileBeforeCaching() async throws {
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, configurationProvider: { .lan })
    let generation = try runtime.beginResume()
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await runtime.authorizeSavedInstallation(generation: generation)
    }
    #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected)
}

private enum KeychainRaceFixtureError: Error {
    case releaseTimedOut
}

private func waitForKeychainRaceSignal(_ semaphore: DispatchSemaphore) -> Bool {
    // Other native tests share MainActor. This guard permits runner scheduling;
    // the explicit release signal, not elapsed time, determines the interleaving.
    semaphore.wait(timeout: .now() + 10) == .success
}

private struct InterleavedKeychainCredentialStore: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation
    let failure: DesktopControlEnrollmentError
    let passiveStarted = DispatchSemaphore(value: 0)
    let continuePassive = DispatchSemaphore(value: 0)
    let authorizationStarted = DispatchSemaphore(value: 0)
    let continueAuthorization = DispatchSemaphore(value: 0)

    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Recovery must not replace credentials") }
    func delete() throws { Issue.record("Recovery must not delete credentials") }

    func load() throws -> DesktopControlInstallation? {
        passiveStarted.signal()
        guard waitForKeychainRaceSignal(continuePassive) else { throw KeychainRaceFixtureError.releaseTimedOut }
        throw failure
    }

    func loadWithUserInteraction() throws -> DesktopControlInstallation? {
        authorizationStarted.signal()
        guard waitForKeychainRaceSignal(continueAuthorization) else { throw KeychainRaceFixtureError.releaseTimedOut }
        return installation
    }
}

@Test(arguments: [false, true], [DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription,
                                DesktopControlEnrollmentError.credentialStoreUnavailable.localizedDescription,
                                "macOS Keychain could not access the Desktop Control installation. Old recovery instructions.",
                                "Desktop Control needs Keychain access. Old recovery instructions.",
                                "Cua permissions need attention", "Waiting for PersonaStack connection"]) @MainActor
func nativeKeychainAuthorizationClearsOnlyItsProfilesCredentialError(alreadyCached: Bool, message: String) async throws {
    let suite = "keychain-error-clear-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let installation = try boundKeychainRecoveryInstallation()
    let credentials = AuthorizingDesktopControlCredentialStore(installation: installation)
    let errorKey = DesktopControlPreferenceKeys.relayError(.production)
    let otherProfileKey = DesktopControlPreferenceKeys.relayError(.lan)
    preferences.set(message, forKey: errorKey)
    preferences.set(DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription, forKey: otherProfileKey)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials,
        installation: alreadyCached ? installation : nil, preferences: preferences)
    preferences.set(message, forKey: errorKey)
    try await runtime.authorizeSavedInstallation(generation: runtime.beginResume())
    let isCredentialError = message == DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription
        || message == DesktopControlEnrollmentError.credentialStoreUnavailable.localizedDescription
        || message.hasPrefix("macOS Keychain could not access") || message.hasPrefix("Desktop Control needs Keychain access.")
    #expect(preferences.string(forKey: errorKey) == (isCredentialError ? "" : message))
    #expect(preferences.string(forKey: otherProfileKey) == DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription)
    #expect(credentials.counts.authorizations == (alreadyCached ? 0 : 1))
    #expect(credentials.counts.reads == 0)
}

@Test @MainActor func obsoleteKeychainMessagesAreClearedAtStartupWithoutReadingCredentials() throws {
    let suite = "obsolete-keychain-message-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let oldAccess = "Desktop Control needs Keychain access. Old recovery instructions."
    let oldStore = "macOS Keychain could not access the Desktop Control installation. Old recovery instructions."
    let obsoleteKeys = [DesktopControlPreferenceKeys.relayError(.production),
                        DesktopControlPreferenceKeys.relayError(.lan),
                        "desktopControlRelayError", "desktopControlRepairError"]
    for (index, key) in obsoleteKeys.enumerated() {
        preferences.set(index.isMultiple(of: 2) ? oldAccess : oldStore, forKey: key)
    }
    preferences.set("Waiting for PersonaStack connection", forKey: "desktopControlRelayError.other")
    preferences.set(oldAccess, forKey: "unrelatedPreference")
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    _ = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, preferences: preferences)
    for key in obsoleteKeys { #expect(preferences.string(forKey: key) == "") }
    #expect(preferences.string(forKey: "desktopControlRelayError.other") == "Waiting for PersonaStack connection")
    #expect(preferences.string(forKey: "unrelatedPreference") == oldAccess)
    #expect(credentials.counts.reads == 0 && credentials.counts.authorizations == 0)
}

private struct DeferredLaunchCredentialStore: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation
    let denyPassiveRead: Bool
    let readStarted = DispatchSemaphore(value: 0)
    let continueRead = DispatchSemaphore(value: 0)

    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Launch must not replace credentials") }
    func delete() throws { Issue.record("Launch must not delete credentials") }
    func loadWithUserInteraction() throws -> DesktopControlInstallation? { installation }

    func load() throws -> DesktopControlInstallation? {
        readStarted.signal()
        guard waitForKeychainRaceSignal(continueRead) else { throw KeychainRaceFixtureError.releaseTimedOut }
        if denyPassiveRead { throw DesktopControlEnrollmentError.credentialAccessRequired }
        return installation
    }
}

@Test(arguments: [false, true]) @MainActor
func currentLaunchKeychainFailureStillPublishesMenuRetry(paused: Bool) async throws {
    let suite = "keychain-launch-denied-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    let otherProfileKey = DesktopControlPreferenceKeys.relayError(.lan)
    preferences.set("Other profile error", forKey: otherProfileKey)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, paused: paused, preferences: preferences)
    await runtime.startAtLaunch(configuration: .production, paused: paused)
    #expect(preferences.string(forKey: DesktopControlPreferenceKeys.relayError(.production))
            == DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription)
    #expect(preferences.string(forKey: otherProfileKey) == "Other profile error")
    #expect(credentials.counts.reads == 1 && credentials.counts.authorizations == 0)
    #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected)
}

@Test @MainActor func launchWithAlreadyChangedProfileDoesNotReadOrClearErrors() async throws {
    let suite = "keychain-launch-profile-before-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let credentials = AuthorizingDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation())
    let errorKey = DesktopControlPreferenceKeys.relayError(.production)
    preferences.set("Preserved startup error", forKey: errorKey)
    preferences.set("Preserved repair error", forKey: "desktopControlRepairError")
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials,
        preferences: preferences, configurationProvider: { .lan })
    await runtime.startAtLaunch(configuration: .production, paused: false)
    #expect(credentials.counts.reads == 0 && credentials.counts.authorizations == 0)
    #expect(preferences.string(forKey: errorKey) == "Preserved startup error")
    #expect(preferences.string(forKey: "desktopControlRepairError") == "Preserved repair error")
}

// These fixtures deliberately hold synchronous credential calls. Serialize
// their shared Security gate while keeping each case's competing operations
// concurrent and other tests parallel.
@Suite(.serialized)
struct DesktopControlKeychainRaceTests {
    @Test(arguments: [false, true]) @MainActor
    func pendingKeychainRecoveryRejectsOverlapAndCannotCommitAfterProfileOrLifecycleChange(changeLifecycle: Bool) async throws {
        let credentials = SuspendedDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation(), waitSeconds: 10)
        var selected = DesktopEnvironmentConfiguration.production
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, configurationProvider: { selected })
        let generation = try runtime.beginResume()
        let authorization = Task { @MainActor in try await runtime.authorizeSavedInstallation(generation: generation) }
        let started = await awaitKeychainRaceSignal(credentials.readStarted)
        #expect(started)
        #expect(throws: CancellationError.self) { try runtime.beginResume() }
        await #expect(throws: CancellationError.self) { try await runtime.authorizeSavedInstallation(generation: generation) }
        if changeLifecycle {
            try await runtime.prepareForEnvironmentSwitch()
            runtime.completeEnvironmentSwitch()
        } else {
            // Same App origin with a different Gateway/MCP is still a different profile.
            selected = try DesktopEnvironmentConfiguration(appURL: "https://my.personastack.ai",
                                                           gatewayURL: "https://gateway-alt.example",
                                                           mcpURL: "https://mcp-alt.example")
        }
        credentials.continueRead.signal()
        await #expect(throws: CancellationError.self) { try await authorization.value }
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        _ = try runtime.beginResume()
    }

    @Test @MainActor func passiveKeychainReadCannotCacheAfterSameOriginServerProfileChanges() async throws {
        let credentials = SuspendedDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation(), waitSeconds: 10)
        var selected = DesktopEnvironmentConfiguration.production
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []), credentials: credentials, configurationProvider: { selected })
        let read = Task { @MainActor in
            try await runtime.savedInstallation(for: DesktopEnvironmentConfiguration.production.appPageURL)
        }
        let started = await awaitKeychainRaceSignal(credentials.readStarted)
        #expect(started)
        selected = try DesktopEnvironmentConfiguration(appURL: "https://my.personastack.ai",
                                                       gatewayURL: "https://gateway-alt.example",
                                                       mcpURL: "https://mcp-alt.example")
        credentials.continueRead.signal()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!runtime.hasActiveInstallation)
    }

    @Test @MainActor func cancelledKeychainAuthorizationCannotCacheCredential() async throws {
        let credentials = SuspendedDesktopControlCredentialStore(installation: try boundKeychainRecoveryInstallation(), waitSeconds: 10)
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []), credentials: credentials)
        let generation = try runtime.beginResume()
        let authorization = Task { @MainActor in try await runtime.authorizeSavedInstallation(generation: generation) }
        let started = await awaitKeychainRaceSignal(credentials.readStarted)
        #expect(started)
        authorization.cancel()
        credentials.continueRead.signal()
        await #expect(throws: CancellationError.self) { try await authorization.value }
        #expect(!runtime.hasActiveInstallation)
        _ = try runtime.beginResume()
    }

    @Test(arguments: [false, true], [DesktopControlEnrollmentError.credentialAccessRequired, .credentialStoreUnavailable]) @MainActor
    func concurrentPassiveKeychainFailureCannotLeaveRecoveredInstallationNeedingAttention(authorizationFirst: Bool,
                                                                                         failure: DesktopControlEnrollmentError) async throws {
        let suite = "keychain-interleaving-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = InterleavedKeychainCredentialStore(installation: try boundKeychainRecoveryInstallation(), failure: failure)
        defer {
            credentials.continuePassive.signal()
            credentials.continueAuthorization.signal()
        }
        let configuration = DesktopEnvironmentConfiguration.production
        let errorKey = DesktopControlPreferenceKeys.relayError(configuration)
        let otherProfileKey = DesktopControlPreferenceKeys.relayError(.lan)
        preferences.set("Unrelated LAN connection failure", forKey: otherProfileKey)
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []), credentials: credentials,
            readiness: "paused", paused: true, preferences: preferences)
        let generation = try runtime.beginResume()
        let authorization = Task { @MainActor in try await runtime.authorizeSavedInstallation(generation: generation) }
        let authorizationStarted = await awaitKeychainRaceSignal(credentials.authorizationStarted)
        #expect(authorizationStarted)
        let passive = Task { @MainActor in try await runtime.savedInstallation(for: configuration.appPageURL) }
        let passiveStarted = await awaitKeychainRaceSignal(credentials.passiveStarted)
        #expect(passiveStarted)

        if authorizationFirst {
            credentials.continueAuthorization.signal()
            try await authorization.value
            #expect(runtime.hasActiveInstallation)
            credentials.continuePassive.signal()
            #expect(try await passive.value == credentials.installation)
        } else {
            credentials.continuePassive.signal()
            await #expect(throws: failure) { try await passive.value }
            #expect(preferences.string(forKey: errorKey) == failure.localizedDescription)
            credentials.continueAuthorization.signal()
            try await authorization.value
        }

        #expect(preferences.string(forKey: errorKey) ?? "" == "")
        #expect(preferences.string(forKey: otherProfileKey) == "Unrelated LAN connection failure")
        #expect(try await runtime.savedInstallation(for: configuration.appPageURL) == credentials.installation)
        #expect(runtime.paused && runtime.readiness == "paused")
        #expect(!runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        #expect(!preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(configuration)))
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func launchKeychainReadCannotPublishAfterNativeRecovery(paused: Bool, denied: Bool) async throws {
        let suite = "keychain-launch-recovery-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = DeferredLaunchCredentialStore(installation: try boundKeychainRecoveryInstallation(), denyPassiveRead: denied)
        defer { credentials.continueRead.signal() }
        let installer = DesktopControlInstallerFixture(errors: [])
        let configuration = DesktopEnvironmentConfiguration.production
        let errorKey = DesktopControlPreferenceKeys.relayError(configuration)
        let otherProfileKey = DesktopControlPreferenceKeys.relayError(.lan)
        preferences.set("Other profile error", forKey: otherProfileKey)
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: installer, credentials: credentials, readiness: paused ? "paused" : "unknown",
            paused: paused, preferences: preferences)
        let startup = Task { @MainActor in await runtime.startAtLaunch(configuration: configuration, paused: paused) }
        let started = await awaitKeychainRaceSignal(credentials.readStarted)
        #expect(started)
        let recoveryGeneration = try runtime.beginResume()
        try await runtime.authorizeSavedInstallation(generation: recoveryGeneration)
        #expect(runtime.hasActiveInstallation)
        credentials.continueRead.signal()
        await startup.value

        #expect(preferences.string(forKey: errorKey) == "")
        #expect(preferences.string(forKey: otherProfileKey) == "Other profile error")
        #expect(try await runtime.savedInstallation(for: configuration.appPageURL) == credentials.installation)
        #expect(runtime.isCurrentLifecycle(recoveryGeneration))
        #expect(runtime.paused == paused && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        #expect(await installer.repairArguments.isEmpty)
    }

    @Test(arguments: [false, true], ["profile-denied", "profile-success", "cancel-denied", "cancel-success"]) @MainActor
    func launchKeychainReadCannotOverwriteChangedProfileOrCancelledTask(paused: Bool, completion: String) async throws {
        let changeProfile = completion.hasPrefix("profile")
        let suite = "keychain-launch-fenced-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = DeferredLaunchCredentialStore(installation: try boundKeychainRecoveryInstallation(),
                                                        denyPassiveRead: completion.hasSuffix("denied"))
        defer { credentials.continueRead.signal() }
        var configuration = DesktopEnvironmentConfiguration.production
        let changedProfile = try DesktopEnvironmentConfiguration(appURL: "https://my.personastack.ai",
                                                                 gatewayURL: "https://gateway-alt.example",
                                                                 mcpURL: "https://mcp-alt.example")
        let oldErrorKey = DesktopControlPreferenceKeys.relayError(configuration)
        let changedErrorKey = DesktopControlPreferenceKeys.relayError(changedProfile)
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []), credentials: credentials,
            preferences: preferences, configurationProvider: { configuration })
        let startup = Task { @MainActor in await runtime.startAtLaunch(configuration: .production, paused: paused) }
        let started = await awaitKeychainRaceSignal(credentials.readStarted)
        #expect(started)
        if changeProfile { configuration = changedProfile }
        else { startup.cancel() }
        preferences.set("Current old-profile state", forKey: oldErrorKey)
        preferences.set("Current changed-profile state", forKey: changedErrorKey)
        credentials.continueRead.signal()
        await startup.value
        #expect(preferences.string(forKey: oldErrorKey) == "Current old-profile state")
        #expect(preferences.string(forKey: changedErrorKey) == "Current changed-profile state")
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected)
    }
}



private actor StandaloneRuntimeInstallerFixture: DesktopControlDriverInstalling {
    private(set) var discoveries = 0
    private(set) var installations = 0
    let installation = CuaDriverInstallation(applicationURL: URL(fileURLWithPath: "/Applications/CuaDriver.app"),
        executableURL: URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"),
        version: CuaDriverCompatibility.version, toolNames: CuaDriverCompatibility.requiredTools)
    func discoverExisting() async throws -> CuaDriverInstallation? { discoveries += 1; return installation }
    func install() async throws -> CuaDriverInstallation { installations += 1; return installation }
}

private actor StandaloneRuntimeServiceFixture: DesktopControlCuaServicing {
    nonisolated let socketURL = URL(fileURLWithPath: "/unused/cua.sock")
    private(set) var setups = 0
    private(set) var permissionRequests = 0
    private(set) var inspections = 0
    func setup(installation: CuaDriverInstallation) async throws { setups += 1 }
    func requestPermissions(installation: CuaDriverInstallation) async throws { permissionRequests += 1 }
    func inspectPeer(installation: CuaDriverInstallation) async throws -> Int32 {
        inspections += 1
        throw CuaMCPProxyError.notStarted
    }
}

private actor CuaObservationRaceService: DesktopControlCuaServicing {
    nonisolated let socketURL = URL(fileURLWithPath: "/unused/race.sock")
    private var pending: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private let stopped: Bool
    init(stopped: Bool) { self.stopped = stopped }
    func setup(installation: CuaDriverInstallation) async throws { Issue.record("Unexpected service startup") }
    func requestPermissions(installation: CuaDriverInstallation) async throws { Issue.record("Unexpected permission request") }
    func inspectPeer(installation: CuaDriverInstallation) async throws -> Int32 {
        await withCheckedContinuation { pending = $0; entered?.resume(); entered = nil }
        if stopped { throw CuaMCPProxyError.notStarted }
        return 123
    }
    func waitForInspection() async {
        if pending != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func finishInspection() { let current = pending; pending = nil; current?.resume() }
}

@Test(arguments: [false, true]) @MainActor
func cuaObservationRacePreservesNewerVerificationOwner(stopped: Bool) async throws {
    let installer = StandaloneRuntimeInstallerFixture()
    let service = CuaObservationRaceService(stopped: stopped)
    let executor = DesktopControlCommandExecutor()
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
        credentials: EmptyDesktopControlCredentialStore(), executor: executor, readiness: "ready")
    let observation = Task { try await runtime.observeCuaForSetup() }
    await service.waitForInspection()
    let owner = try await executor.beginNativeVerification()
    defer { executor.endNativeVerification(owner) }
    await service.finishInspection()
    let result = try await observation.value
    if case .unavailable(_, let reason) = result {
        #expect(reason.contains("Another CUA check or setup"))
    } else { Issue.record("The newer setup owner must block this observation") }
    try executor.requireNativeVerification(owner)
    let report = await runtime.diagnosticReport()
    #expect(report.desktopReadiness == "ready")
    #expect(report.lastCuaCheck == nil && report.cuaCheckFailure == nil)
    #expect(await installer.installations == 0)
}

@Test @MainActor func standaloneReadinessAndConnectionChecksNeverInstallStartOrPrompt() async throws {
    let installer = StandaloneRuntimeInstallerFixture()
    let service = StandaloneRuntimeServiceFixture()
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
        credentials: EmptyDesktopControlCredentialStore(), paused: true)
    #expect(try await runtime.cuaInstalledForSetup())
    #expect(try await runtime.observeCuaForSetup() == .stopped)
    #expect(!(await runtime.refreshCuaReadiness()))
    await #expect(throws: CuaMCPProxyError.notStarted) { try await runtime.checkCuaConnectionForSetup() }
    #expect(await installer.installations == 0)
    #expect(await service.setups == 0)
    #expect(await service.permissionRequests == 0)
    #expect(await service.inspections == 2)
    #expect(runtime.paused)
    #expect(!runtime.gatewayConnected)
}

@Test @MainActor func standaloneSetupIsExplicitAndRelayShutdownLeavesServiceUntouched() async throws {
    let installer = StandaloneRuntimeInstallerFixture()
    let service = StandaloneRuntimeServiceFixture()
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
        credentials: EmptyDesktopControlCredentialStore(), paused: true)
    try await runtime.installCuaForSetup()
    #expect(await installer.installations == 1)
    #expect(await service.setups == 1)
    #expect(await service.permissionRequests == 0)
    try await runtime.requestCuaPermissionsForSetup()
    #expect(await service.permissionRequests == 1)
    await runtime.shutdownForQuit()
    #expect(await service.setups == 1)
    #expect(await service.permissionRequests == 1)
    #expect(await service.inspections == 0)
    #expect(await installer.installations == 1)
    #expect(runtime.paused && !runtime.gatewayConnected)
}

@Test @MainActor func failedRelayCleanupStaysFencedAndRetriesWithoutChangingStandaloneService() async throws {
    let installer = StandaloneRuntimeInstallerFixture()
    let service = StandaloneRuntimeServiceFixture()
    let executor = DesktopControlCommandExecutor()
    executor.failNextCleanupForTesting()
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
        credentials: EmptyDesktopControlCredentialStore(), executor: executor)
    await runtime.pause()
    #expect(runtime.paused)
    #expect(runtime.executorCleanupFailedForTesting)
    #expect(!runtime.permissionSetupAvailable)
    #expect(runtime.cuaSetupBlockReason?.contains("Retry Stop PersonaStack Control") == true)
    let observed = try? await runtime.observeCuaForSetup()
    if case .unavailable(_, let message) = observed {
        #expect(message.contains("Retry Stop PersonaStack Control"))
    } else { Issue.record("Cleanup failure must retain its specific recovery guidance") }
    #expect(!runtime.isReady())
    await runtime.pause()
    #expect(!runtime.executorCleanupFailedForTesting)
    #expect(await installer.installations == 0)
    #expect(await service.setups == 0)
    #expect(await service.permissionRequests == 0)
    #expect(await service.inspections == 0)
}

private actor RestartedStandaloneServiceFixture: DesktopControlCuaServicing {
    nonisolated let socketURL = URL(fileURLWithPath: "/fixture/standalone.sock")
    private var pid: Int32 = 111
    private(set) var mutations = 0
    func setPID(_ pid: Int32) { self.pid = pid }
    func inspectPeer(installation: CuaDriverInstallation) async throws -> Int32 { pid }
    func setup(installation: CuaDriverInstallation) async throws { mutations += 1 }
    func requestPermissions(installation: CuaDriverInstallation) async throws { mutations += 1 }
}

@Test(arguments: ["running", "stopped", "startup", "heartbeat"]) @MainActor
func desktopFirstEnrollmentCheckReconnectsOnlyItsIdleClientAfterStandaloneRestart(mode: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-setup-reconnect-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = CuaDriverCompatibility.requiredTools.sorted().map { name in
        DesktopControlJSONValue.object(["name": .string(name), "inputSchema": CuaToolCatalog.reviewedSchema(name)!])
    }
    let encodedCatalog = try JSONEncoder().encode(catalog).base64EncodedString()
    for pid in [111, 222] {
        let script = #"""
        #!/usr/bin/python3
        import base64, json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "notifications/initialized": continue
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
            elif method == "tools/list":
                result = {"tools":json.loads(base64.b64decode("\#(encodedCatalog)"))}
            elif method == "tools/call" and request["params"]["name"] == "check_permissions":
                assert request["params"]["arguments"] == {"prompt":False,"probe_direct_capture":False}
                result = {"structuredContent":{"accessibility":True,"screen_recording":True,
                    "source":{"attribution":"driver-daemon","bundle_id":"com.trycua.driver","pid":\#(pid)},
                    "direct_capture_verification":{"source":"permissions_grant","bundle_id":"com.trycua.driver","verified_at":"2026-10-06T12:00:00Z"}}}
            else:
                sys.exit(2)
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let executable = directory.appendingPathComponent("proxy-\(pid)")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    let installer = StandaloneRuntimeInstallerFixture()
    let service = RestartedStandaloneServiceFixture()
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    var proxies: [CuaMCPProxy] = []
    var connectedPIDs: [Int32] = []
    var publicationWaiting = false
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, cuaService: service,
        credentials: credentials, proxyFactory: { installation, socket, pid in
            #expect(installation.applicationURL.path == "/Applications/CuaDriver.app")
            #expect(socket == service.socketURL)
            connectedPIDs.append(pid)
            let proxy = CuaMCPProxy(executableURL: directory.appendingPathComponent("proxy-\(pid)"))
            proxies.append(proxy)
            return proxy
        }, beforeCuaPublication: mode == "startup" ? {
            publicationWaiting = true
            while !Task.isCancelled { await Task.yield() }
        } : nil, sessionLockState: .unlocked)
    if mode == "startup" {
        let prior = Task { await runtime.heartbeatReadinessForTesting() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !publicationWaiting, ContinuousClock.now < deadline { await Task.yield() }
        #expect(publicationWaiting)
        await service.setPID(222)
        try await runtime.checkCuaConnectionForSetup()
        _ = await prior.value
    } else {
        try await runtime.checkCuaConnectionForSetup()
        #expect(runtime.isCuaReady())
        #expect(connectedPIDs == [111])
        if mode == "stopped" { await proxies[0].stop() }
        await service.setPID(222)
        if mode == "heartbeat" {
            #expect(await runtime.heartbeatReadinessForTesting() == "cua_unavailable")
            #expect(!runtime.isCuaReady())
            let failed = await runtime.diagnosticReport()
            #expect(failed.lastCuaCheck != nil)
            #expect(failed.cuaCheckFailure?.contains("compatible standalone CUA") == true)
            #expect(failed.accessibilityGranted == nil)
            #expect(await runtime.heartbeatReadinessForTesting() == "ready")
            #expect(await runtime.diagnosticReport().cuaCheckFailure == nil)
        } else {
            try await runtime.checkCuaConnectionForSetup()
        }
    }
    #expect(runtime.isCuaReady())
    #expect(connectedPIDs == [111, 222])
    #expect(await !proxies[0].isProcessRunning())
    #expect(await proxies[1].isProcessRunning())
    #expect(await installer.installations == 0)
    #expect(await service.mutations == 0)
    #expect(credentials.readCount == (mode == "heartbeat" ? 1 : 0))
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasPendingRelayReconnectForTesting)
    await runtime.shutdownForQuit()
}
