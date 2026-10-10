import Foundation
import CoreFoundation

public struct AgentBridgePageCommand: Sendable {
    public let action: String
    public let scope: String
    public let runtime: AgentBridgeRuntime?
    public let workspaceID: String?
    public let personaID: String?
    public let profileCandidateID: String?
    public let preparationID: UUID?
    public let code: String?
    public let connectionID: String?
    public let connectionGeneration: Int?

    public static func parse(_ body: Any) throws -> Self {
        let schemas: [String: Set<String>] = [
            "state": [], "discover": ["runtime_kind"], "connections": [],
            "migration_prepare": ["runtime_kind", "workspace_id", "persona_id", "profile_candidate_id", "connection_id", "connection_generation"],
            "prepare": ["runtime_kind", "workspace_id", "persona_id", "profile_candidate_id"],
            "enroll": ["preparation_id", "code"],
            "check": ["connection_id", "workspace_id", "persona_id", "connection_generation"],
            "repair": ["connection_id", "workspace_id", "persona_id", "connection_generation"],
            "disconnect": ["connection_id", "workspace_id", "persona_id", "connection_generation"]
        ]
        guard let value = body as? [String: Any], value["version"] as? String == "1",
              let action = value["action"] as? String, let fields = schemas[action],
              Set(value.keys) == fields.union(["version", "action", "scope"]),
              let scope = value["scope"] as? String, scope.utf8.count <= 512,
              action == "state" || !scope.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let runtime = (value["runtime_kind"] as? String).flatMap(AgentBridgeRuntime.init(rawValue:))
        if fields.contains("runtime_kind"), runtime == nil { throw AgentBridgeFailure.invalidRequest }
        let workspace = value["workspace_id"] as? String
        let persona = value["persona_id"] as? String
        if fields.contains("workspace_id") {
            guard let workspace, workspace.range(of: "^ws_[0-9a-f]{32}$", options: .regularExpression) != nil,
                  let persona, ChatWindowCommand.validPersonaID(persona) else { throw AgentBridgeFailure.invalidRequest }
        }
        let profile = value["profile_candidate_id"] as? String
        if fields.contains("profile_candidate_id"), !validOpaqueID(profile) { throw AgentBridgeFailure.invalidRequest }
        let preparation = (value["preparation_id"] as? String).flatMap(UUID.init(uuidString:))
        let code = value["code"] as? String
        if action == "enroll" {
            guard preparation != nil, let code, !code.isEmpty, code.utf8.count <= 512,
                  !code.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.invalidRequest }
        }
        let connection = value["connection_id"] as? String
        let generation = value["connection_generation"] as? Int
        if fields.contains("connection_id") {
            guard validOpaqueID(connection), let generation, generation > 0,
                  let number = value["connection_generation"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(generation) else { throw AgentBridgeFailure.invalidRequest }
        }
        return Self(action: action, scope: scope, runtime: runtime, workspaceID: workspace, personaID: persona,
                    profileCandidateID: profile, preparationID: preparation, code: code,
                    connectionID: connection, connectionGeneration: generation)
    }

    private static func validOpaqueID(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

/// A document can retain public preparations only until its authority changes.
public struct AgentBridgeDocumentScope: Sendable {
    public private(set) var documentID = UUID()
    public private(set) var scope = ""
    private var preparations: [UUID: Date] = [:]
    public init() {}
    public mutating func synchronize(_ scope: String) {
        if self.scope != scope { invalidate(); self.scope = scope }
    }
    public mutating func invalidate() { preparations.removeAll(); documentID = UUID(); scope = "" }
    public mutating func retain(_ preparation: UUID, now: Date = Date()) throws {
        preparations = preparations.filter { $0.value > now }
        guard !scope.isEmpty, preparations.count < 64 else { throw AgentBridgeFailure.scopeChanged }
        preparations[preparation] = now.addingTimeInterval(300)
    }
    public mutating func consume(_ preparation: UUID, scope: String, documentID: UUID, now: Date = Date()) throws {
        guard self.scope == scope, self.documentID == documentID,
              let expires = preparations.removeValue(forKey: preparation), expires > now else { throw AgentBridgeFailure.scopeChanged }
    }
    public func requireCurrent(scope: String, documentID: UUID) throws {
        guard !scope.isEmpty, self.scope == scope, self.documentID == documentID else { throw AgentBridgeFailure.scopeChanged }
    }
}
