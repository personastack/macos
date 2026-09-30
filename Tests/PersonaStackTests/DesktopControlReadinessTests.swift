import Foundation
import Testing
import PersonaStackCore

@testable import PersonaStack

@MainActor
@Test func cuaFailuresMapToFiniteDesktopReadiness() {
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.permissionsRequired) == "permission_required")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.functionalProbeFailed) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.processExited) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: DesktopControlGatewayConnectionError.upgradeRequired) == "upgrade_required")
    #expect(CuaMCPProxyError.serviceRunning.localizedDescription.contains("Repair will not terminate"))
    #expect(DesktopControlRuntime.readiness(for: DesktopControlEnrollmentError.rejected) == "cua_unavailable")
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.permissionsRequired))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.serviceRunning))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.serviceMismatch))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CancellationError()))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.functionalProbeFailed))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.responseTooLarge))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.processExited))
    #expect(DesktopControlRuntime.shouldForceRepair(after: CuaDriverInstallError.invalidSignature))
}

@MainActor
@Test func cuaPermissionProbeSeparatesToolFailureFromDeniedGrants() {
    #expect(DesktopControlRuntime.permissionProbeFailure(rpcError: false, toolError: true,
        hasStructured: false, accessibility: false, screenRecording: false) == .functionalProbeFailed)
    #expect(DesktopControlRuntime.permissionProbeFailure(rpcError: true, toolError: false,
        hasStructured: false, accessibility: false, screenRecording: false) == .functionalProbeFailed)
    #expect(DesktopControlRuntime.permissionProbeFailure(rpcError: false, toolError: false,
        hasStructured: true, accessibility: true, screenRecording: false) == .permissionsRequired)
    #expect(DesktopControlRuntime.permissionProbeFailure(rpcError: false, toolError: false,
        hasStructured: true, accessibility: true, screenRecording: true) == nil)
}

@MainActor
@Test func cuaHostCreatesPrivateEndpointsInsteadOfTheSharedStandaloneSocket() {
    let first = CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua"))
    let second = CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua"))
    #expect(first.socketURL != second.socketURL)
    #expect(first.directoryURL.path.hasPrefix("/tmp/ps-cua-"))
    #expect(first.socketURL.path.utf8.count < 104)
    #expect(first.socketURL.lastPathComponent == "control.sock")
    #expect(first.generation != second.generation)
}

@MainActor
@Test func cuaHostIdentityRequiresObservedParentAndReviewedExecutableRatherThanAnAdvisoryLabel() throws {
    let executable = URL(fileURLWithPath: "/reviewed/CuaDriver.app/Contents/MacOS/cua-driver")
    let validIdentity: [String: Any] = [
        "bundle_identifier": "ai.personastack.desktop", "configured_bundle_identifier": "ai.personastack.desktop",
        "identity_source": "parent_application", "parent_process_id": Int32(1000), "executable_path": executable.path,
    ]
    func report(_ identity: [String: Any], status: String = "pass") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": ["structuredContent": [
            "schema_version": "1", "driver_version": "0.29.1", "platform": "macos",
            "checks": [["name": "bundle_identity", "status": status, "data": identity]],
        ]]])
    }
    #expect(DesktopControlRuntime.validCuaHostIdentity(try report(validIdentity), executableURL: executable, hostPID: 1000))
    for field in validIdentity.keys {
        var invalid = validIdentity
        invalid.removeValue(forKey: field)
        #expect(!DesktopControlRuntime.validCuaHostIdentity(try report(invalid), executableURL: executable, hostPID: 1000))
    }
    var wrongParent = validIdentity
    wrongParent["parent_process_id"] = 2000
    #expect(!DesktopControlRuntime.validCuaHostIdentity(try report(wrongParent), executableURL: executable, hostPID: 1000))
    var wrongApp = validIdentity
    wrongApp["bundle_identifier"] = "com.trycua.driver"
    #expect(!DesktopControlRuntime.validCuaHostIdentity(try report(wrongApp), executableURL: executable, hostPID: 1000))
    #expect(!DesktopControlRuntime.validCuaHostIdentity(try report(validIdentity, status: "fail"), executableURL: executable, hostPID: 1000))
}

