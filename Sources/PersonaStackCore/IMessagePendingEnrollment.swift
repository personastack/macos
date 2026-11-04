import Foundation

public enum IMessagePendingEnrollmentError: Error, Equatable, Sendable {
    case invalidRecord
    case scopeMismatch
    case conflictingJourney
    case expired
    case installationPresent
    case randomnessUnavailable
}

/// Private native custody for an unredeemed machine proof. This record is not
/// session authority and must never be projected into a page or API body.
public struct IMessagePendingEnrollment: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let setupReference: String
    public let naturalUserID: String
    public let workspaceID: String
    public let environmentIdentity: String
    public let expiresAt: String
    public let machineCredential: String

    public var credentialBytes: Data { Self.decodeCanonical32(machineCredential)! }
    public var expiry: Date { Self.parseExpiry(expiresAt)! }
    public var description: String { "IMessagePendingEnrollment(identity: <redacted>, machineCredential: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["identity": "<redacted>", "machineCredential": "<redacted>"]) }

    public init(setupReference: String, naturalUserID: String, workspaceID: String,
                environmentIdentity: String, expiresAt: String, credentialBytes: Data) throws {
        guard credentialBytes.count == 32 else { throw IMessagePendingEnrollmentError.invalidRecord }
        try Self.validateIdentity(setupReference: setupReference, naturalUserID: naturalUserID,
            workspaceID: workspaceID, environmentIdentity: environmentIdentity, expiresAt: expiresAt)
        self.setupReference = setupReference
        self.naturalUserID = naturalUserID
        self.workspaceID = workspaceID
        self.environmentIdentity = environmentIdentity
        self.expiresAt = expiresAt
        self.machineCredential = Self.base64URL(credentialBytes)
    }

    @discardableResult
    public static func validateIdentity(setupReference: String, naturalUserID: String, workspaceID: String,
                                        environmentIdentity: String, expiresAt: String) throws -> Date {
        guard decodeCanonical32(setupReference) != nil,
              identifier(naturalUserID, maximumBytes: 256), identifier(workspaceID, maximumBytes: 256),
              identifier(environmentIdentity, maximumBytes: 6144), let expiry = parseExpiry(expiresAt) else {
            throw IMessagePendingEnrollmentError.invalidRecord
        }
        return expiry
    }

    public func requireEnvironment(_ expected: String) throws {
        guard environmentIdentity == expected else { throw IMessagePendingEnrollmentError.scopeMismatch }
    }

    public func requireJourney(setupReference: String, naturalUserID: String, workspaceID: String,
                               environmentIdentity: String, expiresAt: String) throws {
        try requireEnvironment(environmentIdentity)
        guard self.setupReference == setupReference, self.naturalUserID == naturalUserID,
              self.workspaceID == workspaceID, self.expiresAt == expiresAt else {
            throw IMessagePendingEnrollmentError.conflictingJourney
        }
    }

    public func requireUsable(now: Date) throws {
        guard expiry > now else { throw IMessagePendingEnrollmentError.expired }
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: PendingKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw IMessagePendingEnrollmentError.invalidRecord
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else { throw IMessagePendingEnrollmentError.invalidRecord }
        let proof = try container.decode(String.self, forKey: .machineCredential)
        guard let bytes = Self.decodeCanonical32(proof) else { throw IMessagePendingEnrollmentError.invalidRecord }
        try self.init(setupReference: container.decode(String.self, forKey: .setupReference),
            naturalUserID: container.decode(String.self, forKey: .naturalUserID),
            workspaceID: container.decode(String.self, forKey: .workspaceID),
            environmentIdentity: container.decode(String.self, forKey: .environmentIdentity),
            expiresAt: container.decode(String.self, forKey: .expiresAt), credentialBytes: bytes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(setupReference, forKey: .setupReference)
        try container.encode(naturalUserID, forKey: .naturalUserID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(environmentIdentity, forKey: .environmentIdentity)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(machineCredential, forKey: .machineCredential)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, setupReference = "setup_reference", naturalUserID = "natural_user_id"
        case workspaceID = "workspace_id", environmentIdentity = "environment_identity"
        case expiresAt = "expires_at", machineCredential = "machine_credential"
    }

    private static func identifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeCanonical32(_ value: String) -> Data? {
        guard value.utf8.count == 43 else { return nil }
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32, base64URL(bytes) == value else { return nil }
        return bytes
    }

    private static func parseExpiry(_ value: String) -> Date? {
        guard value.utf8.count <= 40,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#, options: .regularExpression) != nil else { return nil }
        let wholeSeconds = String(value.prefix(19)) + "Z"
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: wholeSeconds), formatter.string(from: date) == wholeSeconds else { return nil }
        guard value.count > 20 else { return date }
        let fraction = "0" + String(value.dropFirst(19).dropLast())
        guard let seconds = TimeInterval(fraction) else { return nil }
        return date.addingTimeInterval(seconds)
    }
}

private struct PendingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
