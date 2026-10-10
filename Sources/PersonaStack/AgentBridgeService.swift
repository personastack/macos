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

    init(registration: any AgentBridgeServiceRegistration = AgentBridgeSystemRegistration(),
         client: AgentBridgeControlClient = AgentBridgeControlClient(), preferences: UserDefaults = .standard,
         requireSignature: @escaping @MainActor () throws -> Void = AgentBridgeService.validateHelperIdentity,
         clearDisabledPreference: @escaping @MainActor () throws -> Void = { try AgentBridgeEnvironments.enable() }) {
        self.registration = registration; self.client = client; self.preferences = preferences
        self.requireSignature = requireSignature
        self.clearDisabledPreference = clearDisabledPreference
    }

    var status: SMAppService.Status { registration.status }

    /// Called only from an explicit native setup/enable action. It does not enroll.
    func ensureEnabled() async throws {
        try requireSignature()
        try clearDisabledPreference()
        if registration.status == .notRegistered || registration.status == .notFound { try registration.register() }
        guard registration.status == .enabled else {
            throw registration.status == .requiresApproval ? AgentBridgeFailure.backgroundApprovalRequired : .serviceUnavailable
        }
        // A stale macOS Enabled entry does not prove this bundle's helper answers.
        try await readBackControl()
        preferences.set(false, forKey: Self.disabledKey)
        preferences.removeObject(forKey: Self.errorKey)
    }

    func stopBackground() async throws {
        if registration.status == .requiresApproval {
            try await retireForReplacement()
            preferences.set(true, forKey: Self.disabledKey)
            return
        }
        guard registration.status == .enabled else { return }
        let pendingMigration = try await hasPendingMigrationCapture()
        guard !pendingMigration else { throw AgentBridgeFailure.migrationIncomplete }
        let admission = try await quiesce()
        guard admission.activeRunIDs.isEmpty else { throw AgentBridgeFailure.busy }
        let result = try await client.send(AgentBridgeRequest(operation: "stop_background", payload: [:]), returning: AgentBridgeAcknowledgement.self)
        guard result.disabled == true else { throw AgentBridgeFailure.serviceUnavailable }
        try await retireForReplacement()
        preferences.set(true, forKey: Self.disabledKey)
    }

    func hasPendingMigrationCapture() async throws -> Bool {
        let result = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]), returning: AgentBridgeConnections.self)
        guard let count = result.pendingMigrationCount, count >= 0 else { throw AgentBridgeFailure.unsupportedVersion }
        return count > 0
    }

    func quiesce() async throws -> AgentBridgeAdmission {
        let result = try await client.send(AgentBridgeRequest(operation: "quiesce", payload: [:]), returning: AgentBridgeAdmission.self)
        guard result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
        return result
    }
    func resume() async throws {
        let result = try await client.send(AgentBridgeRequest(operation: "resume", payload: [:]), returning: AgentBridgeAdmission.self)
        guard !result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
    }
    func retireForReplacement() async throws {
        try await registration.unregister()
        guard [.notRegistered, .notFound].contains(registration.status) else { throw AgentBridgeFailure.serviceUnavailable }
    }
    func restoreAfterReplacement() async throws {
        guard !preferences.bool(forKey: Self.disabledKey) else { return }
        try await ensureEnabled()
    }
    private func readBackControl() async throws {
        // SMAppService launches asynchronously. Only transport-unavailable may
        // retry. Malformed protocol or denied credentials never become Ready.
        for attempt in 0..<10 {
            do {
                _ = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]), returning: AgentBridgeConnections.self)
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
