import Foundation

public enum DesktopControlJSONValue: Codable, Equatable, Sendable {
    case object([String: DesktopControlJSONValue])
    case array([DesktopControlJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([DesktopControlJSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: DesktopControlJSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct DesktopControlTarget: Codable, Equatable, Sendable {
    public let installationID: String
    public let workspaceID: String
    public let configID: String
    public let personaID: String
    public let runID: String
    public let generation: Int64
    public let configVersion: Int64?
    public let ownerDisplay: DesktopControlOwnerDisplay?

    public init(installationID: String, workspaceID: String, configID: String, personaID: String, runID: String, generation: Int64,
                configVersion: Int64? = nil, ownerDisplay: DesktopControlOwnerDisplay? = nil) {
        self.installationID = installationID
        self.workspaceID = workspaceID
        self.configID = configID
        self.personaID = personaID
        self.runID = runID
        self.generation = generation
        self.configVersion = configVersion
        self.ownerDisplay = ownerDisplay?.validated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try container.decode(String.self, forKey: .installationID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        configID = try container.decode(String.self, forKey: .configID)
        personaID = try container.decode(String.self, forKey: .personaID)
        runID = try container.decode(String.self, forKey: .runID)
        generation = try container.decode(Int64.self, forKey: .generation)
        configVersion = try container.decodeIfPresent(Int64.self, forKey: .configVersion)
        ownerDisplay = (try? container.decode(DesktopControlOwnerDisplay.self, forKey: .ownerDisplay))?.validated
    }

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case workspaceID = "workspace_id"
        case configID = "config_id"
        case personaID = "persona_id"
        case runID = "run_id"
        case configVersion = "config_version"
        case ownerDisplay = "owner_display"
        case generation
    }
}

public struct DesktopControlOwnerDisplay: Codable, Equatable, Sendable {
    public let personaName: String
    public let workspaceName: String

    public init(personaName: String, workspaceName: String) {
        self.personaName = personaName
        self.workspaceName = workspaceName
    }

    fileprivate var validated: DesktopControlOwnerDisplay? {
        guard isValidName(personaName), isValidName(workspaceName) else { return nil }
        return self
    }

    private func isValidName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.unicodeScalars.count <= 128 &&
            !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format
            }
    }

    enum CodingKeys: String, CodingKey {
        case personaName = "persona_name"
        case workspaceName = "workspace_name"
    }
}

public struct DesktopControlFrame: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: String?
    public let target: DesktopControlTarget?
    public let operation: String?
    public let arguments: DesktopControlJSONValue?
    public let deadlineAt: Date?
    public let result: DesktopControlJSONValue?
    public let errorCode: String?
    public let errorMessage: String?
    public let streamID: String?
    public let sequence: UInt64?
    public let streamChannel: String?
    public let streamData: Data?
    public let lastHeartbeat: Date?
    public let readiness: String?
    public let diagnosticsSupported: Bool?
    public let diagnostics: DesktopControlDiagnostics?

    public init(version: Int = 1, type: String, requestID: String? = nil, target: DesktopControlTarget? = nil,
                operation: String? = nil, arguments: DesktopControlJSONValue? = nil, deadlineAt: Date? = nil,
                result: DesktopControlJSONValue? = nil, errorCode: String? = nil, errorMessage: String? = nil,
                streamID: String? = nil, sequence: UInt64? = nil, streamChannel: String? = nil,
                streamData: Data? = nil, lastHeartbeat: Date? = nil, readiness: String? = nil,
                diagnosticsSupported: Bool? = nil, diagnostics: DesktopControlDiagnostics? = nil) {
        self.version = version
        self.type = type
        self.requestID = requestID
        self.target = target
        self.operation = operation
        self.arguments = arguments
        self.deadlineAt = deadlineAt
        self.result = result
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.streamID = streamID
        self.sequence = sequence
        self.streamChannel = streamChannel
        self.streamData = streamData
        self.lastHeartbeat = lastHeartbeat
        self.readiness = readiness
        self.diagnosticsSupported = diagnosticsSupported
        self.diagnostics = diagnostics
    }

    enum CodingKeys: String, CodingKey {
        case version, type, operation, result, sequence
        case requestID = "request_id"
        case target
        case arguments
        case deadlineAt = "deadline_at"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case streamID = "stream_id"
        case streamChannel = "stream_channel"
        case streamData = "stream_data"
        case lastHeartbeat = "last_heartbeat"
        case readiness
        case diagnosticsSupported = "diagnostics_supported"
        case diagnostics
    }
}

public struct DesktopControlDiagnostics: Codable, Equatable, Sendable {
    public let activeProcesses: Int
    public let openFileHandles: Int
    public let bufferedOutputBytes: Int
    public let outputGapsTotal: UInt64

    public init(activeProcesses: Int, openFileHandles: Int, bufferedOutputBytes: Int, outputGapsTotal: UInt64) {
        self.activeProcesses = activeProcesses
        self.openFileHandles = openFileHandles
        self.bufferedOutputBytes = bufferedOutputBytes
        self.outputGapsTotal = outputGapsTotal
    }

    enum CodingKeys: String, CodingKey {
        case activeProcesses = "active_processes"
        case openFileHandles = "open_file_handles"
        case bufferedOutputBytes = "buffered_output_bytes"
        case outputGapsTotal = "output_gaps_total"
    }
}

public enum DesktopControlFrameCodec {
    // Keep in sync with agentgatewayruntime.DesktopControlFrameLimit.
    public static let maximumFrameBytes = 8 * 1024 * 1024

    public static func decode(_ data: Data) throws -> DesktopControlFrame {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let ordinary = ISO8601DateFormatter()
            ordinary.formatOptions = [.withInternetDateTime]
            if let date = ordinary.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "invalid RFC 3339 timestamp")
        }
        return try decoder.decode(DesktopControlFrame.self, from: data)
    }

    public static func encode(_ frame: DesktopControlFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return try encoder.encode(frame)
    }
}
