import Foundation
import PersonaStackCore
import ServiceManagement

@MainActor
protocol AgentBridgeUpdateLifecycle: AnyObject {
    var hasRegisteredService: Bool { get }
    func hasPendingMigrationCapture() async throws -> Bool
    func quiesce() async throws -> AgentBridgeAdmission
    func resume() async throws
    func retireForReplacement() async throws
    func restoreAfterReplacement() async throws
}
extension AgentBridgeService: AgentBridgeUpdateLifecycle {
    var hasRegisteredService: Bool { status == .enabled || status == .requiresApproval }
}

@MainActor
final class AgentBridgeUpdateHandoff {
    static let shared = AgentBridgeUpdateHandoff()
    static let restoreKey = "agentBridge.restoreAfterAppUpdate"
    private let service: any AgentBridgeUpdateLifecycle
    private let preferences: UserDefaults
    private let pendingNativeMigration: @MainActor () -> Bool
    private(set) var isPreparing = false
    private var quiesced = false
    private var retired = false

    init(service: any AgentBridgeUpdateLifecycle = AgentBridgeService.shared, preferences: UserDefaults = .standard,
         pendingNativeMigration: @escaping @MainActor () -> Bool = { AgentBridgeSetupManager.shared.hasPendingMigrationCutover }) {
        self.service = service; self.preferences = preferences; self.pendingNativeMigration = pendingNativeMigration
    }
    var needsHandoff: Bool { service.hasRegisteredService || retired }

    /// The caller decides whether to wait or Stop assigned work through the API.
    /// This method never substitutes Pause for a drain and never cancels a run.
    func prepareReplacement() async throws {
        guard needsHandoff else { return }
        guard !isPreparing else { throw AgentBridgeFailure.busy }
        if retired { return }
        guard !pendingNativeMigration() else { throw AgentBridgeFailure.migrationIncomplete }
        let pendingCapture = try await service.hasPendingMigrationCapture()
        guard !pendingCapture else { throw AgentBridgeFailure.migrationIncomplete }
        isPreparing = true
        defer { isPreparing = false }
        let result = try await service.quiesce()
        guard result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
        quiesced = true
        guard result.activeRunIDs.isEmpty else { throw AgentBridgeFailure.busy }
        preferences.set(true, forKey: Self.restoreKey)
        try await service.retireForReplacement()
        retired = true
    }

    func cancelReplacement() async throws {
        guard quiesced || retired else { return }
        if retired { try await service.restoreAfterReplacement() }
        try await service.resume()
        retired = false; quiesced = false
        preferences.removeObject(forKey: Self.restoreKey)
    }

    func restoreAtLaunch() async throws {
        guard preferences.bool(forKey: Self.restoreKey) else { return }
        try await service.restoreAfterReplacement()
        try await service.resume()
        preferences.removeObject(forKey: Self.restoreKey)
        retired = false; quiesced = false
    }
}
