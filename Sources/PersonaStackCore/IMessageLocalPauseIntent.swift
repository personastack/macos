import Foundation

/// Restrictive local intention only. These locators never authenticate a
/// request. Recovery must reauthorize the same current human and workspace.
public struct IMessageLocalPauseIntent: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let generation: UUID
    public let installationID: String?
    public let configID: String?
    public let naturalUserID: String?
    public let workspaceID: String?
    public var description: String { "IMessageLocalPauseIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["intention": "<redacted>"]) }
    public init(generation: UUID = UUID(), installationID: String? = nil, configID: String? = nil,
                naturalUserID: String? = nil, workspaceID: String? = nil) throws {
        guard [installationID, configID, naturalUserID, workspaceID].compactMap({ $0 }).allSatisfy(IMessageSavedPageCommand.validToken),
              (naturalUserID == nil) == (workspaceID == nil) else { throw IMessageSetupPageCommandError.invalidRequest }
        self.generation = generation; self.installationID = installationID; self.configID = configID
        self.naturalUserID = naturalUserID; self.workspaceID = workspaceID
    }
    public var preferences: [String: String] {
        var value = ["generation": generation.uuidString.lowercased()]
        value["installation_id"] = installationID; value["config_id"] = configID
        value["natural_user_id"] = naturalUserID; value["workspace_id"] = workspaceID
        return value
    }
    public static func parse(_ value: Any) throws -> Self {
        guard let value = value as? [String: String],
              Set(value.keys).isSubset(of: ["generation", "installation_id", "config_id", "natural_user_id", "workspace_id"]),
              let raw = value["generation"], let generation = UUID(uuidString: raw), generation.uuidString.lowercased() == raw else {
            throw IMessageSetupPageCommandError.invalidRequest
        }
        return try .init(generation: generation, installationID: value["installation_id"], configID: value["config_id"],
            naturalUserID: value["natural_user_id"], workspaceID: value["workspace_id"])
    }
}