@MainActor
@Test func desktopCommandsRequireTheCurrentConnectionAndAnActiveLifecycle() {
    let currentConnection = UUID()
    #expect(DesktopControlRuntime.acceptsCommand(
        connectionID: currentConnection,
        currentConnectionID: currentConnection,
        disconnecting: false
    ))
    #expect(!DesktopControlRuntime.acceptsCommand(
        connectionID: UUID(),
        currentConnectionID: currentConnection,
        disconnecting: false
    ))
    #expect(!DesktopControlRuntime.acceptsCommand(
        connectionID: currentConnection,
        currentConnectionID: currentConnection,
        disconnecting: true
    ))
}

@MainActor
@Test func cuaReadinessIsScopedToGuiOperations() {
    for operation in ["desktop_control_observe", "desktop_control_input", "desktop_control_application",
                     "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser"] {
        #expect(DesktopControlRuntime.requiresCua(operation))
    }
    for operation in ["desktop_control_acquire", "desktop_control_release", "desktop_control_status",
                     "desktop_control_file", "desktop_control_execute", "desktop_control_exec_read",
                     "desktop_control_exec_write", "desktop_control_exec_status", "desktop_control_exec_cancel"] {
        #expect(!DesktopControlRuntime.requiresCua(operation))
    }
}

@MainActor
@Test func desktopControlStatusSeparatesConnectionAndGuiAndNativeReadiness() {
    let response = DesktopControlFrame(type: "result", requestID: "status",
                                       result: .object(["available": .bool(true), "busy": .bool(false),
                                                        "native_executor_ready": .bool(true)]))
    let degradedGui = DesktopControlRuntime.enrichStatus(response, connected: true, guiReadiness: "permission_required",
                                                         nativeExecutorReady: true, paused: false, locked: false,
                                                         sessionUnlocked: true)
    guard case .object(let result)? = degradedGui.result else {
        Issue.record("status result is missing")
        return
    }
    #expect(result["connected"] == .bool(true))
    #expect(result["gui_readiness"] == .string("permission_required"))
    #expect(result["gui_ready"] == .bool(false))
    #expect(result["native_executor_ready"] == .bool(true))
    #expect(result["control_available"] == .bool(false))

    let paused = DesktopControlRuntime.enrichStatus(response, connected: true, guiReadiness: "ready",
                                                    nativeExecutorReady: true, paused: true, locked: true,
                                                    sessionUnlocked: false)
    guard case .object(let pausedResult)? = paused.result else {
        Issue.record("paused status result is missing")
        return
    }
    #expect(pausedResult["paused"] == .bool(true))
    #expect(pausedResult["locked"] == .bool(true))
    #expect(pausedResult["session_unlocked"] == .bool(false))
    #expect(pausedResult["control_available"] == .bool(false))
}

@MainActor
@Test func successfulGuiPermissionProbeRestoresReadyState() {
    #expect(DesktopControlRuntime.reconciledGuiReadiness(permissionProbeSucceeded: true,
                                                         failureReadiness: "cua_unavailable") == "ready")
    #expect(DesktopControlRuntime.reconciledGuiReadiness(permissionProbeSucceeded: false,
                                                         failureReadiness: "permission_required") == "permission_required")
}

@MainActor
@Test func onlyReadyObservationsCanRetryAfterCuaFailure() {
    #expect(DesktopControlRuntime.shouldRetryGuiObservation(operation: "desktop_control_observe", readiness: "ready"))
    for operation in ["desktop_control_input", "desktop_control_application", "desktop_control_window",
                      "desktop_control_clipboard", "desktop_control_browser"] {
        #expect(!DesktopControlRuntime.shouldRetryGuiObservation(operation: operation, readiness: "ready"))
    }
    for readiness in ["permission_required", "cua_unavailable", "locked", "paused"] {
        #expect(!DesktopControlRuntime.shouldRetryGuiObservation(operation: "desktop_control_observe", readiness: readiness))
    }
}

