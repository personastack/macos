import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private actor AgentBridgeProfileReviewFixture: AgentBridgeControlTransport, AgentBridgeHostedTransport {
    struct Step: Sendable { let operation: String; let json: String; let failure: AgentBridgeFailure? }
    private var steps: [Step]
    private let runtime: String
    private(set) var performed: [String] = []
    private(set) var cleanups = 0
    private var afterLocalRead: (@MainActor @Sendable () -> Void)?
    init(_ steps: [Step], runtime: String) { self.steps = steps; self.runtime = runtime }
    func setAfterLocalRead(_ callback: @escaping @MainActor @Sendable () -> Void) { afterLocalRead = callback }
    private func consume(_ operation: String) throws -> Step {
        guard !steps.isEmpty else { Issue.record("Unexpected profile review call: \(operation)"); throw AgentBridgeFailure.invalidRequest }
        let step = steps.removeFirst()
        #expect(step.operation == operation)
        guard step.operation == operation else { throw AgentBridgeFailure.invalidRequest }
        performed.append(operation)
        return step
    }
    func exchange(_ request: Data) async throws -> Data {
        let envelope = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(envelope["operation"] as? String)
        let payload = try #require(envelope["payload"] as? [String: Any])
        let name = operation == "status" && payload["binding_key"] != nil ? "local-read" : operation
        let step = try consume(name)
        if operation == "prepare" {
            #expect(payload["environment_id"] as? String == "https://my.personastack.ai")
            #expect(payload["workspace_id"] as? String == "ws_11111111111111111111111111111111")
            #expect(payload["persona_id"] as? String == "persona-a")
            #expect(payload["runtime_kind"] as? String == runtime)
            #expect(payload["profile_candidate_id"] as? String == "rt_profile_a")
            let document = try #require(payload["document_id"] as? String)
            #expect(UUID(uuidString: document) != nil)
            #expect(payload["openclaw_agent_candidate_id"] as? String == (runtime == "openclaw" ? "rt_agent_a" : nil))
        }
        if operation == "disconnect" {
            #expect(payload["binding_key"] as? [String: String] == ["environment_id": "https://my.personastack.ai", "connection_id": "old-a"])
            #expect(payload["workspace_id"] as? String == "ws_11111111111111111111111111111111")
            #expect(payload["persona_id"] as? String == "persona-a")
            #expect(payload["connection_generation"] as? Int == 7)
            let proof = try #require(payload["revocation_readback"] as? [String: Any])
            #expect(Set(proof.keys) == ["environment_id", "workspace_id", "persona_id", "connection_id", "connection_generation", "binding_absent"])
            #expect(proof["binding_absent"] as? Bool == true)
            #expect(proof["environment_id"] as? String == "https://my.personastack.ai")
            #expect(proof["workspace_id"] as? String == "ws_11111111111111111111111111111111")
            #expect(proof["persona_id"] as? String == "persona-a")
            #expect(proof["connection_id"] as? String == "old-a")
            #expect(proof["connection_generation"] as? Int == 7)
            if step.failure == nil { cleanups += 1 }
        }
        if name == "local-read", let afterLocalRead { await afterLocalRead() }
        var response: [String: Any] = ["version": 1, "request_id": envelope["request_id"]!]
        if let failure = step.failure { response["error"] = ["code": failure.rawValue, "message": "Profile cleanup needs attention."] }
        else { response["result"] = try JSONSerialization.jsonObject(with: Data(step.json.utf8)) }
        return try JSONSerialization.data(withJSONObject: response)
    }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https" && request.url?.host == "my.personastack.ai")
        #expect(request.url?.path == "/user/personas/external-runtime")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "persona_id", value: "persona-a")])
        return (Data(try consume("hosted-read").json.utf8), 200)
    }
}

@MainActor private final class AgentBridgeProfileReviewRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .enabled
    func register() throws { Issue.record("Existing enabled helper must not register") }
    func unregister() async throws { Issue.record("Profile review must not stop sibling connections") }
}

