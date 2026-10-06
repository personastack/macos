import Foundation
import Testing
import PersonaStackCore

@testable import PersonaStack

private actor ReadinessStateEnrollment: DesktopControlSetupEnrollment {
    private(set) var stateReads = 0
    let installation: DesktopControlInstallation
    init(installation: DesktopControlInstallation) { self.installation = installation }

    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        #expect(installation.installationID == self.installation.installationID)
        #expect(appURL == DesktopEnvironmentConfiguration.production.appURL)
        stateReads += 1
        return .init(hasActiveConfig: false, hasConfig: false)
    }

    private func unplanned() throws -> Never {
        Issue.record("A status read must not enroll, attach, reconnect, or report readiness")
        throw DesktopControlEnrollmentError.invalidRequest
    }
    func enroll(ticket: String, appURL: URL, commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?) async throws -> DesktopControlInstallation { try unplanned() }
    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws { try unplanned() }
    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws { try unplanned() }
    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool { try unplanned() }
}

@MainActor
@Test func cuaFailuresMapToFiniteDesktopReadiness() {
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.permissionsRequired) == "permission_required")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.functionalProbeFailed) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: CuaMCPProxyError.processExited) == "cua_unavailable")
    #expect(DesktopControlRuntime.readiness(for: DesktopControlGatewayConnectionError.upgradeRequired) == "upgrade_required")

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
                                                         paused: false, locked: false,
                                                         sessionUnlocked: true)
    guard case .object(let result)? = degradedGui.result else {
        Issue.record("status result is missing")
        return
    }
    #expect(result["connected"] == .bool(true))
    #expect(result["gui_readiness"] == .string("permission_required"))
    #expect(result["gui_ready"] == .bool(false))
    #expect(result["native_executor_ready"] == nil)
    #expect(result["control_available"] == .bool(false))

    let paused = DesktopControlRuntime.enrichStatus(response, connected: true, guiReadiness: "ready",
                                                    paused: true, locked: true,
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
    try installation.bindEnvironment(appURL, configuration: .production)
    let credentials = CountingDesktopCredentials(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(installer: ReadinessInstaller(), credentials: credentials)
    let enrollment = ReadinessStateEnrollment(installation: installation)
    let manager = DesktopControlSetupManager(runtime: runtime, enrollment: enrollment, configurationProvider: { .production })
    let page = DesktopControlSetupManager.Page(appURL: appURL)

    for _ in 0..<2 {
        let state = try await manager.apply(.state(scope: ""), page: page)
        #expect(state["installation_id"] as? String == installation.installationID)
        #expect(state["configuration_in_use"] as? Bool == false)
    }
    #expect(credentials.readCount == 1)
    #expect(await enrollment.stateReads == 2)

    page.setupScope.synchronize("workspace-setup")
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        _ = try await manager.apply(.state(scope: ""), page: page)
    }
    #expect(await enrollment.stateReads == 2)
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
                                    operation: "desktop_control_status", arguments: .object([:]),
                                    deadlineAt: Date().addingTimeInterval(45))
    let pausedResponse = await pausedRuntime.handleForTesting(frame, connectionID: connectionID)
    #expect(pausedResponse.type == "result")
    guard case .object(let pausedValues)? = pausedResponse.result else {
        Issue.record("paused status result is missing")
        await pausedExecutor.close()
        return
    }
    #expect(pausedValues["connected"] == .bool(true))
    #expect(pausedValues["gui_readiness"] == .string("cua_unavailable"))
    #expect(!pausedRuntime.isCuaReady())
    #expect(await pausedRuntime.diagnosticReport().cuaCheckFailure?.contains("not connected") == true)
    #expect(pausedValues["native_executor_ready"] == nil)
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
                                           operation: "desktop_control_status", arguments: .object([:]),
                                           deadlineAt: Date().addingTimeInterval(45))
    let cleanupResponse = await cleanupRuntime.handleForTesting(cleanupFrame, connectionID: connectionID)
    #expect(cleanupResponse.type == "result")
    guard case .object(let cleanupValues)? = cleanupResponse.result else {
        Issue.record("cleanup status result is missing")
        return
    }
    #expect(cleanupValues["native_executor_ready"] == nil)
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
                                    operation: "desktop_control_status", arguments: .object([:]),
                                    deadlineAt: Date().addingTimeInterval(45))

    let response = await runtime.handleForTesting(frame, connectionID: connectionID)
    #expect(response.type == "result")
    guard case .object(let values)? = response.result else {
        Issue.record("unavailable executor status result is missing")
        return
    }
    #expect(values["available"] == .bool(false))
    #expect(values["native_executor_ready"] == nil)
    #expect(values["control_available"] == .bool(false))
}

private actor ReadinessInstaller: DesktopControlDriverInstalling {
    func discoverExisting() async throws -> CuaDriverInstallation? { nil }
    func install() async throws -> CuaDriverInstallation { throw CuaDriverInstallError.invalidLayout }

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

@MainActor @Test func desktopBusyStatusDoesNotQueueBehindCUAOrLoseItsLease() async throws {
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"install-status","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://gateway.test/v1/desktop-control/ws"}"#.utf8))
    let target = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
        configID: "config-a", personaID: "persona-a", runID: "run-a", generation: 1)
    let executor = DesktopControlCommandExecutor()
    let acquire = DesktopControlFrame(type: "command", requestID: "acquire", target: target,
        operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: Date().addingTimeInterval(45))
    #expect(await executor.handle(acquire, proxy: nil).type == "result")
    let connectionID = UUID()
    let runtime = DesktopControlRuntime.makeForTesting(installer: ReadinessInstaller(), credentials: ReadinessCredentials(),
        executor: executor, connectionID: connectionID, installation: installation, connected: true, readiness: "ready")
    let status = DesktopControlFrame(type: "command", requestID: "status", target: target,
        operation: "desktop_control_status", arguments: .object([:]), deadlineAt: Date().addingTimeInterval(45))
    let response = await runtime.handleForTesting(status, connectionID: connectionID)
    guard case .object(let values)? = response.result else { Issue.record("Missing busy status"); return }
    #expect(values["busy"] == .bool(true))
    #expect(values["gui_readiness"] == .string("ready"))
    #expect(executor.currentLease != nil)
    #expect(await runtime.diagnosticReport().lastCuaCheck == nil)
    #expect(await executor.close())
}
