import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
@testable import PersonaStack

private func runtimeJSON(running: Bool = false, enabled: Bool = false, active: Bool = false, kubernetesAvailable: Bool = false) -> String {
    "{\"installed\":true,\"running\":\(running),\"kubernetes_available\":\(kubernetesAvailable),\"enabled\":\(enabled),\"installer_active\":\(active)}"
}

private func runtimeSnapshot(running: Bool = false, enabled: Bool = false, active: Bool = false) throws -> AgentBridgeLocalRuntimeSnapshot {
    try JSONDecoder().decode(AgentBridgeLocalRuntimeSnapshot.self,
                            from: Data(runtimeJSON(running: running, enabled: enabled, active: active).utf8))
}

private actor LocalRuntimeControlFixture: AgentBridgeControlTransport {
    private var steps: [(String, String)]
    private let externalCredentialsUnavailable: Bool
    private(set) var operations: [String] = []
    init(_ steps: [(String, String)], externalCredentialsUnavailable: Bool = false) {
        self.steps = steps; self.externalCredentialsUnavailable = externalCredentialsUnavailable
    }
    func exchange(_ request: Data) throws -> Data {
        let envelope = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(envelope["operation"] as? String)
        operations.append(operation)
        let payload = try #require(envelope["payload"] as? [String: Any])
        #expect(payload.isEmpty)
        if operation == "status" {
            var status: [String: Any] = ["local_cluster_control_version": 1]
            if externalCredentialsUnavailable {
                status["external_error"] = ["code": "credential_unavailable", "message": "External runtime credentials are unavailable. Restore credential access and try again."]
            } else { status["connections"] = [] }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": envelope["request_id"]!, "result": status])
        }
        guard !steps.isEmpty else { throw AgentBridgeFailure.serviceUnavailable }
        let next = steps.removeFirst()
        #expect(operation == next.0)
        guard operation == next.0 else { throw AgentBridgeFailure.invalidRequest }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": envelope["request_id"]!,
            "result": JSONSerialization.jsonObject(with: Data(next.1.utf8))])
    }
}

@MainActor private final class LocalRuntimeRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .enabled
    var calls: [String] = []
    var canRegister: @MainActor () -> Bool = { true }
    func register() throws {
        guard canRegister() else { throw AgentBridgeFailure.serviceUnavailable }
        calls.append("register"); status = .enabled
    }
    func unregister() async throws { calls.append("unregister"); status = .notRegistered }
}

