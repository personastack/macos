import AppKit
import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

private actor DesktopControlInstallerFixture: DesktopControlDriverInstalling {
    private let errors: [any Error]
    private(set) var repairArguments: [Bool] = []

    init(errors: [any Error]) { self.errors = errors }

    func validateOrInstall(
        repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?
    ) async throws -> CuaDriverInstallation {
        repairArguments.append(repair)
        guard let error = errors.indices.contains(repairArguments.count - 1) ? errors[repairArguments.count - 1] : nil else {
            throw CuaDriverInstallError.invalidLayout
        }
        throw error
    }
}

private struct EmptyDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

@Test @MainActor func macOSLockFencesCommandsBeforeAsynchronousHeartbeat() async {
    let executor = DesktopControlCommandExecutor()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(), executor: executor,
        sessionLockState: .locked
    )
    #expect(runtime.lockCleanupStartedForTesting)
    #expect(runtime.readiness == "locked")
    _ = await executor.close()
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
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        installation: installation, connected: true, readiness: "ready")
    let generation = try runtime.beginResume()

    await runtime.shutdownForQuit()

    #expect(!runtime.isCurrentLifecycle(generation))
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasActiveInstallation)
}

@Test @MainActor func quitWaitsForCleanupAndRepliesOnlyOnce() async {
    var cleanupCalls = 0
    var replies = 0
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { cleanupCalls += 1 },
        reply: { _ in replies += 1 },
        timeout: .seconds(1))
    let app = NSApplication.shared

    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cleanupCalls == 1)
    #expect(replies == 1)
}

@Test @MainActor func quitDeadlineRepliesWhenCleanupIsSlow() async {
    var replies = 0
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { try? await Task.sleep(for: .milliseconds(100)) },
        reply: { _ in replies += 1 },
        timeout: .milliseconds(10))

    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(replies == 1)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(replies == 1)
}

private actor DesktopControlRelayStateFixture: DesktopControlRelayStateReading {
    let active: Bool

    init(active: Bool) { self.active = active }

    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool {
        active
    }
}

@MainActor
private final class DesktopControlSetupRuntimeFixture: DesktopControlSetupRuntime {
    private(set) var attempts = 0
    private(set) var repairAttempts = 0
    private(set) var gatewayConnected = false
    private(set) var paused = false
    var nativeExecutorReady = true
    private(set) var ready = false
    private(set) var nativeProbeCount = 0
    private(set) var connectedInstallationID = ""
    var permissionGranted = false
    private var generation = UUID()
    var readiness: String { ready ? "ready" : "permission_required" }

    func isCuaReady() -> Bool { ready }

    func probeNativeCapabilities(generation: UUID) async throws {
        guard isCurrentLifecycle(generation) else { throw CancellationError() }
        nativeProbeCount += 1
    }

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

    func finishSetupIfIdle() async {}

    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID {
        repairAttempts += 1
        throw CuaMCPProxyError.functionalProbeFailed
    }

    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async {
        connectedInstallationID = installation.installationID
        gatewayConnected = true
    }

    func savedInstallation(for appURL: URL) throws -> DesktopControlInstallation? { nil }
}

private actor DesktopControlSetupEnrollmentFixture: DesktopControlSetupEnrollment {
    private(set) var readyInstallationIDs: [String] = []
    private(set) var attachedTicketInstallationIDs: [String] = []

    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?
    ) async throws -> DesktopControlInstallation {
        throw DesktopControlEnrollmentError.rejected
    }

    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws {
        readyInstallationIDs.append(installation.installationID)
    }

    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws {
        attachedTicketInstallationIDs.append(installation.installationID)
    }

    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool { true }
}

@Test @MainActor func repairDoesNotForceReinstallWhenCuaNeedsPermission() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaMCPProxyError.permissionsRequired])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaMCPProxyError.permissionsRequired) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false])
    #expect(runtime.readiness == "permission_required")
}

@Test @MainActor func foregroundSetupConfirmationAllowsOnlyUnknownSession() {
    let lock = DesktopControlSessionLock(observeSystem: false)
    #expect(!lock.allowsControl)
    lock.confirmForegroundSetup()
    #expect(lock.allowsControl)
    lock.receive(.locked)
    lock.confirmForegroundSetup()
    #expect(!lock.allowsControl)
    lock.receive(.unlocked)
    #expect(lock.allowsControl)
}

