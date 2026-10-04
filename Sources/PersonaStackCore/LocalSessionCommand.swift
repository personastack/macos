import Foundation

public enum LocalSessionCommand {
    case state(scope: String)
    case select(scope: String, harness: LocalSessionHarness)
    case profiles(scope: String, harness: LocalSessionHarness)
    case selectProfile(scope: String, harness: LocalSessionHarness, profileID: UUID)
    case prepare(scope: String, persona: String, harness: LocalSessionHarness, workspace: String)
    case connections(scope: String, harness: LocalSessionHarness)
    case remove(scope: String, harness: LocalSessionHarness, connectionID: UUID)
    case check(scope: String, harness: LocalSessionHarness, connectionID: UUID)
    case reconnect(scope: String, harness: LocalSessionHarness, connectionID: UUID)
    case configure(scope: String, pendingID: UUID, bundle: Data)

    public var scope: String {
        switch self {
        case .state(let scope), .select(let scope, _), .profiles(let scope, _), .selectProfile(let scope, _, _), .prepare(let scope, _, _, _), .configure(let scope, _, _), .connections(let scope, _), .remove(let scope, _, _), .check(let scope, _, _), .reconnect(let scope, _, _): return scope
        }
    }

    public static func parse(_ body: Any) throws -> LocalSessionCommand {
        let schemas: [String: Set<String>] = [
            "state": [], "select_harness": ["harness"], "connections": ["harness"], "profiles": ["harness"],
            "select_profile": ["harness", "profile_id"],
            "prepare": ["harness", "persona_id", "workspace_id"],
            "configure": ["pending_id", "bundle"],
            "remove": ["harness", "connection_id"], "check": ["harness", "connection_id"], "reconnect": ["harness", "connection_id"]
        ]
        guard let object = body as? [String: Any], object["version"] as? String == "1",
              let action = object["action"] as? String, let extras = schemas[action],
              Set(object.keys) == extras.union(["version", "action", "scope"]),
              let scope = object["scope"] as? String, scope.utf8.count <= 512 else { throw LocalSessionError.invalidRequest }
        if action == "state" { return .state(scope: scope) }
        guard !scope.isEmpty else { throw LocalSessionError.invalidRequest }
        if action == "configure" { return try configuration(object, scope: scope) }
        guard let raw = object["harness"] as? String, let harness = LocalSessionHarness(rawValue: raw) else { throw LocalSessionError.invalidRequest }
        switch action {
        case "select_harness": return .select(scope: scope, harness: harness)
        case "profiles": return .profiles(scope: scope, harness: harness)
        case "select_profile":
            guard let value = object["profile_id"] as? String, let id = UUID(uuidString: value) else { throw LocalSessionError.invalidRequest }
            return .selectProfile(scope: scope, harness: harness, profileID: id)
        case "connections": return .connections(scope: scope, harness: harness)
        case "prepare": return try preparation(object, scope: scope, harness: harness)
        default: return try connectionAction(object, action: action, scope: scope, harness: harness)
        }
    }

    private static func configuration(_ object: [String: Any], scope: String) throws -> LocalSessionCommand {
        guard let id = object["pending_id"] as? String, let uuid = UUID(uuidString: id),
              let bundle = object["bundle"] as? [String: Any], JSONSerialization.isValidJSONObject(bundle) else { throw LocalSessionError.invalidRequest }
        let data = try JSONSerialization.data(withJSONObject: bundle)
        guard data.count <= LocalSessionBundle.maxWireBytes else { throw LocalSessionError.invalidBundle }
        return .configure(scope: scope, pendingID: uuid, bundle: data)
    }

    private static func preparation(_ object: [String: Any], scope: String, harness: LocalSessionHarness) throws -> LocalSessionCommand {
        guard let workspace = object["workspace_id"] as? String, workspace.range(of: "^ws_[0-9a-f]{32}$", options: .regularExpression) != nil,
              let persona = object["persona_id"] as? String, ChatWindowCommand.validPersonaID(persona) else { throw LocalSessionError.invalidRequest }
        return .prepare(scope: scope, persona: persona, harness: harness, workspace: workspace)
    }

    private static func connectionAction(_ object: [String: Any], action: String, scope: String, harness: LocalSessionHarness) throws -> LocalSessionCommand {
        guard let value = object["connection_id"] as? String, let id = UUID(uuidString: value) else { throw LocalSessionError.invalidRequest }
        switch action {
        case "remove": return .remove(scope: scope, harness: harness, connectionID: id)
        case "check": return .check(scope: scope, harness: harness, connectionID: id)
        case "reconnect": return .reconnect(scope: scope, harness: harness, connectionID: id)
        default: throw LocalSessionError.invalidRequest
        }
    }

}

/// Scope binds pending presentation work. API authorization remains authoritative.
public struct LocalSessionPendingRequests {
    public struct Request: Sendable {
        public let persona: String
        public let harness: LocalSessionHarness
        public let workspace: String
        public let profile: String
        public let expires: Date
    }
    public private(set) var scope = ""
    public private(set) var generation = UUID()
    private var requests: [UUID: Request] = [:]
    public init() {}

    public mutating func sync(_ next: String) {
        if next != scope { requests.removeAll(); scope = next; generation = UUID() }
    }

    public mutating func invalidate() { requests.removeAll(); generation = UUID() }

    public mutating func prepare(persona: String, harness: LocalSessionHarness, workspace: String, profile: String, id suppliedID: UUID? = nil, now: Date = Date()) throws -> UUID {
        guard !scope.isEmpty, ChatWindowCommand.validPersonaID(persona), workspace.range(of: "^ws_[0-9a-f]{32}$", options: .regularExpression) != nil, profile.hasPrefix("/") else { throw LocalSessionError.invalidRequest }
        requests = requests.filter { $0.value.expires > now }
        guard requests.count < 64 else { throw LocalSessionError.invalidRequest }
        let id = suppliedID ?? UUID()
        requests[id] = Request(persona: persona, harness: harness, workspace: workspace, profile: profile, expires: now.addingTimeInterval(300))
        return id
    }

    @discardableResult
    public mutating func consume(_ id: UUID, scope: String, bundle: LocalSessionBundle, now: Date = Date()) throws -> Request {
        guard scope == self.scope, let request = requests.removeValue(forKey: id), request.expires > now,
              request.persona == bundle.personaID, request.harness == bundle.harness, request.workspace == bundle.workspaceID, UUID(uuidString: bundle.connectionID) == id else {
            throw LocalSessionError.staleRequest
        }
        return request
    }
}