@MainActor private final class LocalRuntimeUpdateFixture: AgentBridgeUpdateLifecycle {
    var hasRegisteredService = true
    var canQuiesce = true
    var running = true
    var enabled = true
    var installerActive = false
    var stopActuallySettles = true
    var waitForStop = false
    var stopContinuation: CheckedContinuation<Void, Never>?
    var calls: [String] = []
    func localRuntimeSnapshot() async throws -> AgentBridgeLocalRuntimeSnapshot {
        calls.append("snapshot")
        return try runtimeSnapshot(running: running, enabled: enabled, active: installerActive)
    }
    func stopLocalRuntime() async throws {
        calls.append("stop-begin")
        enabled = false
        if waitForStop { await withCheckedContinuation { stopContinuation = $0 } }
        if stopActuallySettles { running = false; installerActive = false }
        calls.append("stop-exited")
    }
    func resumeLocalRuntime() async throws { calls.append("resume-local"); enabled = true }
    func quiesce() async throws -> AgentBridgeAdmission {
        calls.append("quiesce")
        return try JSONDecoder().decode(AgentBridgeAdmission.self, from: Data(#"{"quiesced":true,"active_run_ids":[]}"#.utf8))
    }
    func resume() async throws { calls.append("resume-external") }
    func retireForReplacement() async throws { calls.append("retire"); hasRegisteredService = false }
    func restoreAfterReplacement() async throws { calls.append("restore"); hasRegisteredService = true }
}

@Suite struct AgentBridgeLocalRuntimeLifecycleTests {
    private func preferences() -> UserDefaults {
        UserDefaults(suiteName: "AgentBridgeLocalRuntimeLifecycleTests." + UUID().uuidString)!
    }


    @Test @MainActor func localRemovalRemainsAvailableWhenExternalKeychainStatusFails() async throws {
        let removed = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_removed"}"#
        let control = LocalRuntimeControlFixture([
            ("local_cluster_remove", #"{"active":true}"#),
            ("local_cluster_runtime_status", removed)
        ], externalCredentialsUnavailable: true)
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.removeLocalRuntimeData()
        await #expect(throws: AgentBridgeFailure.credentialUnavailable) { try await service.retireIfUnused() }
        #expect(registration.calls.isEmpty)
        let operations = await control.operations
        #expect(operations.filter { $0 != "status" } == ["local_cluster_remove", "local_cluster_runtime_status"])
    }


    @Test @MainActor func confirmedLocalStopReportsExternalCredentialCleanupFailureSeparately() async throws {
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_stop", #"{"active":true}"#),
            ("local_cluster_runtime_status", runtimeJSON())
        ], externalCredentialsUnavailable: true)
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.stopLocalRuntime()
        do {
            try await service.retireIfUnused()
            Issue.record("Unknown external inventory must retain the shared helper")
        } catch {
            #expect(error as? AgentBridgeFailure == .credentialUnavailable)
            #expect(AgentBridgeMenu.localStopCleanupFailure(error as? AgentBridgeFailure) == "Local runtime stop was confirmed. Restore access to your login Keychain. Sign out of macOS and sign back in to restart the background helper. Signing out of PersonaStack does not restart it.")
        }
        #expect(registration.calls.isEmpty)
    }

    @Test @MainActor func externalEnableCannotTreatUnavailableKeychainAsEmptyInventory() async throws {
        let control = LocalRuntimeControlFixture([], externalCredentialsUnavailable: true)
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        await #expect(throws: AgentBridgeFailure.credentialUnavailable) { try await service.ensureEnabled() }
        #expect(settings.bool(forKey: AgentBridgeService.disabledKey))
        #expect(registration.calls.isEmpty)
        #expect(await control.operations == ["status"])
    }

    @Test @MainActor func externalStopRetainsClusterHelperWithoutStoppingVM() async throws {
        let control = LocalRuntimeControlFixture([
            ("quiesce", #"{"quiesced":true,"active_run_ids":[]}"#),
            ("stop_background", #"{"disabled":true,"keep_service":true}"#)
        ])
        let registration = LocalRuntimeRegistration(), settings = preferences()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.stopBackground()
        #expect(registration.calls.isEmpty)
        #expect(registration.status == .enabled)
        #expect(settings.bool(forKey: AgentBridgeService.disabledKey))
        #expect(await control.operations == ["quiesce", "stop_background"])
    }

    @Test @MainActor func clusterSetupUnblocksSharedStartupWhileUpdateRestoreKeepsExternalAgentsDisabled() async throws {
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_status", runtimeJSON(enabled: true)),
            ("local_cluster_runtime_status", runtimeJSON(enabled: true))
        ])
        let registration = LocalRuntimeRegistration(), settings = preferences()
        registration.status = .notRegistered
        var startupDisabled = true
        var markerClears = 0
        registration.canRegister = { !startupDisabled }
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        settings.set(true, forKey: AgentBridgeUpdateHandoff.restoreKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {
                markerClears += 1
                startupDisabled = false
            })
        try await service.ensureLocalClusterEnabled()
        try await service.restoreAfterReplacement()
        try await service.resume()
        #expect(registration.calls == ["register"])
        #expect(markerClears == 2)
        #expect(!startupDisabled)
        #expect(settings.bool(forKey: AgentBridgeService.disabledKey))
        #expect(await control.operations == ["status", "local_cluster_runtime_status", "status", "local_cluster_runtime_status"])
    }

    @Test @MainActor func offlineStopJoinsProcessExitWithoutExternalCommandsOrUnregister() async throws {
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_stop", #"{"active":true}"#),
            ("local_cluster_runtime_status", runtimeJSON(active: true)),
            ("local_cluster_runtime_status", runtimeJSON())
        ])
        let registration = LocalRuntimeRegistration()
        var waits = 0
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {}, waitForRuntimePoll: { waits += 1 })
        try await service.stopLocalRuntime()
        #expect(waits == 1)
        #expect(registration.calls.isEmpty)
        #expect(await control.operations == ["status", "local_cluster_runtime_stop", "status", "local_cluster_runtime_status", "status", "local_cluster_runtime_status"])
    }



    @Test @MainActor func nativeRemovalUsesCanonicalTaskAndWaitsForExactRemovedEvidence() async throws {
        let removed = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_removed"}"#
        let control = LocalRuntimeControlFixture([
            ("local_cluster_remove", #"{"active":true}"#),
            ("local_cluster_runtime_status", runtimeJSON(active: true)),
            ("local_cluster_runtime_status", removed)
        ])
        let registration = LocalRuntimeRegistration()
        var waits = 0
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {}, waitForRuntimePoll: { waits += 1 })
        try await service.removeLocalRuntimeData()
        #expect(waits == 1)
        #expect(registration.calls.isEmpty)
        let operations = await control.operations
        #expect(operations.filter { $0 != "status" } == ["local_cluster_remove", "local_cluster_runtime_status", "local_cluster_runtime_status"])
    }

    @Test @MainActor func missingRemovedReceiptCannotBeReportedAsSuccessfulRemoval() async throws {
        let absent = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false}"#
        let control = LocalRuntimeControlFixture([
            ("local_cluster_remove", #"{"active":false}"#),
            ("local_cluster_runtime_status", absent)
        ])
        let registration = LocalRuntimeRegistration()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {}, runtimeOperationTimeout: .zero)
        await #expect(throws: AgentBridgeFailure.operationTimeout) { try await service.removeLocalRuntimeData() }
        #expect(registration.calls.isEmpty)
    }


    @Test @MainActor func partialRemovalRetryReachesTheCommonOwnerWithoutASeparateStop() async throws {
        let partial = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_unavailable"}"#
        let removed = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_removed"}"#
        let control = LocalRuntimeControlFixture([
            ("local_cluster_remove", #"{"active":true}"#),
            ("local_cluster_runtime_status", partial),
            ("local_cluster_remove", #"{"active":true}"#),
            ("local_cluster_runtime_status", removed)
        ])
        let registration = LocalRuntimeRegistration()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {}, runtimeOperationTimeout: .zero)
        await #expect(throws: AgentBridgeFailure.operationTimeout) { try await service.removeLocalRuntimeData() }
        try await service.removeLocalRuntimeData()
        #expect(registration.calls.isEmpty)
        let operations = await control.operations
        #expect(operations.filter { $0 != "status" } == ["local_cluster_remove", "local_cluster_runtime_status", "local_cluster_remove", "local_cluster_runtime_status"])
    }

    @Test @MainActor func removalCanRegisterWithPartialDataWithoutRequiringHealthyRuntimeState() async throws {
        let partial = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_unavailable"}"#
        let removed = #"{"installed":false,"running":false,"kubernetes_available":false,"enabled":false,"installer_active":false,"safe_reason":"local_data_removed"}"#
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_status", partial),
            ("local_cluster_remove", #"{"active":true}"#),
            ("local_cluster_runtime_status", removed)
        ])
        let registration = LocalRuntimeRegistration()
        registration.status = .notRegistered
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {})
        try await service.removeLocalRuntimeData()
        #expect(registration.calls == ["register"])
        let operations = await control.operations
        #expect(!operations.contains("local_cluster_runtime_stop"))
    }

    @Test @MainActor func nativeResumeWaitsForLocalKubernetesWithoutEnablingExternalAgents() async throws {
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_status", runtimeJSON()),
            ("local_cluster_runtime_resume", #"{"active":true}"#),
            ("local_cluster_runtime_status", runtimeJSON(running: true, enabled: true, active: true)),
            ("local_cluster_runtime_status", runtimeJSON(running: true, enabled: true, kubernetesAvailable: true))
        ])
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        var waits = 0
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {}, waitForRuntimePoll: { waits += 1 })
        try await service.resumeLocalRuntime()
        #expect(waits == 1)
        #expect(settings.bool(forKey: AgentBridgeService.disabledKey))
        #expect(registration.calls.isEmpty)
        #expect(await control.operations == ["status", "local_cluster_runtime_status", "local_cluster_runtime_resume", "status", "local_cluster_runtime_status", "status", "local_cluster_runtime_status"])
    }

    @Test @MainActor func stopTimeoutDoesNotUnregisterOrClaimStopped() async throws {
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_stop", #"{"active":true}"#),
            ("local_cluster_runtime_status", runtimeJSON(running: true, active: true))
        ])
        let registration = LocalRuntimeRegistration()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {}, runtimeOperationTimeout: .zero)
        await #expect(throws: AgentBridgeFailure.operationTimeout) { try await service.stopLocalRuntime() }
        #expect(registration.calls.isEmpty)
        #expect(await control.operations == ["status", "local_cluster_runtime_stop", "status", "local_cluster_runtime_status"])
    }

    @Test(arguments: [true, false]) @MainActor func directUnregisterRequiresObservedVMAndInstallerExit(_ running: Bool) async throws {
        let control = LocalRuntimeControlFixture([("local_cluster_runtime_status", runtimeJSON(running: running, active: !running))])
        let registration = LocalRuntimeRegistration()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {})
        await #expect(throws: AgentBridgeFailure.localRuntimeActive) { try await service.retireForReplacement() }
        #expect(registration.calls.isEmpty)
    }


    @Test(arguments: [true, false]) @MainActor func menuStopReleasesHelperOnlyWhenExternalConsumerIsDisabled(_ externalDisabled: Bool) async throws {
        let control = LocalRuntimeControlFixture(externalDisabled ? [("local_cluster_runtime_status", runtimeJSON())] : [])
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(externalDisabled, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.retireIfUnused()
        #expect(registration.calls == (externalDisabled ? ["unregister"] : []))
        #expect(await control.operations == (externalDisabled ? ["status", "local_cluster_runtime_status"] : []))
    }

    @Test @MainActor func failedProbeCannotReleaseHelperEvenWhenRunningIsFalse() async throws {
        let unknown = runtimeJSON().replacingOccurrences(of: "\"installer_active\":false", with: "\"installer_active\":false,\"safe_reason\":\"resource_unavailable\"")
        let control = LocalRuntimeControlFixture([
            ("local_cluster_runtime_status", unknown), ("local_cluster_runtime_status", unknown)
        ])
        let registration = LocalRuntimeRegistration(), settings = preferences()
        settings.set(true, forKey: AgentBridgeService.disabledKey)
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.retireIfUnused()
        await #expect(throws: AgentBridgeFailure.localRuntimeActive) { try await service.retireForReplacement() }
        #expect(registration.calls.isEmpty)
    }

    @Test @MainActor func enabledIntentAloneDoesNotPreventStoppedHelperReplacement() async throws {
        let control = LocalRuntimeControlFixture([("local_cluster_runtime_status", runtimeJSON(enabled: true))])
        let registration = LocalRuntimeRegistration()
        let service = AgentBridgeService(registration: registration, client: .init(transport: control),
            preferences: preferences(), requireSignature: {}, clearDisabledPreference: {})
        try await service.retireForReplacement()
        #expect(registration.calls == ["unregister"])
    }

    @Test(arguments: [true, false]) @MainActor func automaticReplacementDefersVMAndInstallerBeforeQuiescingExternalRuns(_ running: Bool) async throws {
        let lifecycle = LocalRuntimeUpdateFixture(), settings = preferences()
        lifecycle.running = running; lifecycle.installerActive = !running
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        await #expect(throws: AgentBridgeFailure.localRuntimeActive) { try await handoff.prepareReplacement() }
        try await handoff.cancelReplacement()
        #expect(lifecycle.calls == ["snapshot"])
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
    }

    @Test @MainActor func explicitStopAndUpdateWaitsForExitThenRestoresPreviousEnableIntent() async throws {
        let lifecycle = LocalRuntimeUpdateFixture(), settings = preferences()
        lifecycle.waitForStop = true
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        let task = Task { try await handoff.prepareReplacement(stoppingLocalRuntime: true) }
        for _ in 0..<100 where lifecycle.stopContinuation == nil { await Task.yield() }
        let stopped = try #require(lifecycle.stopContinuation)
        #expect(lifecycle.calls == ["snapshot", "stop-begin"])
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        stopped.resume()
        try await task.value
        #expect(lifecycle.calls == ["snapshot", "stop-begin", "stop-exited", "snapshot", "quiesce", "retire"])
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        try await handoff.restoreAtLaunch()
        #expect(lifecycle.calls.suffix(3) == ["restore", "resume-external", "resume-local"])
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
    }


    @Test(arguments: [true, false]) @MainActor func canceledExplicitUpdateRestoresOnlyPreviousLocalEnableIntent(_ enabled: Bool) async throws {
        let lifecycle = LocalRuntimeUpdateFixture(), settings = preferences()
        lifecycle.enabled = enabled
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        try await handoff.cancelReplacement()
        #expect(lifecycle.calls.contains("resume-local") == enabled)
        #expect(lifecycle.calls.contains("restore"))
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
    }


    @Test @MainActor func newReplacementCannotReuseAnOldLocalResumePreference() async throws {
        let lifecycle = LocalRuntimeUpdateFixture(), settings = preferences()
        lifecycle.running = false; lifecycle.enabled = false
        settings.set(true, forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey)
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        try await handoff.prepareReplacement()
        try await handoff.restoreAtLaunch()
        #expect(!lifecycle.calls.contains("resume-local"))
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
    }

    @Test @MainActor func unprovenStopCannotRetireEvenAfterStopCallReturns() async throws {
        let lifecycle = LocalRuntimeUpdateFixture()
        lifecycle.stopActuallySettles = false
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: preferences())
        await #expect(throws: AgentBridgeFailure.localRuntimeActive) {
            try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        }
        #expect(lifecycle.calls == ["snapshot", "stop-begin", "stop-exited", "snapshot"])
    }

    @Test @MainActor func localMenuUsesMachineEvidenceWithoutCloudReadinessOrForeignNames() throws {
        #expect(AgentBridgeMenu.localStatus(try runtimeSnapshot(running: true)) == "Local runtime is running. Agent status is available in settings.")
        #expect(AgentBridgeMenu.localStatus(try runtimeSnapshot(active: true)) == "A local runtime operation is in progress.")
        #expect(AgentBridgeMenu.localStatus(try runtimeSnapshot()) == "Local runtime is stopped. Agent files are retained.")
    }
}

