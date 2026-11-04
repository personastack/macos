import Foundation
import PersonaStackCore
import Security
import ServiceManagement

@MainActor
protocol AgentBridgeServiceRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
struct AgentBridgeSystemRegistration: AgentBridgeServiceRegistration {
    private var service: SMAppService { .agent(plistName: AgentBridgeService.plistName) }
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
}

@MainActor
final class AgentBridgeService {
    static let shared = AgentBridgeService()
    static let plistName = "ai.personastack.desktop.agent-bridge.plist"
    static let disabledKey = "agentBridge.backgroundDisabled"
    static let errorKey = "agentBridge.backgroundError"
    private let registration: any AgentBridgeServiceRegistration
    private let client: AgentBridgeControlClient
    private let preferences: UserDefaults
    private let requireSignature: @MainActor () throws -> Void
    private let clearDisabledPreference: @MainActor () throws -> Void
    private let waitForRuntimePoll: @MainActor () async throws -> Void
    private let runtimeOperationTimeout: Duration

    init(registration: any AgentBridgeServiceRegistration = AgentBridgeSystemRegistration(),
         client: AgentBridgeControlClient = AgentBridgeControlClient(), preferences: UserDefaults = .standard,
         requireSignature: @escaping @MainActor () throws -> Void = AgentBridgeService.validateHelperIdentity,
         clearDisabledPreference: @escaping @MainActor () throws -> Void = { try AgentBridgeEnvironments.enable() },
         waitForRuntimePoll: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
         runtimeOperationTimeout: Duration = .seconds(40)) {
        self.registration = registration; self.client = client; self.preferences = preferences
        self.requireSignature = requireSignature
        self.clearDisabledPreference = clearDisabledPreference
        self.waitForRuntimePoll = waitForRuntimePoll
        self.runtimeOperationTimeout = runtimeOperationTimeout
    }

    var status: SMAppService.Status { registration.status }

    /// Called only from an explicit native setup/enable action. It does not enroll.
    func ensureEnabled() async throws {
        try await enableRegistration(enableExternalAgents: true)
    }

    /// Cluster setup reuses registration without enabling Hermes/OpenClaw.
    func ensureLocalClusterEnabled() async throws {
        try await enableRegistration(enableExternalAgents: false)
    }

    private func enableRegistration(enableExternalAgents: Bool, restoringReplacement: Bool = false) async throws {
        guard restoringReplacement || !AgentBridgeUpdateHandoff.shared.isReplacingHelper else { throw AgentBridgeFailure.busy }
        try requireSignature()
        // Explicit setup may unblock helper startup. External admission and
        // its saved disabled intent remain separate from this shared marker.
        try clearDisabledPreference()
        if registration.status == .notRegistered || registration.status == .notFound { try registration.register() }
        guard registration.status == .enabled else {
            throw registration.status == .requiresApproval ? AgentBridgeFailure.backgroundApprovalRequired : .serviceUnavailable
        }
        // A stale macOS Enabled entry does not prove this bundle's helper answers.
        try await readBackControl(localCluster: !enableExternalAgents)
        if enableExternalAgents { preferences.set(false, forKey: Self.disabledKey) }
        preferences.removeObject(forKey: Self.errorKey)
    }

    func stopBackground() async throws {
        if registration.status == .requiresApproval {
            try await unregisterObservedStopped()
            preferences.set(true, forKey: Self.disabledKey)
            return
        }
        guard registration.status == .enabled else { return }
        let admission = try await quiesce()
        guard admission.activeRunIDs.isEmpty else { throw AgentBridgeFailure.busy }
        let result = try await client.send(AgentBridgeRequest(operation: "stop_background", payload: [:]), returning: AgentBridgeAcknowledgement.self)
        guard result.disabled == true else { throw AgentBridgeFailure.serviceUnavailable }
        // The helper makes this decision alongside its guarded shutdown.
        // Older helpers omit keep_service and have no cluster consumer.
        if result.keepService != true { try await unregisterObservedStopped() }
        preferences.set(true, forKey: Self.disabledKey)
    }

