import Foundation
import PersonaStackCore
import Testing

@MainActor private final class HandoffPolicyLifecycle: AgentBridgeUpdateLifecycle {
    var hasRegisteredService = true
    var canQuiesce = true
    var enabled: Bool
    var running = true
    var stopObservationFailures = 0
    var stopReturnedWithoutExit = 0
    var quiesceFailures = 0
    var retirementFailures = 0
    var localResumeFailures = 0
    private(set) var calls: [String] = []
    private(set) var localResumeCalls = 0

    init(enabled: Bool) { self.enabled = enabled }
    func localRuntimeSnapshot() async throws -> AgentBridgeLocalRuntimeSnapshot {
        calls.append("snapshot")
        let json = "{\"installed\":true,\"running\":\(running),\"enabled\":\(enabled),\"kubernetes_available\":false,\"installer_active\":false}"
        return try JSONDecoder().decode(AgentBridgeLocalRuntimeSnapshot.self, from: Data(json.utf8))
    }
    func stopLocalRuntime() async throws {
        calls.append("stop-disable-intent")
        // Runtime.Stop persists disabled intent before it can prove shutdown.
        // A lost observation must not make a later snapshot the original intent.
        enabled = false
        if stopObservationFailures > 0 {
            stopObservationFailures -= 1
            calls.append("stop-observation-failed")
            throw AgentBridgeFailure.operationTimeout
        }
        if stopReturnedWithoutExit > 0 {
            stopReturnedWithoutExit -= 1
            calls.append("stop-exit-unproven")
            return
        }
        running = false
        calls.append("stop-observed-exit")
    }
    func resumeLocalRuntime() async throws {
        calls.append("resume-local")
        if localResumeFailures > 0 {
            localResumeFailures -= 1
            throw AgentBridgeFailure.serviceUnavailable
        }
        localResumeCalls += 1
        enabled = true
        running = true
    }
    func quiesce() async throws -> AgentBridgeAdmission {
        calls.append("quiesce")
        if quiesceFailures > 0 {
            quiesceFailures -= 1
            throw AgentBridgeFailure.serviceUnavailable
        }
        return try JSONDecoder().decode(AgentBridgeAdmission.self,
            from: Data(#"{"active_run_ids":[],"quiesced":true}"#.utf8))
    }
    func resume() async throws { calls.append("resume-external") }
    func retireForReplacement() async throws {
        calls.append("retire")
        if retirementFailures > 0 {
            retirementFailures -= 1
            throw AgentBridgeFailure.serviceUnavailable
        }
        hasRegisteredService = false
    }
    func restoreAfterReplacement() async throws {
        calls.append("restore-registration")
        hasRegisteredService = true
    }
}

@Suite struct AgentBridgeUpdateHandoffPolicyTests {
    private func preferences() -> UserDefaults {
        UserDefaults(suiteName: "AgentBridgeUpdateHandoffPolicyTests." + UUID().uuidString)!
    }

    @MainActor private func finish(_ outcome: String, handoff: AgentBridgeUpdateHandoff) async throws {
        if outcome == "cancel" { try await handoff.cancelReplacement() }
        else { try await handoff.restoreAtLaunch() }
    }

    @Test(arguments: [true, false], ["cancel", "restore"]) @MainActor
    func retryAfterStopDisablesIntentRestoresOriginalChoice(_ originallyEnabled: Bool, _ outcome: String) async throws {
        let lifecycle = HandoffPolicyLifecycle(enabled: originallyEnabled), settings = preferences()
        lifecycle.stopObservationFailures = 1
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        await #expect(throws: AgentBridgeFailure.operationTimeout) {
            try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        }
        #expect(!lifecycle.enabled)
        #expect(lifecycle.running)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey) == originallyEnabled)
        #expect(!settings.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))

        try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey) == originallyEnabled)
        #expect(!lifecycle.enabled)
        try await finish(outcome, handoff: handoff)
        #expect(lifecycle.localResumeCalls == (originallyEnabled ? 1 : 0))
        #expect(lifecycle.enabled == originallyEnabled)
        #expect(settings.object(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey) == nil)
        #expect(settings.object(forKey: AgentBridgeUpdateHandoff.restoreKey) == nil)
    }


    @Test(arguments: ["cancel", "restore"]) @MainActor
    func failedExitReadbackPreservesOriginalIntentThroughRetry(_ outcome: String) async throws {
        let lifecycle = HandoffPolicyLifecycle(enabled: true), settings = preferences()
        lifecycle.stopReturnedWithoutExit = 1
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        await #expect(throws: AgentBridgeFailure.localRuntimeActive) {
            try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        }
        #expect(!lifecycle.enabled)
        #expect(lifecycle.running)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
        try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
        try await finish(outcome, handoff: handoff)
        #expect(lifecycle.localResumeCalls == 1)
        #expect(lifecycle.enabled)
    }

    @Test(arguments: ["quiesce", "retire"], ["cancel", "restore"]) @MainActor
    func laterFailureAndRetryPreserveCapturedEnabledIntent(_ failure: String, _ outcome: String) async throws {
        let lifecycle = HandoffPolicyLifecycle(enabled: true), settings = preferences()
        if failure == "quiesce" { lifecycle.quiesceFailures = 1 }
        else { lifecycle.retirementFailures = 1 }
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) {
            try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        }
        #expect(!lifecycle.enabled)
        #expect(!lifecycle.running)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))

        try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        #expect(lifecycle.calls.filter { $0 == "stop-disable-intent" }.count == 1)
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
        try await finish(outcome, handoff: handoff)
        #expect(lifecycle.localResumeCalls == 1)
        #expect(lifecycle.enabled)
        #expect(settings.object(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey) == nil)
    }

    @Test(arguments: ["cancel", "restore"]) @MainActor
    func failedLocalRestoreRetainsIntentUntilSuccessfulRetry(_ outcome: String) async throws {
        let lifecycle = HandoffPolicyLifecycle(enabled: true), settings = preferences()
        lifecycle.localResumeFailures = 1
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: settings)
        try await handoff.prepareReplacement(stoppingLocalRuntime: true)
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) { try await finish(outcome, handoff: handoff) }
        #expect(settings.bool(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey))
        try await finish(outcome, handoff: handoff)
        #expect(lifecycle.localResumeCalls == 1)
        #expect(settings.object(forKey: AgentBridgeUpdateHandoff.restoreLocalRuntimeKey) == nil)
        #expect(settings.object(forKey: AgentBridgeUpdateHandoff.restoreKey) == nil)
    }
}