/// Models the published helper protocol. Any new operation sent to a legacy
/// helper fails the test instead of being mistaken for an absent VM.
private actor VersionedHelperFixture: AgentBridgeControlTransport {
    enum Kind: Sendable { case legacy, managedProbeFailure }
    private let kind: Kind
    private(set) var operations: [String] = []
    init(_ kind: Kind) { self.kind = kind }
    func exchange(_ request: Data) throws -> Data {
        let envelope = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(envelope["operation"] as? String)
        operations.append(operation)
        var response: [String: Any] = ["version": 1, "request_id": envelope["request_id"]!]
        switch operation {
        case "status":
            var status: [String: Any] = ["connections": []]
            if kind == .managedProbeFailure { status["local_cluster_control_version"] = 1 }
            response["result"] = status
        case "quiesce": response["result"] = ["quiesced": true, "active_run_ids": []]
        case "stop_background": response["result"] = ["disabled": true]
        case "local_cluster_runtime_status" where kind == .managedProbeFailure:
            response["error"] = ["code": "service_unavailable", "message": "Untrusted runtime probe detail"]
        default:
            Issue.record("Unexpected operation for this helper version: \(operation)")
            throw AgentBridgeFailure.invalidRequest
        }
        return try JSONSerialization.data(withJSONObject: response)
    }
}