@MainActor
@Test func degradedGuiHeartbeatRechecksOnlyAnUnlockedUsableCuaService() {
    for readiness in ["permission_required", "cua_unavailable"] {
        #expect(DesktopControlRuntime.shouldProbeGuiRecovery(readiness: readiness, paused: false,
                                                              unlocked: true, cuaReady: true))
        #expect(!DesktopControlRuntime.shouldProbeGuiRecovery(readiness: readiness, paused: true,
                                                               unlocked: true, cuaReady: true))
        #expect(!DesktopControlRuntime.shouldProbeGuiRecovery(readiness: readiness, paused: false,
                                                               unlocked: false, cuaReady: true))
        #expect(!DesktopControlRuntime.shouldProbeGuiRecovery(readiness: readiness, paused: false,
                                                               unlocked: true, cuaReady: false))
    }
    for readiness in ["ready", "paused", "locked", "upgrade_required", "unknown"] {
        #expect(!DesktopControlRuntime.shouldProbeGuiRecovery(readiness: readiness, paused: false,
                                                               unlocked: true, cuaReady: true))
    }
}

@MainActor
@Test func recoveredCuaServiceClearsOnlyItsRepairErrors() throws {
    let suite = "DesktopControlRepairErrorTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("Cua service could not be repaired", forKey: "desktopControlRepairError")
    preferences.set("Cua service could not be repaired: previous attempt failed", forKey: "desktopControlLoginItemError")

    DesktopControlRuntime.clearRecoveredRepairError(preferences: preferences, readiness: "cua_unavailable", cuaReady: true)
    #expect(preferences.string(forKey: "desktopControlRepairError") != "")
    #expect(preferences.string(forKey: "desktopControlLoginItemError") != "")
    DesktopControlRuntime.clearRecoveredRepairError(preferences: preferences, readiness: "ready", cuaReady: false)
    #expect(preferences.string(forKey: "desktopControlRepairError") != "")
    #expect(preferences.string(forKey: "desktopControlLoginItemError") != "")
    DesktopControlRuntime.clearRecoveredRepairError(preferences: preferences, readiness: "ready", cuaReady: true)
    #expect(preferences.string(forKey: "desktopControlRepairError") == "")
    #expect(preferences.string(forKey: "desktopControlLoginItemError") == "")
    preferences.set("Login item failed", forKey: "desktopControlLoginItemError")
    DesktopControlRuntime.clearRecoveredRepairError(preferences: preferences, readiness: "ready", cuaReady: true)
    #expect(preferences.string(forKey: "desktopControlLoginItemError") == "Login item failed")
}

