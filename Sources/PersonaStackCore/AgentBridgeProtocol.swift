import Foundation
import CoreFoundation

public enum AgentBridgeFailure: String, Error, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedVersion = "unsupported_version"
    case scopeChanged = "scope_changed"
    case profileInUse = "profile_in_use"
    case runtimeUnsupported = "runtime_unsupported"
    case runtimeConflict = "runtime_conflict"
    case credentialUnavailable = "credential_unavailable"
    case busy
    case cleanupRequired = "cleanup_required"
    case migrationRequired = "migration_required"
    case backgroundApprovalRequired = "background_approval_required"
    case serviceUnavailable = "service_unavailable"
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

public struct AgentBridgeProfile: Codable, Sendable {
    public let profileCandidateID: String
    public let accountCandidateID: String
    public let label: String
    public let runtimeKind: AgentBridgeRuntime
    public let conflictCode: String?
    enum CodingKeys: String, CodingKey {
        case profileCandidateID = "profile_candidate_id", accountCandidateID = "account_candidate_id", label
        case runtimeKind = "runtime_kind", conflictCode = "conflict_code"
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

public struct AgentBridgeConnection: Codable, Sendable {
    public let bindingKey: AgentBridgeBindingKey
    public let personaID: String
    public let runtimeKind: AgentBridgeRuntime
    public let readinessState: String
    public let activeRunID: String?
    public let diagnosticCode: String?
    public let diagnosticMessage: String?
    enum CodingKeys: String, CodingKey {
        case bindingKey = "binding_key", personaID = "persona_id", runtimeKind = "runtime_kind"
        case readinessState = "readiness_state", activeRunID = "active_run_id"
        case diagnosticCode = "diagnostic_code", diagnosticMessage = "diagnostic_message"
    }
}
public struct AgentBridgeMigrationCapture: Codable, Sendable {
    public let migrationID: UUID
    public let legacyServiceScope: String
    public let profileCandidateID: String
    enum CodingKeys: String, CodingKey {
        case migrationID = "migration_id", legacyServiceScope = "legacy_service_scope", profileCandidateID = "profile_candidate_id"
    }
}
public struct AgentBridgeConnections: Codable, Sendable { public let connections: [AgentBridgeConnection] }
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
}

/// The payload comes from native types. Page messages are decoded separately.
public struct AgentBridgeRequest: Encodable, Sendable {
    public static let maximumBytes = 256 * 1024
    public let requestID: UUID
    public let operation: String
    private let payload: [String: AgentBridgeValue]
    public init(requestID: UUID = UUID(), operation: String, payload: [String: AgentBridgeValue]) throws {
        guard ["discover", "prepare", "enroll", "status", "check", "repair", "disconnect", "quiesce", "resume", "stop_background", "migration_prepare"].contains(operation) else {
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
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
