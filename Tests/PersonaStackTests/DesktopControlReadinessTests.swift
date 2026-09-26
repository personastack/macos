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
    #expect(CuaMCPProxyError.serviceRunning.localizedDescription.contains("will not terminate CuaDriver.app"))
    #expect(DesktopControlRuntime.readiness(for: DesktopControlEnrollmentError.rejected) == "cua_unavailable")
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.permissionsRequired))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.serviceRunning))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.serviceMismatch))
    #expect(!DesktopControlRuntime.shouldForceRepair(after: CancellationError()))
    #expect(DesktopControlRuntime.shouldForceRepair(after: CuaMCPProxyError.functionalProbeFailed))
}

@MainActor
@Test func cuaLaunchAndProxySelectOneSocketAndAppBundle() {
    let home = URL(fileURLWithPath: "/tmp/cua-test-home")
    let socket = DesktopControlRuntime.cuaSocketURL(homeDirectory: home)
    #expect(socket.path == "/tmp/cua-test-home/Library/Caches/cua-driver/cua-driver.sock")
    let configuration = DesktopControlRuntime.cuaServiceLaunchConfiguration(socketURL: socket)
    #expect(configuration.arguments == ["serve", "--socket", socket.path])

    let selected = URL(fileURLWithPath: "/Applications/CuaDriver.app", isDirectory: true)
    #expect(DesktopControlRuntime.matchesSelectedApplication(selected, selected))
    #expect(!DesktopControlRuntime.matchesSelectedApplication(
        URL(fileURLWithPath: "/Users/other/Applications/CuaDriver.app", isDirectory: true), selected
    ))
    #expect(!DesktopControlRuntime.matchesSelectedApplication(nil, selected))
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
@Test func desktopControlStatusSurvivesPausedLockedAndCleanupRuntimeGates() async throws {
    let payload = Data(#"{"installation_id":"install-status","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let connectionID = UUID()
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
                                     configID: "config-a", personaID: "persona-a", runID: "run-a", generation: 1)
    let pausedExecutor = DesktopControlCommandExecutor()
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

    let failedExecutor = DesktopControlCommandExecutor()
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
    let executor = DesktopControlCommandExecutor()
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
