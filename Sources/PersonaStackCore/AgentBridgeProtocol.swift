import Foundation
import CoreFoundation

public enum AgentBridgeFailure: String, Error, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case scopeChanged = "scope_changed"
    case profileInUse = "profile_in_use"
    case runtimeUnsupported = "runtime_unsupported"
    case runtimeConflict = "runtime_conflict"
    case runtimeOccupied = "runtime_occupied"
    case attemptChanged = "attempt_changed"
    case localRuntimeActive = "local_runtime_active"
    case enrollmentUncertain = "enrollment_uncertain"
    case credentialUnavailable = "credential_unavailable"
    case reconnectRequired = "reconnect_required"
    case busy
    case cleanupRequired = "cleanup_required"
    case backgroundApprovalRequired = "background_approval_required"
    case serviceUnavailable = "service_unavailable"
    case operationTimeout = "operation_timeout"
    case hermesHostConsentRequired = "hermes_host_consent_required"
}

public enum AgentBridgeRuntime: String, Codable, Sendable, CaseIterable { case hermes, openclaw }

public struct AgentBridgeBindingKey: Codable, Equatable, Sendable {
    public let environmentID: String
    public let connectionID: String
    public init(environmentID: String, connectionID: String) {
        self.environmentID = environmentID; self.connectionID = connectionID
    }
    enum CodingKeys: String, CodingKey { case environmentID = "environment_id", connectionID = "connection_id" }
}

public struct AgentBridgeNativeAgent: Codable, Sendable {
    public let agentCandidateID: String
    public let label: String
    enum CodingKeys: String, CodingKey { case agentCandidateID = "agent_candidate_id", label }
}
public struct AgentBridgeProfile: Codable, Sendable {
    public let profileCandidateID: String
    public let accountCandidateID: String
    public let label: String
    public let runtimeKind: AgentBridgeRuntime
    public let conflictCode: String?
    public let openClawAgents: [AgentBridgeNativeAgent]?
    public let selectedAgentCandidateID: String?
    enum CodingKeys: String, CodingKey {
        case profileCandidateID = "profile_candidate_id", accountCandidateID = "account_candidate_id", label
        case runtimeKind = "runtime_kind", conflictCode = "conflict_code"
        case openClawAgents = "openclaw_agents", selectedAgentCandidateID = "selected_agent_candidate_id"
    }
}

public struct AgentBridgeDiscovery: Codable, Sendable {
    public let profiles: [AgentBridgeProfile]
    public let discoveryStatus: String
    enum CodingKeys: String, CodingKey { case profiles, discoveryStatus = "discovery_status" }
}

public struct AgentBridgePreparation: Codable, Sendable {
    public let preparationID: UUID?
    public let devicePublicKey: String?
    public let profileCandidateID: String?
    public let expiresAt: String?
    public let existingBindingKey: AgentBridgeBindingKey?
    enum CodingKeys: String, CodingKey {
        case preparationID = "preparation_id", devicePublicKey = "device_public_key"
        case profileCandidateID = "profile_candidate_id", expiresAt = "expires_at", existingBindingKey = "existing_binding_key"
    }
}

public struct AgentBridgeRetainedTarget: Codable, Sendable {
    public let workspaceID: String
    public let accountCandidateID: String
    public let profileCandidateID: String
    public let runtimeKind: AgentBridgeRuntime
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", accountCandidateID = "account_candidate_id"
        case profileCandidateID = "profile_candidate_id", runtimeKind = "runtime_kind"
    }
}
public struct AgentBridgeConnection: Codable, Sendable {
    public let bindingKey: AgentBridgeBindingKey
    public let personaID: String
    public let runtimeKind: AgentBridgeRuntime
    public let readinessState: String
    public let connectionGeneration: Int?
    public let preparedTarget: AgentBridgeRetainedTarget?
    public let activeRunID: String?
    public let diagnosticCode: String?
    public let diagnosticMessage: String?
    public var isMCPVerified: Bool { readinessState == "mcp_verified" }
    public var requiresReconnect: Bool {
        ["reconnect_required", "mcp_token_rejected", "mcp_auth_missing"].contains(diagnosticCode ?? "")
    }
    enum CodingKeys: String, CodingKey {
        case bindingKey = "binding_key", personaID = "persona_id", runtimeKind = "runtime_kind"
        case readinessState = "readiness_state", activeRunID = "active_run_id"
        case diagnosticCode = "diagnostic_code", diagnosticMessage = "diagnostic_message"
        case connectionGeneration = "connection_generation", preparedTarget = "prepared_target"
    }
}
/// Reads only the local helper capability. External Keychain failure cannot
/// remove the machine owner's ability to stop or erase its managed local VM.
public struct AgentBridgeLocalClusterControlCapability: Decodable, Sendable {
    public let localClusterControlVersion: Int?
    enum CodingKeys: String, CodingKey { case localClusterControlVersion = "local_cluster_control_version" }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.localClusterControlVersion) {
            guard let version = try? values.decode(Int.self, forKey: .localClusterControlVersion), version == 1 else {
                throw AgentBridgeFailure.runtimeUnsupported
            }
            localClusterControlVersion = version
        } else { localClusterControlVersion = nil }
    }
}

