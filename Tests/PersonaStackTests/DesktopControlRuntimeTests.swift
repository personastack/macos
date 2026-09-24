import Foundation
import PersonaStackCore
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

private struct SavedDesktopControlCredentialStore: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation

    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { installation }
    func delete() throws {}
}

@MainActor
private final class DesktopControlSetupRuntimeFixture: DesktopControlSetupRuntime {
    private(set) var attempts = 0
    private(set) var repairAttempts = 0
    private(set) var gatewayConnected = false
    private(set) var paused = false
    private(set) var ready = false
    private(set) var connectedInstallationID = ""
    var permissionGranted = false
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

    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID {
        repairAttempts += 1
        throw CuaMCPProxyError.functionalProbeFailed
    }

    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async {
        connectedInstallationID = installation.installationID
        gatewayConnected = true
    }
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

@Test @MainActor func setupReplyBoundaryRetriesAfterPermissionGrantAndConnectsInstallation() async throws {
    let installationPayload = Data(#"{"installation_id":"installation-setup","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: installationPayload)
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
        registerLoginItem: { loginItemRegistrations += 1 }
    )
    let page = DesktopControlSetupManager.Page(appURL: URL(string: "https://personastack.ai")!)
    let scope = "workspace-setup-session"
    page.setupScope.synchronize(scope)
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

    runtime.permissionGranted = true
    let retried = await sendSetupMessage()
    #expect(retried.error == nil)
    #expect(retried.ok)
    #expect(retried.installationID == installation.installationID)
    #expect(retried.cuaReady)
    #expect(retried.gatewayConnected)
    #expect(!retried.relayPaused)
    #expect(runtime.attempts == 2)
    #expect(runtime.repairAttempts == 0)
    #expect(runtime.connectedInstallationID == installation.installationID)
    #expect(loginItemRegistrations == 1)
    #expect(preferences.bool(forKey: "desktopControlRelayEnabled"))
    #expect(!(preferences.bool(forKey: "desktopControlRelayPaused")))
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID])
}