@Test @MainActor func restartConfirmationRequiresForegroundApprovalAndNeverOverridesLock() throws {
    let denied = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { false }
    )
    #expect(denied.requiresForegroundSessionConfirmation)
    #expect(throws: CancellationError.self) { try denied.confirmForegroundSession() }
    #expect(denied.requiresForegroundSessionConfirmation)

    let approved = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { true }
    )
    try approved.confirmForegroundSession()
    #expect(!approved.requiresForegroundSessionConfirmation)
    #expect(approved.sessionRecoveryMessage == nil)

    let locked = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        sessionLockState: .locked,
        confirmForegroundSetup: { true }
    )
    #expect(!locked.requiresForegroundSessionConfirmation)
    #expect(throws: DesktopControlEnrollmentError.self) { try locked.confirmForegroundSession() }
    #expect(locked.sessionRecoveryMessage == "Unlock this Mac to enable remote control.")
}

@Test @MainActor func repairAllowsOnlyOneForcedInstallAfterRetryableFailure() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaDriverInstallError.invalidLayout, CuaDriverInstallError.invalidLayout])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaDriverInstallError.invalidLayout) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false, true])
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func setupPrepareAcceptsRepeatedPermissionRetryAttemptsWithoutForcedInstall() async throws {
    let installer = DesktopControlInstallerFixture(errors: [
        CuaMCPProxyError.permissionsRequired,
        CuaMCPProxyError.permissionsRequired,
    ])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())
    let manager = DesktopControlSetupManager(runtime: runtime)
    let page = DesktopControlSetupManager.Page(appURL: URL(string: "https://personastack.ai")!)
    page.setupScope.synchronize("workspace-setup-session")
    let command = DesktopControlSetupCommand.prepare(
        scope: "workspace-setup-session",
        enrollmentTicket: String(repeating: "a", count: 43)
    )

    for _ in 0..<2 {
        do {
            _ = try await manager.apply(command, page: page)
            Issue.record("permission denial should leave setup available for another attempt")
        } catch let error as CuaMCPProxyError {
            #expect(error == .permissionsRequired)
        } catch {
            Issue.record("unexpected setup error: \(error)")
        }
    }

    #expect(await installer.repairArguments == [false, false])
    #expect(runtime.readiness == "permission_required")
}

@Test @MainActor func setupCancellationBeforeUnknownLockConfirmationDoesNotStartCua() async throws {
    let installer = DesktopControlInstallerFixture(errors: [])
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: installer,
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { false }
    )
    let generation = try runtime.beginResume()

    await #expect(throws: CancellationError.self) {
        try await runtime.resumeForSetup(generation: generation)
    }
    #expect(await installer.repairArguments.isEmpty)
}

@Test @MainActor func setupCancellationStopsOnlyAnUnconfiguredRelay() async throws {
    let payload = Data(#"{"installation_id":"install-cancel","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(appURL)

    for hasActiveConfig in [false, true] {
        let suite = "desktop-control-relay-idle-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "desktopControlRelayEnabled")
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []),
            credentials: SavedDesktopControlCredentialStore(installation: installation),
            connectionID: UUID(), installation: installation, connected: true,
            readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: hasActiveConfig),
            preferences: preferences
        )

        await runtime.finishSetupIfIdle()

        #expect(runtime.gatewayConnected == hasActiveConfig)
        #expect(runtime.hasActiveInstallation == hasActiveConfig)
        #expect(preferences.bool(forKey: "desktopControlRelayEnabled") == hasActiveConfig)
    }
}

