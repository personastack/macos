import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private actor AgentBridgeAuthorityFixture: AgentBridgeHostedTransport {
    struct Expected: Sendable {
        let method: String
        let status: Int
        let json: String
    }
    private var expected: [Expected]
    private(set) var methods: [String] = []
    init(_ expected: [Expected]) { self.expected = expected }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        guard !expected.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let next = expected.removeFirst()
        methods.append(request.httpMethod ?? "")
        #expect(request.httpMethod == next.method)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "my.personastack.ai")
        #expect(request.url?.path == "/user/personas/external-runtime")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(request.httpShouldHandleCookies == false)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "persona_id" })?.value == "persona-a")
        if next.method == "DELETE" {
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://my.personastack.ai")
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(query.first(where: { $0.name == "expected_connection_id" })?.value == "conn-a")
            #expect(query.first(where: { $0.name == "expected_connection_generation" })?.value == "7")
        }
        return (Data(next.json.utf8), next.status)
    }
}

@Suite struct AgentBridgeHostedAuthorityTests {
    private let workspace = "ws_11111111111111111111111111111111"
    private let current = #"{"workspace_id":"ws_11111111111111111111111111111111","persona_id":"persona-a","connection_id":"conn-a","connection_generation":7,"client_kind":"macos_app"}"#
    private let absent = #"{"workspace_id":"ws_11111111111111111111111111111111","persona_id":"persona-a"}"#

    @Test func exactRevokeHeadersAndReadbackAuthorizeCleanup() async throws {
        let fixture = AgentBridgeAuthorityFixture([
            .init(method: "GET", status: 200, json: current),
            .init(method: "DELETE", status: 200, json: #"{"connection_status":"disconnected"}"#),
            .init(method: "GET", status: 200, json: absent)
        ])
        let authority = AgentBridgeHostedAuthority(transport: fixture)
        try await authority.revoke(configuration: .production, cookies: "personastack_session=fixture", workspace: workspace,
                                   persona: "persona-a", connection: "conn-a", generation: 7, csrfToken: "csrf-fixture")
        #expect(await fixture.methods == ["GET", "DELETE", "GET"])
    }

    @Test func wrongGenerationOrWorkspaceNeverDeletes() async throws {
        for (scope, generation) in [(workspace, 8), ("ws_22222222222222222222222222222222", 7)] {
            let fixture = AgentBridgeAuthorityFixture([.init(method: "GET", status: 200, json: current)])
            let authority = AgentBridgeHostedAuthority(transport: fixture)
            await #expect(throws: AgentBridgeFailure.scopeChanged) {
                try await authority.revoke(configuration: .production, cookies: "personastack_session=fixture", workspace: scope,
                                           persona: "persona-a", connection: "conn-a", generation: generation, csrfToken: "csrf-fixture")
            }
            #expect(await fixture.methods == ["GET"])
        }
    }

    @Test func changedDocumentOrCookieFenceNeverDeletes() async throws {
        let fixture = AgentBridgeAuthorityFixture([.init(method: "GET", status: 200, json: current)])
        let authority = AgentBridgeHostedAuthority(transport: fixture)
        await #expect(throws: AgentBridgeFailure.scopeChanged) {
            try await authority.revoke(configuration: .production, cookies: "personastack_session=fixture", workspace: workspace,
                                       persona: "persona-a", connection: "conn-a", generation: 7, csrfToken: "csrf-fixture",
                                       validateScope: { throw AgentBridgeFailure.scopeChanged })
        }
        #expect(await fixture.methods == ["GET"])
    }

    @Test func failedDeleteAndReplacementReadbackNeverAuthorizeCleanup() async throws {
        let failed = AgentBridgeAuthorityFixture([
            .init(method: "GET", status: 200, json: current), .init(method: "DELETE", status: 503, json: "{}")])
        await #expect(throws: AgentBridgeFailure.cleanupRequired) {
            try await AgentBridgeHostedAuthority(transport: failed).revoke(configuration: .production,
                cookies: "personastack_session=fixture", workspace: workspace, persona: "persona-a", connection: "conn-a", generation: 7, csrfToken: "csrf-fixture")
        }
        #expect(await failed.methods == ["GET", "DELETE"])
        let replacement = AgentBridgeAuthorityFixture([
            .init(method: "GET", status: 200, json: current), .init(method: "DELETE", status: 204, json: ""),
            .init(method: "GET", status: 200, json: current.replacingOccurrences(of: "conn-a", with: "conn-b"))])
        await #expect(throws: AgentBridgeFailure.cleanupRequired) {
            try await AgentBridgeHostedAuthority(transport: replacement).revoke(configuration: .production,
                cookies: "personastack_session=fixture", workspace: workspace, persona: "persona-a", connection: "conn-a", generation: 7, csrfToken: "csrf-fixture")
        }
    }

    @Test func missedNotificationOrOfflineRetryUsesFreshAbsenceReadback() async throws {
        let fixture = AgentBridgeAuthorityFixture([.init(method: "GET", status: 200, json: absent)])
        try await AgentBridgeHostedAuthority(transport: fixture).revoke(configuration: .production,
            cookies: "personastack_session=fixture", workspace: workspace, persona: "persona-a", connection: "conn-a", generation: 7, csrfToken: "csrf-fixture")
        #expect(await fixture.methods == ["GET"])
    }
}
