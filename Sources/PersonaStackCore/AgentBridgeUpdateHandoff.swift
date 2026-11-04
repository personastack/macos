import Foundation

@MainActor
public protocol AgentBridgeUpdateLifecycle: AnyObject {
    var hasRegisteredService: Bool { get }
    var canQuiesce: Bool { get }
    func localRuntimeSnapshot() async throws -> AgentBridgeLocalRuntimeSnapshot
    func stopLocalRuntime() async throws
    func resumeLocalRuntime() async throws
    func quiesce() async throws -> AgentBridgeAdmission
    func resume() async throws
    func retireForReplacement() async throws
    func restoreAfterReplacement() async throws
}
@MainActor
public final class AgentBridgeUpdateHandoff {
    public static let restoreKey = "agentBridge.restoreAfterAppUpdate"
    public static let restoreLocalRuntimeKey = "agentBridge.restoreLocalRuntimeAfterAppUpdate"
    private let service: any AgentBridgeUpdateLifecycle
    private let preferences: UserDefaults
    public private(set) var isPreparing = false
    private var quiesced = false
    private var retired = false
    private var stoppedLocalRuntime = false

    public init(service: any AgentBridgeUpdateLifecycle, preferences: UserDefaults = .standard) {
        self.service = service; self.preferences = preferences
    }
    public var needsHandoff: Bool { service.hasRegisteredService || retired }
    public var isReplacingHelper: Bool { isPreparing || retired }

    /// The caller decides whether to wait or Stop assigned work through the API.
    /// This method never substitutes Pause for a drain and never cancels a run.
    public func prepareReplacement(stoppingLocalRuntime: Bool = false) async throws {
        guard needsHandoff else { return }
        guard !isPreparing else { throw AgentBridgeFailure.busy }
        if retired { return }
        isPreparing = true
        defer { isPreparing = false }
        if !stoppedLocalRuntime { preferences.removeObject(forKey: Self.restoreLocalRuntimeKey) }
        if service.canQuiesce {
            let local = try await service.localRuntimeSnapshot()
            if local.preventsReplacement {
                guard stoppingLocalRuntime else { throw AgentBridgeFailure.localRuntimeActive }
                // Stop persists disabled intent before proving exit. Capture the
                // original choice once so a retry cannot overwrite it with false.
                if !stoppedLocalRuntime {
                    stoppedLocalRuntime = true
                    preferences.set(local.enabled, forKey: Self.restoreLocalRuntimeKey)
                }
                try await service.stopLocalRuntime()
                let stopped = try await service.localRuntimeSnapshot()
                guard !stopped.preventsReplacement else { throw AgentBridgeFailure.localRuntimeActive }
            }
            let result = try await service.quiesce()
            guard result.quiesced else { throw AgentBridgeFailure.serviceUnavailable }
            quiesced = true
            guard result.activeRunIDs.isEmpty else { throw AgentBridgeFailure.busy }
        }
        preferences.set(true, forKey: Self.restoreKey)
        try await service.retireForReplacement()
        retired = true
    }

    public func cancelReplacement() async throws {
        guard quiesced || retired || stoppedLocalRuntime else { return }
        let needsResume = quiesced || retired
        if retired {
            try await service.restoreAfterReplacement()
            retired = false
        }
        if needsResume { try await service.resume() }
        try await restoreLocalRuntimeIfNeeded()
        retired = false; quiesced = false; stoppedLocalRuntime = false
        preferences.removeObject(forKey: Self.restoreKey)
    }

    public func restoreAtLaunch() async throws {
        guard preferences.bool(forKey: Self.restoreKey) else { return }
        try await service.restoreAfterReplacement()
        retired = false
        try await service.resume()
        try await restoreLocalRuntimeIfNeeded()
        preferences.removeObject(forKey: Self.restoreKey)
        retired = false; quiesced = false; stoppedLocalRuntime = false
    }
    private func restoreLocalRuntimeIfNeeded() async throws {
        if preferences.bool(forKey: Self.restoreLocalRuntimeKey) { try await service.resumeLocalRuntime() }
        preferences.removeObject(forKey: Self.restoreLocalRuntimeKey)
    }
}