@Suite struct AgentBridgeLegacyHelperCompatibilityTests {
    @Test @MainActor func legacyHelperUpgradeUsesOnlyPublishedOperations() async throws {
        let helper = VersionedHelperFixture(.legacy), registration = LocalRuntimeRegistration()
        let settings = UserDefaults(suiteName: "AgentBridgeLegacyHelperCompatibilityTests." + UUID().uuidString)!
        let service = AgentBridgeService(registration: registration, client: .init(transport: helper),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        let handoff = AgentBridgeUpdateHandoff(service: service, preferences: settings)
        try await handoff.prepareReplacement()
        #expect(registration.calls == ["unregister"])
        #expect(await helper.operations == ["status", "quiesce", "status"])
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
    }

    @Test @MainActor func legacyHelperExternalStopStillUsesOnlyPublishedOperations() async throws {
        let helper = VersionedHelperFixture(.legacy), registration = LocalRuntimeRegistration()
        let settings = UserDefaults(suiteName: "AgentBridgeLegacyHelperCompatibilityTests." + UUID().uuidString)!
        let service = AgentBridgeService(registration: registration, client: .init(transport: helper),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        try await service.stopBackground()
        #expect(registration.calls == ["unregister"])
        #expect(await helper.operations == ["quiesce", "stop_background"])
        #expect(settings.bool(forKey: AgentBridgeService.disabledKey))
    }

    @Test @MainActor func advertisedRuntimeProbeFailureCannotFallBackToLegacyAbsence() async throws {
        let helper = VersionedHelperFixture(.managedProbeFailure), registration = LocalRuntimeRegistration()
        let settings = UserDefaults(suiteName: "AgentBridgeLegacyHelperCompatibilityTests." + UUID().uuidString)!
        let service = AgentBridgeService(registration: registration, client: .init(transport: helper),
            preferences: settings, requireSignature: {}, clearDisabledPreference: {})
        let handoff = AgentBridgeUpdateHandoff(service: service, preferences: settings)
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) { try await handoff.prepareReplacement() }
        #expect(registration.calls.isEmpty)
        #expect(await helper.operations == ["status", "local_cluster_runtime_status"])
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
    }
}