    func quiesce() async throws -> AgentBridgeAdmission {
        let result = try await client.send(AgentBridgeRequest(operation: "quiesce", payload: [:]), returning: AgentBridgeAdmission.self)
        guard result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
        return result
    }
    func resume() async throws {
        guard !preferences.bool(forKey: Self.disabledKey) else { return }
        let result = try await client.send(AgentBridgeRequest(operation: "resume", payload: [:]), returning: AgentBridgeAdmission.self)
        guard !result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
    }
    /// Absence identifies the deployed pre-feature helper. A present version
    /// has already passed the narrow status DTO's strict compatibility gate.
    /// External inventory errors remain independent from local machine control.
    func localClusterControlVersion() async throws -> Int? {
        let status = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]),
                                            returning: AgentBridgeLocalClusterControlCapability.self)
        return status.localClusterControlVersion
    }

    /// Fresh setup alone needs these strict resource inputs. Emergency controls
    /// continue to use the independent version-only reader above.
    func localClusterRequirements() async throws -> AgentBridgeLocalClusterRequirements {
        let status = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]),
                                          returning: AgentBridgeLocalClusterRequirementsStatus.self)
        guard status.localClusterControlVersion == 1, let requirements = status.localClusterRequirements else { throw AgentBridgeFailure.runtimeUnsupported }
        return requirements
    }

    func localRuntimeSnapshot() async throws -> AgentBridgeLocalRuntimeSnapshot {
        guard try await localClusterControlVersion() != nil else { return .legacyNoLocalConsumer }
        return try await currentLocalRuntimeSnapshot()
    }

    private func currentLocalRuntimeSnapshot() async throws -> AgentBridgeLocalRuntimeSnapshot {
        try await client.send(AgentBridgeRequest(operation: "local_cluster_runtime_status", payload: [:]),
                              returning: AgentBridgeLocalRuntimeSnapshot.self)
    }

    /// An explicit native action. It requires no cloud session and retains disks.
    /// A stop reply only starts the work. Status joins actual VM/process exit.
    func stopLocalRuntime() async throws {
        if registration.status != .enabled { try await ensureLocalClusterEnabled() }
        guard try await localClusterControlVersion() != nil else { return }
        let deadline = ContinuousClock.now.advanced(by: runtimeOperationTimeout)
        _ = try await client.send(AgentBridgeRequest(operation: "local_cluster_runtime_stop", payload: [:]),
                                  returning: AgentBridgeLocalRuntimeAcknowledgement.self)
        try await waitForLocalRuntime(deadline: deadline) { !$0.preventsReplacement && !$0.enabled }
    }

    func resumeLocalRuntime() async throws {
        try await ensureLocalClusterEnabled()
        let deadline = ContinuousClock.now.advanced(by: runtimeOperationTimeout)
        _ = try await client.send(AgentBridgeRequest(operation: "local_cluster_runtime_resume", payload: [:]),
                                  returning: AgentBridgeLocalRuntimeAcknowledgement.self)
        try await waitForLocalRuntime(deadline: deadline) {
            $0.enabled && $0.running && $0.kubernetesAvailable && !$0.installerActive && ($0.safeReason ?? "").isEmpty
        }
    }

    /// The native menu owns destructive confirmation. The common removal task
    /// owns initial Stop, stopped-process proof and partially erased retries.
    func removeLocalRuntimeData() async throws {
        if registration.status != .enabled { try await ensureLocalClusterEnabled() }
        guard try await localClusterControlVersion() != nil else { throw AgentBridgeFailure.runtimeUnsupported }
        let deadline = ContinuousClock.now.advanced(by: runtimeOperationTimeout)
        _ = try await client.send(AgentBridgeRequest(operation: "local_cluster_remove", payload: [:]),
                                  returning: AgentBridgeLocalRuntimeAcknowledgement.self)
        try await waitForLocalRuntime(deadline: deadline) {
            $0.safeReason == "local_data_removed" && !$0.installed && !$0.running && !$0.kubernetesAvailable && !$0.enabled && !$0.installerActive
        }
    }

    private func waitForLocalRuntime(deadline: ContinuousClock.Instant,
                                     until settled: (AgentBridgeLocalRuntimeSnapshot) -> Bool) async throws {
        while true {
            let snapshot = try await localRuntimeSnapshot()
            if settled(snapshot) { return }
            guard ContinuousClock.now < deadline else { throw AgentBridgeFailure.operationTimeout }
            try await waitForRuntimePoll()
        }
    }

    /// Menu Stop can release the helper only when both consumers disabled it.
    /// Update handoff keeps registration until its own observed-exit gate.
    func retireIfUnused() async throws {
        guard preferences.bool(forKey: Self.disabledKey), registration.status == .enabled else { return }
        // Local Stop/Remove can finish without Keychain access. Releasing the
        // shared helper still requires a known external inventory and intent.
        let external = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]),
                                              returning: AgentBridgeConnections.self)
        let snapshot: AgentBridgeLocalRuntimeSnapshot
        if external.localClusterControlVersion == nil { snapshot = .legacyNoLocalConsumer }
        else { snapshot = try await currentLocalRuntimeSnapshot() }
        guard !snapshot.keepsService else { return }
        try await unregisterObservedStopped()
    }

    func retireForReplacement() async throws {
        if registration.status == .enabled {
            let snapshot = try await localRuntimeSnapshot()
            guard !snapshot.preventsReplacement else { throw AgentBridgeFailure.localRuntimeActive }
        }
        try await unregisterObservedStopped()
    }
    private func unregisterObservedStopped() async throws {
        try await registration.unregister()
        guard [.notRegistered, .notFound].contains(registration.status) else { throw AgentBridgeFailure.serviceUnavailable }
    }
    func restoreAfterReplacement() async throws {
        if preferences.bool(forKey: Self.disabledKey) {
            // The saved handoff can belong solely to the cluster consumer.
            guard preferences.bool(forKey: AgentBridgeUpdateHandoff.restoreKey) else { return }
            try await enableRegistration(enableExternalAgents: false, restoringReplacement: true)
        } else { try await enableRegistration(enableExternalAgents: true, restoringReplacement: true) }
    }
    private func readBackControl(localCluster: Bool = false) async throws {
        // SMAppService launches asynchronously. Only transport-unavailable may
        // retry. Malformed protocol or denied credentials never become Ready.
        for attempt in 0..<10 {
            do {
                if localCluster {
                    guard try await localClusterControlVersion() != nil else { throw AgentBridgeFailure.runtimeUnsupported }
                    _ = try await currentLocalRuntimeSnapshot()
                }
                else { _ = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]), returning: AgentBridgeConnections.self) }
                return
            } catch AgentBridgeFailure.serviceUnavailable where attempt < 9 {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw AgentBridgeFailure.serviceUnavailable
    }

    static func validateHelperIdentity() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PersonaStackAgentBridge")
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let expected = "identifier \"ai.personastack.desktop.agent-bridge\" and anchor apple generic and certificate leaf[subject.OU] = \"5T2T8KL852\""
        guard DesktopLoginItemRegistration.hasValidBundleSignature(),
              SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw AgentBridgeFailure.serviceUnavailable
        }
    }
}