/// Display and preflight inputs come from the initialized runtime owner.
/// This decoder validates representation, not a second native resource policy.
public struct AgentBridgeLocalClusterRequirements: Decodable, Equatable, Sendable {
    public let cpus: Int
    public let memoryBytes: Int64
    public let diskBytes: Int64
    public let initialDownloadBytes: Int64
    public let minimumHostMemoryBytes: Int64
    enum CodingKeys: String, CodingKey {
        case cpus, memoryBytes = "memory_bytes", diskBytes = "disk_bytes"
        case initialDownloadBytes = "initial_download_bytes", minimumHostMemoryBytes = "minimum_host_memory_bytes"
    }
    public init(cpus: Int, memoryBytes: Int64, diskBytes: Int64, initialDownloadBytes: Int64, minimumHostMemoryBytes: Int64) throws {
        guard cpus > 0, memoryBytes > 0, diskBytes > 0, initialDownloadBytes > 0, minimumHostMemoryBytes > 0 else { throw AgentBridgeFailure.runtimeUnsupported }
        self.cpus = cpus; self.memoryBytes = memoryBytes; self.diskBytes = diskBytes
        self.initialDownloadBytes = initialDownloadBytes; self.minimumHostMemoryBytes = minimumHostMemoryBytes
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cpus: values.decode(Int.self, forKey: .cpus), memoryBytes: values.decode(Int64.self, forKey: .memoryBytes),
            diskBytes: values.decode(Int64.self, forKey: .diskBytes), initialDownloadBytes: values.decode(Int64.self, forKey: .initialDownloadBytes),
            minimumHostMemoryBytes: values.decode(Int64.self, forKey: .minimumHostMemoryBytes))
    }
    public func supportsHost(physicalMemoryBytes: UInt64, activeProcessorCount: Int) -> Bool {
        physicalMemoryBytes >= UInt64(minimumHostMemoryBytes) && activeProcessorCount >= cpus
    }
}

/// Resource corruption must not poison the version-only emergency control read.
public struct AgentBridgeLocalClusterRequirementsStatus: Decodable, Sendable {
    public let localClusterControlVersion: Int?
    public let localClusterRequirements: AgentBridgeLocalClusterRequirements?
    enum CodingKeys: String, CodingKey { case localClusterRequirements = "local_cluster_requirements" }
    public init(from decoder: any Decoder) throws {
        localClusterControlVersion = try AgentBridgeLocalClusterControlCapability(from: decoder).localClusterControlVersion
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.localClusterRequirements) {
            guard localClusterControlVersion == 1,
                  let requirements = try? values.decode(AgentBridgeLocalClusterRequirements.self, forKey: .localClusterRequirements) else { throw AgentBridgeFailure.runtimeUnsupported }
            localClusterRequirements = requirements
        } else { localClusterRequirements = nil }
    }
}

private struct AgentBridgeExternalStatusError: Decodable {
    let code: String
    let message: String
}

public struct AgentBridgeConnections: Codable, Sendable {
    public let connections: [AgentBridgeConnection]
    public let localClusterControlVersion: Int?
    enum CodingKeys: String, CodingKey {
        case connections, localClusterControlVersion = "local_cluster_control_version", externalError = "external_error"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.externalError) {
            guard let error = try? values.decode(AgentBridgeExternalStatusError.self, forKey: .externalError),
                  error.code == AgentBridgeFailure.credentialUnavailable.rawValue, error.message.utf8.count <= 4096 else {
                throw AgentBridgeFailure.invalidRequest
            }
            throw AgentBridgeFailure.credentialUnavailable
        }
        connections = try values.decode([AgentBridgeConnection].self, forKey: .connections)
        localClusterControlVersion = try AgentBridgeLocalClusterControlCapability(from: decoder).localClusterControlVersion
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(connections, forKey: .connections)
        try values.encodeIfPresent(localClusterControlVersion, forKey: .localClusterControlVersion)
    }
}
public struct AgentBridgeEnrollment: Codable, Sendable {
    public let bindingKey: AgentBridgeBindingKey
    public let personaID: String
    enum CodingKeys: String, CodingKey { case bindingKey = "binding_key", personaID = "persona_id" }
}
public struct AgentBridgeAdmission: Codable, Sendable {
    public let activeRunIDs: [String]
    public let quiesced: Bool
    enum CodingKeys: String, CodingKey { case activeRunIDs = "active_run_ids", quiesced }
}
public struct AgentBridgeAcknowledgement: Codable, Sendable {
    public let disabled: Bool?
    public let disconnected: Bool?
    public let keepService: Bool?
    enum CodingKeys: String, CodingKey { case disabled, disconnected, keepService = "keep_service" }
}

