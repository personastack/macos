import Foundation
import PersonaStackCore
import Testing

@Suite struct DesktopUninstallCoordinatorTests {
    @Test @MainActor func controlRemovalPrecedesBothUnregistrations() async throws {
        var calls: [String] = []
        let coordinator = DesktopUninstallCoordinator(acquireApplicationOwner: { calls.append("application-owner"); return true },
            controlAvailable: { true },
            removeUsingControl: { calls.append("verified-remove") },
            removeUsingBundledHelper: { Issue.record("Do not run another removal owner") },
            unregisterAgentBridge: { calls.append("bridge") },
            unregisterLoginItems: { calls.append("login") })
        try await coordinator.run()
        #expect(calls == ["application-owner", "verified-remove", "bridge", "login"])
    }

    @Test @MainActor func busyApplicationOwnerHasZeroCleanupEffects() async {
        let coordinator = DesktopUninstallCoordinator(acquireApplicationOwner: { false },
            controlAvailable: { Issue.record("Do not observe service before acquiring app ownership"); return true },
            removeUsingControl: { Issue.record("Running GUI retains its runtime") },
            removeUsingBundledHelper: { Issue.record("Running GUI retains its offline tools") },
            unregisterAgentBridge: { Issue.record("Running GUI retains background registration") },
            unregisterLoginItems: { Issue.record("Running GUI retains login registration") })
        await #expect(throws: AgentBridgeFailure.busy) { try await coordinator.run() }
    }

    @Test @MainActor func disabledOrApprovalPendingHelperIsNeverEnabled() async throws {
        var calls: [String] = []
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { false },
            removeUsingControl: { Issue.record("Disabled service must not be started") },
            removeUsingBundledHelper: { calls.append("offline-remove") },
            unregisterAgentBridge: { calls.append("bridge") },
            unregisterLoginItems: { calls.append("login") })
        try await coordinator.run()
        #expect(calls == ["offline-remove", "bridge", "login"])
    }

    @Test @MainActor func unreachableControlUsesOfflineOwnerBeforeUnregistering() async throws {
        var calls: [String] = []
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { true },
            removeUsingControl: { calls.append("control"); throw AgentBridgeFailure.serviceUnavailable },
            removeUsingBundledHelper: { calls.append("offline-remove") },
            unregisterAgentBridge: { calls.append("bridge") },
            unregisterLoginItems: { calls.append("login") })
        try await coordinator.run()
        #expect(calls == ["control", "offline-remove", "bridge", "login"])
    }

    @Test(arguments: [AgentBridgeFailure.operationTimeout, .runtimeUnsupported, .busy, .cleanupRequired])
    @MainActor func uncertainControlRemovalNeverRetiresTools(_ failure: AgentBridgeFailure) async {
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { true },
            removeUsingControl: { throw failure },
            removeUsingBundledHelper: { Issue.record("Do not bypass a reported removal failure") },
            unregisterAgentBridge: { Issue.record("Keep helper for retry") },
            unregisterLoginItems: { Issue.record("Keep app registration for retry") })
        await #expect(throws: failure) { try await coordinator.run() }
    }

    @Test @MainActor func busyOfflineOwnerNeverRetiresTools() async {
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { true },
            removeUsingControl: { throw AgentBridgeFailure.serviceUnavailable },
            removeUsingBundledHelper: { throw AgentBridgeFailure.busy },
            unregisterAgentBridge: { Issue.record("Live owner must remain registered") },
            unregisterLoginItems: { Issue.record("Keep app available") })
        await #expect(throws: AgentBridgeFailure.busy) { try await coordinator.run() }
    }

    @Test @MainActor func repeatedAbsentDataUninstallRemainsSuccessful() async throws {
        var calls: [String] = []
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { false },
            removeUsingControl: { Issue.record("No registered service") },
            removeUsingBundledHelper: { calls.append("verified-absent") },
            unregisterAgentBridge: { calls.append("already-unregistered") },
            unregisterLoginItems: { calls.append("already-unregistered-login") })
        try await coordinator.run()
        try await coordinator.run()
        #expect(calls == ["verified-absent", "already-unregistered", "already-unregistered-login",
                          "verified-absent", "already-unregistered", "already-unregistered-login"])
    }

    @Test @MainActor func failedAgentUnregisterStopsBeforeOtherRegistrations() async {
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { false },
            removeUsingControl: { Issue.record("No control") }, removeUsingBundledHelper: {},
            unregisterAgentBridge: { throw AgentBridgeFailure.serviceUnavailable },
            unregisterLoginItems: { Issue.record("Keep remaining registration for retry") })
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) { try await coordinator.run() }
    }

    @Test @MainActor func offlineCommandVerifiesSignatureBeforeExactBundledInvocation() async throws {
        var calls: [String] = []
        let command = DesktopUninstallHelperCommand(bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"))
        try await command.run(verifySignature: { calls.append("signature") }, execute: { executable, arguments in
            calls.append("execute")
            #expect(executable.path == "/Applications/PersonaStack.app/Contents/MacOS/PersonaStackAgentBridge")
            #expect(arguments == ["--remove-local-runtime"])
        })
        #expect(calls == ["signature", "execute"])
    }

    @Test @MainActor func signatureFailureNeverExecutesHelper() async {
        let command = DesktopUninstallHelperCommand(bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"))
        await #expect(throws: AgentBridgeFailure.serviceUnavailable) {
            try await command.run(verifySignature: { throw AgentBridgeFailure.serviceUnavailable },
                execute: { _, _ in Issue.record("Unverified executable must not run") })
        }
    }

    @Test @MainActor func offlineTimeoutNeverUnregisters() async {
        let command = DesktopUninstallHelperCommand(bundleURL: URL(fileURLWithPath: "/Applications/PersonaStack.app"))
        let coordinator = DesktopUninstallCoordinator(controlAvailable: { false }, removeUsingControl: {},
            removeUsingBundledHelper: {
                try await command.run(verifySignature: {}, execute: { _, _ in throw AgentBridgeFailure.operationTimeout })
            }, unregisterAgentBridge: { Issue.record("Keep helper after timeout") },
            unregisterLoginItems: { Issue.record("Keep app after timeout") })
        await #expect(throws: AgentBridgeFailure.operationTimeout) { try await coordinator.run() }
    }
}