@Suite struct AgentBridgeProfileReviewTests {
    @Test(arguments: ["hermes", "openclaw"], ["success", "foreign_workspace", "foreign_persona", "foreign_profile", "changed_scope", "stale_generation", "active_run", "active_lane", "edited_config"])
    @MainActor func revokedProfileReviewCleansOnlyExactIdleOwnerThenPreparesSamePersona(_ runtime: String, _ fault: String) async throws {
        let profile = "{\"profile_candidate_id\":\"rt_profile_a\",\"account_candidate_id\":\"rt_account_a\",\"label\":\"Work\",\"runtime_kind\":\"\(runtime)\",\"openclaw_agents\":[{\"agent_candidate_id\":\"rt_agent_a\",\"label\":\"Research\"}]}"
        let occupied = String(profile.dropLast()) + ",\"conflict_code\":\"profile_in_use\"}"
        let discovery = "{\"profiles\":[\(occupied)],\"discovery_status\":\"complete\"}"
        var remote = #"{"workspace_id":"ws_11111111111111111111111111111111","persona_id":"persona-a","run_lane_status":"idle"}"#
        if fault == "foreign_workspace" { remote = remote.replacingOccurrences(of: "ws_11111111111111111111111111111111", with: "ws_22222222222222222222222222222222") }
        if fault == "active_lane" { remote = remote.replacingOccurrences(of: "idle", with: "busy") }
        var local = "{\"connections\":[{\"binding_key\":{\"environment_id\":\"https://my.personastack.ai\",\"connection_id\":\"old-a\"},\"persona_id\":\"persona-a\",\"runtime_kind\":\"\(runtime)\",\"connection_generation\":7,\"readiness_state\":\"unavailable\",\"prepared_target\":{\"workspace_id\":\"ws_11111111111111111111111111111111\",\"account_candidate_id\":\"rt_account_a\",\"profile_candidate_id\":\"rt_profile_a\",\"runtime_kind\":\"\(runtime)\"}}]}"
        if fault == "foreign_persona" { local = local.replacingOccurrences(of: "persona-a", with: "persona-b") }
        if fault == "foreign_profile" { local = local.replacingOccurrences(of: "rt_profile_a", with: "rt_profile_b") }
        if fault == "active_run" { local = local.replacingOccurrences(of: "\"readiness_state\":\"unavailable\"", with: "\"readiness_state\":\"unavailable\",\"active_run_id\":\"run-a\"") }
        let preparation = UUID()
        var steps: [AgentBridgeProfileReviewFixture.Step] = [
            .init(operation: "status", json: #"{"connections":[]}"#, failure: nil), .init(operation: "discover", json: discovery, failure: nil),
            .init(operation: "status", json: #"{"connections":[]}"#, failure: nil),
            .init(operation: "prepare", json: #"{"existing_binding_key":{"environment_id":"https://my.personastack.ai","connection_id":"old-a"}}"#, failure: nil),
            .init(operation: "hosted-read", json: remote, failure: nil)
        ]
        if fault != "foreign_workspace" { steps.append(.init(operation: "local-read", json: local, failure: nil)) }
        if ["success", "stale_generation", "edited_config"].contains(fault) {
            steps.append(.init(operation: "disconnect", json: #"{"disconnected":true}"#, failure: fault == "stale_generation" ? .scopeChanged : fault == "edited_config" ? .cleanupRequired : nil))
        }
        if fault == "success" {
            steps += [.init(operation: "status", json: #"{"connections":[]}"#, failure: nil),
                      .init(operation: "discover", json: "{\"profiles\":[\(profile)],\"discovery_status\":\"complete\"}", failure: nil),
                      .init(operation: "status", json: #"{"connections":[]}"#, failure: nil),
                      .init(operation: "prepare", json: "{\"preparation_id\":\"\(preparation.uuidString)\",\"device_public_key\":\"\(Data(repeating: 1, count: 32).base64EncodedString())\",\"profile_candidate_id\":\"rt_profile_a\",\"expires_at\":\"2026-10-12T12:00:00Z\"}", failure: nil)]
        }
        let fixture = AgentBridgeProfileReviewFixture(steps, runtime: runtime)
        let client = AgentBridgeControlClient(transport: fixture)
        let service = AgentBridgeService(registration: AgentBridgeProfileReviewRegistration(), client: client,
            preferences: UserDefaults(suiteName: "AgentBridgeProfileReviewTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        let manager = AgentBridgeSetupManager(service: service, client: client, hosted: AgentBridgeHostedAuthority(transport: fixture),
            configuration: { _ in .production }, approveEnvironment: { _ in }, prepareBackgroundEnable: {}, cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView(); manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let state = try await manager.apply(AgentBridgePageCommand.parse(["version": "2", "action": "state", "scope": ""]), view: view)
        let scope = try #require(state["scope"] as? String)
        let discover = try AgentBridgePageCommand.parse(["version": "2", "action": "discover", "scope": scope, "runtime_kind": runtime])
        let review = try AgentBridgePageCommand.parse(["version": "2", "action": "prepare", "scope": scope, "runtime_kind": runtime,
            "workspace_id": "ws_11111111111111111111111111111111", "persona_id": "persona-a", "profile_candidate_id": "rt_profile_a"])
        let initial = try await manager.apply(discover, view: view)
        #expect((initial["profiles"] as? [[String: Any]])?.first?["available"] as? Bool == false)
        if fault == "changed_scope" { await fixture.setAfterLocalRead { manager.invalidateSession() } }
        if fault == "success" {
            let released = try await manager.apply(review, view: view)
            #expect(Set(released.keys) == ["ok"])
            let rediscovered = try await manager.apply(discover, view: view)
            #expect((rediscovered["profiles"] as? [[String: Any]])?.first?["available"] as? Bool == true)
            let prepared = try await manager.apply(review, view: view)
            #expect((prepared["desktop_preparation"] as? [String: String])?["preparation_id"] == preparation.uuidString.lowercased())
        } else {
            let failure: AgentBridgeFailure = fault == "edited_config" ? .cleanupRequired : ["active_run", "active_lane"].contains(fault) ? .busy : .scopeChanged
            await #expect(throws: failure) { _ = try await manager.apply(review, view: view) }
        }
        #expect(await fixture.cleanups == (fault == "success" ? 1 : 0))
        #expect(await fixture.performed == steps.map(\.operation))
    }
}