@Test @MainActor func idleRelayKeepsInstallationWhenExecutorCleanupFails() async throws {
    let payload = Data(#"{"installation_id":"install-idle-failure","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    let suite = "desktop-control-idle-failure-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: "desktopControlRelayEnabled")
    let executor = DesktopControlCommandExecutor()
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
                                     configID: "config-a", personaID: "persona-a", runID: "run-a",
                                     generation: 1, configVersion: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "acquire-idle-failure", target: owner,
                                      operation: "desktop_control_acquire", arguments: .object([:]))
    #expect((await executor.handle(acquire, proxy: nil)).type == "result")
    executor.failNextCleanupForTesting()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        executor: executor, connectionID: UUID(), installation: installation, connected: true,
        readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: false),
        preferences: preferences
    )

    await runtime.finishSetupIfIdle()

    #expect(runtime.gatewayConnected)
    #expect(runtime.hasActiveInstallation)
    #expect(preferences.bool(forKey: "desktopControlRelayEnabled"))
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func setupReplyBoundaryRetriesAfterPermissionGrantAndConnectsInstallation() async throws {
    let installationPayload = Data(#"{"installation_id":"installation-setup","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: installationPayload)
    // Saved credentials carry the origin set by the enrollment commit path.
    try installation.bindEnvironment(appURL)
    let runtime = DesktopControlSetupRuntimeFixture()
    let enrollment = DesktopControlSetupEnrollmentFixture()
    let defaultsName = "desktop-control-setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: defaultsName))
    defer { preferences.removePersistentDomain(forName: defaultsName) }
    var loginItemRegistrations = 0
    let manager = DesktopControlSetupManager(
        runtime: runtime,
        enrollment: enrollment,
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        preferences: preferences,
        registerLoginItem: { loginItemRegistrations += 1 },
        loginItemStatus: { loginItemRegistrations > 0 ? .enabled : .notRegistered }
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    let scope = "workspace-setup-session"
    page.setupScope.synchronize(scope)
    let setupGeneration = page.setupScope.generation
    let body: [String: Any] = [
        "version": "1", "action": "prepare", "scope": scope,
        "enrollment_ticket": String(repeating: "a", count: 43),
    ]

    func sendSetupMessage() async -> (error: String?, ok: Bool, installationID: String?, cuaReady: Bool, gatewayConnected: Bool, relayPaused: Bool) {
        await withCheckedContinuation { continuation in
            manager.dispatch(body, page: page) { value, error in
                let response = value as? [String: Any]
                continuation.resume(returning: (
                    error: error,
                    ok: response?["ok"] as? Bool ?? false,
                    installationID: response?["installation_id"] as? String,
                    cuaReady: response?["cua_ready"] as? Bool ?? false,
                    gatewayConnected: response?["gateway_connected"] as? Bool ?? false,
                    relayPaused: response?["relay_paused"] as? Bool ?? true
                ))
            }
        }
    }

    let denied = await sendSetupMessage()
    #expect(denied.ok == false)
    #expect(denied.error == CuaMCPProxyError.permissionsRequired.localizedDescription)
    #expect(runtime.readiness == "permission_required")
    #expect(loginItemRegistrations == 0)

    #expect(page.setupScope.generation == setupGeneration)
    #expect(page.setupScope.value == scope)
    #expect(await enrollment.readyInstallationIDs.isEmpty)
    #expect(await enrollment.attachedTicketInstallationIDs.isEmpty)

    runtime.permissionGranted = true
    let retried = await sendSetupMessage()
    #expect(retried.error == nil)
    #expect(retried.ok)
    #expect(retried.installationID == installation.installationID)
    #expect(retried.cuaReady)
    #expect(retried.gatewayConnected)
    #expect(!retried.relayPaused)
    #expect(runtime.attempts == 2)
    #expect(runtime.nativeProbeCount == 1)
    #expect(runtime.repairAttempts == 0)
    #expect(runtime.connectedInstallationID == installation.installationID)
    #expect(loginItemRegistrations == 1)
    #expect(preferences.bool(forKey: "desktopControlRelayEnabled"))
    #expect(!(preferences.bool(forKey: "desktopControlRelayPaused")))
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID])
    #expect(page.setupScope.generation == setupGeneration)

    page.setupScope.synchronize("")
    let staleRetry = await sendSetupMessage()
    #expect(staleRetry.error == DesktopControlEnrollmentError.invalidRequest.localizedDescription)
    #expect(!staleRetry.ok)
    #expect(runtime.attempts == 2)
    #expect(loginItemRegistrations == 1)
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID])
}

@Test @MainActor func setupDoesNotEnrollUntilLoginItemIsEnabled() async throws {
    let payload = Data(#"{"installation_id":"installation-approval","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(appURL)
    let runtime = DesktopControlSetupRuntimeFixture()
    runtime.permissionGranted = true
    let enrollment = DesktopControlSetupEnrollmentFixture()
    let suite = "desktop-control-approval-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let manager = DesktopControlSetupManager(
        runtime: runtime,
        enrollment: enrollment,
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        preferences: preferences,
        registerLoginItem: {},
        loginItemStatus: { .requiresApproval }
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    page.setupScope.synchronize("workspace-setup-session")
    do {
        _ = try await manager.apply(.prepare(scope: "workspace-setup-session", enrollmentTicket: String(repeating: "a", count: 43)), page: page)
        Issue.record("setup should wait for login item approval")
    } catch {
        #expect(error.localizedDescription.contains("Login Items & Extensions"))
    }
    #expect(await enrollment.readyInstallationIDs.isEmpty)
    #expect(await enrollment.attachedTicketInstallationIDs.isEmpty)
    #expect(!runtime.gatewayConnected)
    #expect(!preferences.bool(forKey: "desktopControlRelayEnabled"))
}
