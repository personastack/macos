import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private actor AgentBridgeMigrationHTTPFixture: AgentBridgeHostedTransport {
    struct Step: Sendable { let path: String; let method: String; let body: String?; let status: Int; let response: String }
    private var steps: [Step]
    private(set) var paths: [String] = []
    init(_ steps: [Step]) { self.steps = steps }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        guard !steps.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let expected = steps.removeFirst()
        #expect(request.url?.scheme == "https" && request.url?.host == "my.personastack.ai")
        #expect(request.url?.path == expected.path)
        #expect(request.httpMethod == expected.method)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://my.personastack.ai")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        if expected.method == "POST" {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == expected.body)
            #expect(request.url?.query == nil)
        } else {
            #expect(request.httpBody == nil)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query == [URLQueryItem(name: "persona_id", value: "persona-a")])
        }
        paths.append(expected.path)
        return (Data(expected.response.utf8), expected.status)
    }
}

@Suite struct AgentBridgeMigrationAuthorityTests {
    @Test func existingSettingsPauseStopAndTestContractsUseExactAuthority() async throws {
        let fixture = AgentBridgeMigrationHTTPFixture([
            .init(path: "/user/mobile/personas/settings", method: "GET", body: nil, status: 200,
                  response: #"{"persona":{"id":"persona-a","user_paused":false,"user_pause_version":7},"external_runtime":{"run_lane_status":"busy"}}"#),
            .init(path: "/user/personas/stop", method: "POST", body: #"{"persona_id":"persona-a"}"#, status: 200, response: #"{"ok":true,"accepted":true}"#),
            .init(path: "/user/personas/pause/save", method: "POST", body: #"{"expected_user_pause_version":7,"paused":true,"persona_id":"persona-a"}"#, status: 200,
                  response: #"{"ok":true,"paused":true,"effective_paused":true,"user_pause_version":8}"#),
            .init(path: "/user/personas/external-runtime/test-dispatch", method: "POST", body: #"{"persona_id":"persona-a"}"#, status: 200, response: #"{"accepted":true}"#)
        ])
        let authority = AgentBridgeMigrationAuthority(transport: fixture)
        let state = try await authority.state(configuration: .production, cookies: "personastack_session=fixture", persona: "persona-a")
        #expect(!state.userPaused && state.pauseVersion == 7 && !state.laneIdle)
        try await authority.stop(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture", persona: "persona-a")
        #expect(try await authority.pause(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture", persona: "persona-a", paused: true, expectedVersion: 7) == 8)
        try await authority.test(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture", persona: "persona-a")
        #expect(await fixture.paths.count == 4)
    }

    @Test func missingPauseOrLaneAuthorityAndWrongPersonaFailClosed() async {
        for json in [
            #"{"persona":{"id":"persona-a","user_pause_version":7},"external_runtime":{"run_lane_status":"idle"}}"#,
            #"{"persona":{"id":"persona-a","user_paused":false,"user_pause_version":7},"external_runtime":{}}"#,
            #"{"persona":{"id":"other","user_paused":false,"user_pause_version":7},"external_runtime":{"run_lane_status":"idle"}}"#
        ] {
            let fixture = AgentBridgeMigrationHTTPFixture([.init(path: "/user/mobile/personas/settings", method: "GET", body: nil, status: 200, response: json)])
            await #expect(throws: (any Error).self) {
                _ = try await AgentBridgeMigrationAuthority(transport: fixture).state(configuration: .production, cookies: "personastack_session=fixture", persona: "persona-a")
            }
        }
    }

    @Test func invalidCSRFHasZeroTransportCalls() async {
        let fixture = AgentBridgeMigrationHTTPFixture([])
        await #expect(throws: AgentBridgeFailure.invalidRequest) {
            _ = try await AgentBridgeMigrationAuthority(transport: fixture).pause(configuration: .production, cookies: "personastack_session=fixture", csrf: "", persona: "persona-a", paused: true, expectedVersion: 7)
        }
        #expect(await fixture.paths.isEmpty)
    }
}