@MainActor
@Test func desktopRuntimeKeepsOneLoadedInstallationForItsLifecycle() async throws {
    let payload = Data(#"{"installation_id":"install-cache","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let credentials = CountingDesktopCredentials(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(installer: ReadinessInstaller(), credentials: credentials)

    #expect(try await runtime.savedInstallationForTesting()?.installationID == installation.installationID)
    #expect(try await runtime.savedInstallationForTesting()?.installationID == installation.installationID)
    #expect(credentials.readCount == 1)
}

@MainActor
@Test func desktopStatusUsesTheRuntimeCredentialCache() async throws {
    let appURL = URL(string: "https://my.personastack.ai")!
    let payload = Data(#"{"installation_id":"install-status-cache","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(appURL)
    let credentials = CountingDesktopCredentials(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(installer: ReadinessInstaller(), credentials: credentials)
    let manager = DesktopControlSetupManager(runtime: runtime)
    let page = DesktopControlSetupManager.Page(appURL: appURL)

    for _ in 0..<2 {
        let state = try await manager.apply(.state(scope: ""), page: page)
        #expect(state["installation_id"] as? String == installation.installationID)
    }
    #expect(credentials.readCount == 1)

    page.setupScope.synchronize("workspace-setup")
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        _ = try await manager.apply(.state(scope: ""), page: page)
    }
}

@MainActor
@Test func desktopControlStatusSurvivesPausedLockedAndCleanupRuntimeGates() async throws {
    let payload = Data(#"{"installation_id":"install-status","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let connectionID = UUID()
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
                                     configID: "config-a", personaID: "persona-a", runID: "run-a", generation: 1)
    let pausedExecutor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    let pausedRuntime = DesktopControlRuntime.makeForTesting(
        installer: ReadinessInstaller(), credentials: ReadinessCredentials(), executor: pausedExecutor,
        connectionID: connectionID, installation: installation, connected: true,
        readiness: "permission_required", paused: true, sessionLockState: .locked
    )
    await pausedRuntime.waitForLockCleanupForTesting()
    let frame = DesktopControlFrame(type: "command", requestID: "status-paused", target: owner,
                                    operation: "desktop_control_status", arguments: .object([:]))
    let pausedResponse = await pausedRuntime.handleForTesting(frame, connectionID: connectionID)
    #expect(pausedResponse.type == "result")
    guard case .object(let pausedValues)? = pausedResponse.result else {
        Issue.record("paused status result is missing")
        await pausedExecutor.close()
        return
    }
    #expect(pausedValues["connected"] == .bool(true))
    #expect(pausedValues["gui_readiness"] == .string("locked"))
    #expect(pausedValues["native_executor_ready"] == .bool(true))
    #expect(pausedValues["paused"] == .bool(true))
    #expect(pausedValues["locked"] == .bool(true))
    #expect(pausedValues["session_unlocked"] == .bool(false))
    #expect(pausedValues["control_available"] == .bool(false))
    await pausedExecutor.close()

    let failedExecutor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    #expect(await failedExecutor.close())
    let cleanupRuntime = DesktopControlRuntime.makeForTesting(
        installer: ReadinessInstaller(), credentials: ReadinessCredentials(), executor: failedExecutor,
        connectionID: connectionID, installation: installation, connected: true,
        readiness: "ready", cleanupInProgress: true
    )
    let cleanupFrame = DesktopControlFrame(type: "command", requestID: "status-cleanup", target: owner,
                                           operation: "desktop_control_status", arguments: .object([:]))
    let cleanupResponse = await cleanupRuntime.handleForTesting(cleanupFrame, connectionID: connectionID)
    #expect(cleanupResponse.type == "result")
    guard case .object(let cleanupValues)? = cleanupResponse.result else {
        Issue.record("cleanup status result is missing")
        return
    }
    #expect(cleanupValues["native_executor_ready"] == .bool(false))
    #expect(cleanupValues["control_available"] == .bool(false))
}

@MainActor
@Test func desktopControlStatusPreservesExecutorReportedFailureWithoutRuntimeCleanupFlag() async throws {
    let payload = Data(#"{"installation_id":"install-status","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let connectionID = UUID()
    let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    #expect(await executor.close())
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: ReadinessInstaller(), credentials: ReadinessCredentials(), executor: executor,
        connectionID: connectionID, installation: installation, connected: true, readiness: "ready"
    )
    let target = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
                                     configID: "config-a", personaID: "persona-a", runID: "run-a", generation: 1)
    let frame = DesktopControlFrame(type: "command", requestID: "status-unavailable", target: target,
                                    operation: "desktop_control_status", arguments: .object([:]))

    let response = await runtime.handleForTesting(frame, connectionID: connectionID)
    #expect(response.type == "result")
    guard case .object(let values)? = response.result else {
        Issue.record("unavailable executor status result is missing")
        return
    }
    #expect(values["available"] == .bool(false))
    #expect(values["native_executor_ready"] == .bool(false))
    #expect(values["control_available"] == .bool(false))
}

private actor ReadinessInstaller: DesktopControlDriverInstalling {
    func validateOrInstall(
        repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?
    ) async throws -> CuaDriverInstallation {
        throw CuaDriverInstallError.invalidLayout
    }
}

private struct ReadinessCredentials: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

private final class CountingDesktopCredentials: DesktopControlCredentialStoring, @unchecked Sendable {
    private let installation: DesktopControlInstallation
    private let lock = NSLock()
    private var reads = 0

    init(installation: DesktopControlInstallation) { self.installation = installation }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func save(_ installation: DesktopControlInstallation) throws {}

    func load() throws -> DesktopControlInstallation? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return installation
    }

    func delete() throws {}
}
