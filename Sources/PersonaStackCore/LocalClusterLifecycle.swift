import Foundation

/// Native-only identity. Page commands never carry this binding.
public struct LocalClusterTargetBinding: Codable, Equatable, Sendable {
    public let integrationID: String
    public let installationID: String
    public init(integrationID: String, installationID: String) throws {
        guard integrationID.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              installationID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw AgentBridgeFailure.invalidRequest }
        self.integrationID = integrationID; self.installationID = installationID
    }
    enum CodingKeys: String, CodingKey { case integrationID = "integration_id", installationID = "installation_id" }
    public var controlValue: AgentBridgeValue {
        .object(["integration_id": .string(integrationID), "installation_id": .string(installationID)])
    }
    public func requireValid() throws { _ = try Self(integrationID: integrationID, installationID: installationID) }
}
public struct LocalClusterBindingStatus: Decodable, Sendable {
    public let binding: LocalClusterTargetBinding?
    public let previousRemovedBinding: LocalClusterTargetBinding?
    public let removed: Bool
    enum CodingKeys: String, CodingKey { case binding, removed, previousRemovedBinding = "previous_removed_binding" }
    public func requireConsistent() throws {
        try binding?.requireValid()
        try previousRemovedBinding?.requireValid()
    }
    public func requireFreshIdentity(_ keyID: String) throws {
        guard previousRemovedBinding?.installationID != keyID else { throw AgentBridgeFailure.credentialUnavailable }
    }
    public func requireFreshTarget(_ target: LocalClusterTargetBinding) throws {
        try requireFreshIdentity(target.installationID)
        guard previousRemovedBinding?.integrationID != target.integrationID else { throw AgentBridgeFailure.scopeChanged }
    }
}
public struct LocalClusterStatusChange: Decodable, Sendable {
    public let clusterID: String
    public let installationID: String
    public let status: String
    public let configVersion: Int64
    enum CodingKeys: String, CodingKey { case clusterID = "cluster_id", installationID = "installation_id", status, configVersion = "config_version" }
    public func require(binding: LocalClusterTargetBinding, status expected: String, previousVersion: Int64) throws {
        guard clusterID == binding.integrationID, installationID == binding.installationID,
              status == expected, configVersion > previousVersion else { throw AgentBridgeFailure.scopeChanged }
    }
}
public struct LocalClusterRetirement: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case retiring, retired }
    public let clusterID: String
    public let installationID: String
    public let state: State
    enum CodingKeys: String, CodingKey { case clusterID = "cluster_id", installationID = "installation_id", state = "retirement_state" }
    public func require(binding: LocalClusterTargetBinding) throws {
        guard clusterID == binding.integrationID, installationID == binding.installationID else { throw AgentBridgeFailure.scopeChanged }
    }
}
public struct LocalClusterLifecycle: Sendable {
    public enum Cloud: String, Sendable { case connected, disconnected, retirementPending = "retirement_pending", retired, unknown }
    public enum Local: String, Sendable { case running, stopped, removed, unknown }
    public enum Action: String, Sendable { case none, repairing, disconnecting, reconnecting, retiring, removing }
    public enum Failure: String, Sendable {
        case stopUnconfirmed = "stop_unconfirmed", statusChangeUnconfirmed = "status_change_unconfirmed"
        case retirementUnconfirmed = "retirement_unconfirmed", localStopUnconfirmed = "local_stop_unconfirmed", localStartUnconfirmed = "local_start_unconfirmed"
        case localRemovalUnconfirmed = "local_removal_unconfirmed", custodyUnavailable = "custody_unavailable"
        case bindingChanged = "binding_changed", newSetupUnconfirmed = "new_setup_unconfirmed"
    }
    public var cloud: Cloud = .unknown
    public var local: Local = .unknown
    public var action: Action = .none
    public var failure: Failure?
    public var availableActions: [String] = []
    public init() {}
    public var pageValue: [String: Any] {
        var value: [String: Any] = ["cloud": cloud.rawValue, "local": local.rawValue, "action": action.rawValue, "available_actions": availableActions]
        if let failure { value["failure"] = failure.rawValue }
        return value
    }
}
