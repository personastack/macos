import Foundation

public enum LocalSessionCommand {
    case state(scope: String)
    case select(scope: String, harness: LocalSessionHarness)
    case prepare(scope: String, persona: String, harness: LocalSessionHarness)
    case launch(scope: String, pendingID: UUID, bundle: Data)

    public var scope: String {
        switch self {
        case .state(let scope), .select(let scope, _), .prepare(let scope, _, _), .launch(let scope, _, _): return scope
        }
    }

    public static func parse(_ body: Any) throws -> LocalSessionCommand {
        guard let object = body as? [String: Any], object["version"] as? String == "1",
              let action = object["action"] as? String,
              let scope = object["scope"] as? String, scope.utf8.count <= 512 else {
            throw LocalSessionError.invalidRequest
        }
        func keys(_ extras: Set<String>) -> Bool { Set(object.keys) == Set(["version", "action", "scope"]).union(extras) }
        if action == "state", keys([]) { return .state(scope: scope) }
        guard !scope.isEmpty else { throw LocalSessionError.invalidRequest }
        if action == "launch", keys(["pending_id", "bundle"]),
           let id = object["pending_id"] as? String, let uuid = UUID(uuidString: id),
           let bundle = object["bundle"] as? [String: Any], JSONSerialization.isValidJSONObject(bundle) {
            let data = try JSONSerialization.data(withJSONObject: bundle)
            guard data.count <= LocalSessionBundle.maxWireBytes else { throw LocalSessionError.invalidBundle }
            return .launch(scope: scope, pendingID: uuid, bundle: data)
        }
        guard let raw = object["harness"] as? String, let harness = LocalSessionHarness(rawValue: raw) else {
            throw LocalSessionError.invalidRequest
        }
        if action == "select_harness", keys(["harness"]) { return .select(scope: scope, harness: harness) }
        if action == "prepare", keys(["harness", "persona_id"]),
           let persona = object["persona_id"] as? String, ChatWindowCommand.validPersonaID(persona) {
            return .prepare(scope: scope, persona: persona, harness: harness)
        }
        throw LocalSessionError.invalidRequest
    }
}

/// Scope binds pending presentation work. API authorization remains authoritative.
public struct LocalSessionPendingRequests {
    public struct Request: Sendable {
        public let persona: String
        public let harness: LocalSessionHarness
        public let expires: Date
    }
    public private(set) var scope = ""
    public private(set) var generation = UUID()
    private var requests: [UUID: Request] = [:]
    public init() {}

    public mutating func sync(_ next: String) {
        if next != scope { requests.removeAll(); scope = next; generation = UUID() }
    }

    public mutating func prepare(persona: String, harness: LocalSessionHarness, now: Date = Date()) throws -> UUID {
        guard !scope.isEmpty, ChatWindowCommand.validPersonaID(persona) else { throw LocalSessionError.invalidRequest }
        requests = requests.filter { $0.value.expires > now }
        guard requests.count < 64 else { throw LocalSessionError.invalidRequest }
        let id = UUID()
        requests[id] = Request(persona: persona, harness: harness, expires: now.addingTimeInterval(300))
        return id
    }

    public mutating func consume(_ id: UUID, scope: String, bundle: LocalSessionBundle, now: Date = Date()) throws {
        guard scope == self.scope, let request = requests.removeValue(forKey: id), request.expires > now,
              request.persona == bundle.personaID, request.harness == bundle.harness else {
            throw LocalSessionError.staleRequest
        }
    }
}