public struct AgentBridgeLocalRuntimeAcknowledgement: Decodable, Sendable {
    public let active: Bool
}

/// Machine-owner lifecycle evidence. It never carries account or persona metadata.
/// These booleans describe the local VM, not cloud connection or agent readiness.
public struct AgentBridgeLocalRuntimeSnapshot: Codable, Sendable, Equatable {
    public let installed: Bool
    public let running: Bool
    public let kubernetesAvailable: Bool
    public let enabled: Bool
    public let installerActive: Bool
    public let safeReason: String?
    public var hasBlockingReason: Bool {
        guard let safeReason, !safeReason.isEmpty else { return false }
        return safeReason != "local_data_removed" || installed || running || kubernetesAvailable || enabled || installerActive
    }
    public var preventsReplacement: Bool { running || installerActive || hasBlockingReason }
    /// A pre-feature helper advertises no VM consumer through its existing status.
    /// This value is replacement compatibility evidence, never product readiness.
    public static let legacyNoLocalConsumer = Self(installed: false, running: false, kubernetesAvailable: false,
        enabled: false, installerActive: false, safeReason: nil)
    public var keepsService: Bool { enabled || preventsReplacement }
    enum CodingKeys: String, CodingKey {
        case installed, running, enabled
        case kubernetesAvailable = "kubernetes_available", installerActive = "installer_active", safeReason = "safe_reason"
    }
}

/// The payload comes from native types. Page messages are decoded separately.
public struct AgentBridgeRequest: Encodable, Sendable {
    public static let maximumBytes = 256 * 1024
    public let requestID: UUID
    public let operation: String
    private let payload: [String: AgentBridgeValue]
    public init(requestID: UUID = UUID(), operation: String, payload: [String: AgentBridgeValue]) throws {
        guard ["discover", "prepare", "enroll", "status", "check", "repair", "disconnect", "quiesce", "resume", "stop_background",
               "local_cluster_start", "local_cluster_status", "local_cluster_cancel",
               "local_cluster_runtime_status", "local_cluster_runtime_stop", "local_cluster_runtime_resume",
               "local_cluster_apply", "local_cluster_binding", "local_cluster_remove", "local_cluster_new_setup"].contains(operation) else {
            throw AgentBridgeFailure.invalidRequest
        }
        self.requestID = requestID; self.operation = operation; self.payload = payload
    }
    enum CodingKeys: String, CodingKey { case version, requestID = "request_id", operation, payload }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try values.encode(operation, forKey: .operation)
        try values.encode(payload, forKey: .payload)
    }
    public func encoded() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard data.count < Self.maximumBytes else { throw AgentBridgeFailure.invalidRequest }
        data.append(10)
        return data
    }
}

public indirect enum AgentBridgeValue: Codable, Sendable {
    case string(String), integer(Int), bool(Bool), object([String: AgentBridgeValue]), array([AgentBridgeValue]), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Int.self) { self = .integer(number) }
        else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else { self = .array(try value.decode([Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let data): try value.encode(data)
        case .integer(let data): try value.encode(data)
        case .bool(let data): try value.encode(data)
        case .object(let data): try value.encode(data)
        case .array(let data): try value.encode(data)
        case .null: try value.encodeNil()
        }
    }
}

public enum AgentBridgeResponse {
    public static func decode<T: Decodable>(_ type: T.Type, data: Data, requestID: UUID) throws -> T {
        guard data.count <= AgentBridgeRequest.maximumBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "request_id", "result", "error"]),
              object["version"] as? Int == 1,
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              let id = object["request_id"] as? String, UUID(uuidString: id) == requestID,
              (object["result"] != nil) != (object["error"] != nil) else { throw AgentBridgeFailure.invalidRequest }
        if let error = object["error"] as? [String: Any] {
            guard Set(error.keys) == ["code", "message"], let code = error["code"] as? String,
                  let message = error["message"] as? String, message.utf8.count <= 4096 else { throw AgentBridgeFailure.invalidRequest }
            throw AgentBridgeFailure(rawValue: code) ?? .serviceUnavailable
        }
        guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else { throw AgentBridgeFailure.invalidRequest }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
    }
}
