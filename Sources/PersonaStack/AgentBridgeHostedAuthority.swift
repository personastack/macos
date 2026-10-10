import Foundation
import PersonaStackCore

struct AgentBridgeHostedBinding: Decodable, Sendable {
    let workspaceID: String
    let personaID: String
    let connectionID: String?
    let connectionGeneration: Int?
    let clientKind: String?
    let readinessStatus: String?
    let runLaneStatus: String?
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", personaID = "persona_id", connectionID = "connection_id"
        case connectionGeneration = "connection_generation", clientKind = "client_kind"
        case readinessStatus = "readiness_status", runLaneStatus = "run_lane_status"
    }
    func require(workspace: String, persona: String, connection: String, generation: Int, clientKind expectedKind: String = "macos_app") throws {
        guard workspaceID == workspace, personaID == persona, connectionID == connection,
              connectionGeneration == generation, clientKind == expectedKind else { throw AgentBridgeFailure.scopeChanged }
    }
}

protocol AgentBridgeHostedTransport: Sendable {
    func request(_ request: URLRequest) async throws -> (Data, Int)
}
struct AgentBridgeURLTransport: AgentBridgeHostedTransport {
    private let session = DesktopControlNetworkSession.makeWithoutRedirects()
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= AgentBridgeRequest.maximumBytes else {
            throw AgentBridgeFailure.invalidRequest
        }
        return (data, response.statusCode)
    }
}

struct AgentBridgeHostedAuthority: Sendable {
    let transport: any AgentBridgeHostedTransport
    init(transport: any AgentBridgeHostedTransport = AgentBridgeURLTransport()) { self.transport = transport }

    func read(configuration: DesktopEnvironmentConfiguration, cookies: String, persona: String) async throws -> AgentBridgeHostedBinding {
        let request = try request(configuration: configuration, cookies: cookies, method: "GET", persona: persona)
        let (data, status) = try await transport.request(request)
        guard status == 200 else { throw AgentBridgeFailure.credentialUnavailable }
        return try JSONDecoder().decode(AgentBridgeHostedBinding.self, from: data)
    }

    func connections(configuration: DesktopEnvironmentConfiguration, cookies: String) async throws -> [AgentBridgeHostedBinding] {
        var request = URLRequest(url: configuration.appURL.appendingPathComponent("user/personas/external-runtime/connections"))
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let (data, status) = try await transport.request(request)
        guard status == 200 else { throw AgentBridgeFailure.credentialUnavailable }
        struct Response: Decodable { let connections: [AgentBridgeHostedBinding] }
        return try JSONDecoder().decode(Response.self, from: data).connections
    }

    /// Readback is authoritative. A token.revoked notification cannot enter this path.
    func revoke(configuration: DesktopEnvironmentConfiguration, cookies: String, workspace: String,
                persona: String, connection: String, generation: Int, csrfToken: String, clientKind: String = "macos_app", requireIdle: Bool = false,
                validateScope: @MainActor @Sendable () async throws -> Void = {}) async throws {
        guard !csrfToken.isEmpty, csrfToken.utf8.count <= 512, !csrfToken.contains(where: { $0.isWhitespace }) else {
            throw AgentBridgeFailure.invalidRequest
        }
        let before = try await read(configuration: configuration, cookies: cookies, persona: persona)
        guard before.workspaceID == workspace, before.personaID == persona else { throw AgentBridgeFailure.scopeChanged }
        if before.connectionID == nil || before.connectionID == "" { return }
        try before.require(workspace: workspace, persona: persona, connection: connection, generation: generation, clientKind: clientKind)
        if requireIdle && before.runLaneStatus != "idle" { throw AgentBridgeFailure.busy }
        try await validateScope()
        let deletion = try request(configuration: configuration, cookies: cookies, method: "DELETE", persona: persona,
                                   connection: connection, generation: generation)
        var mutation = deletion
        mutation.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
        let (_, status) = try await transport.request(mutation)
        guard status == 200 || status == 204 else { throw AgentBridgeFailure.cleanupRequired }
        let after = try await read(configuration: configuration, cookies: cookies, persona: persona)
        try await validateScope()
        guard after.workspaceID == workspace, after.personaID == persona,
              after.connectionID == nil || after.connectionID == "" else { throw AgentBridgeFailure.cleanupRequired }
    }

    private func request(configuration: DesktopEnvironmentConfiguration, cookies: String, method: String,
                         persona: String, connection: String? = nil, generation: Int? = nil) throws -> URLRequest {
        guard ChatWindowCommand.validPersonaID(persona), !cookies.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        var parts = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        parts.path = "/user/personas/external-runtime"
        parts.queryItems = [URLQueryItem(name: "persona_id", value: persona)]
        if let connection, let generation {
            parts.queryItems?.append(URLQueryItem(name: "expected_connection_id", value: connection))
            parts.queryItems?.append(URLQueryItem(name: "expected_connection_generation", value: String(generation)))
        }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(configuration.appOrigin, forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
