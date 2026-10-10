import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private actor AgentBridgeManagementFixture: AgentBridgeControlTransport, AgentBridgeHostedTransport {
    struct Step: Sendable { let operation: String; let json: String }
    private var expected: [Step]
    private(set) var performed: [String] = []
    init(_ expected: [Step]) { self.expected = expected }
    private func consume(_ operation: String) throws -> String {
        guard !expected.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let step = expected.removeFirst()
        performed.append(operation)
        #expect(operation == step.operation)
        guard operation == step.operation else { throw AgentBridgeFailure.invalidRequest }
        return step.json
    }
    func exchange(_ request: Data) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let payload = try #require(object["payload"] as? [String: Any])
        let binding = try #require(payload["binding_key"] as? [String: String])
        #expect(binding == ["environment_id": "https://my.personastack.ai", "connection_id": "conn-a"])
        if operation == "disconnect" {
            let proof = try #require(payload["revocation_readback"] as? [String: Any])
            #expect(proof["binding_absent"] as? Bool == true)
            #expect(proof["connection_generation"] as? Int == 7)
        }
        let result = try JSONSerialization.jsonObject(with: Data(consume(operation).utf8))
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        let method = request.httpMethod ?? "GET", path = request.url!.path
        #expect(request.url?.host == "my.personastack.ai")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(!request.httpShouldHandleCookies)
        if method == "DELETE" || method == "POST" {
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://my.personastack.ai")
        }
        if method == "POST" {
            #expect(path == "/user/personas/stop")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            #expect(body == ["persona_id": "persona-a"])
        } else {
            #expect(path == "/user/personas/external-runtime")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first(where: { $0.name == "persona_id" })?.value == "persona-a")
            if method == "DELETE" {
                #expect(query.first(where: { $0.name == "expected_connection_id" })?.value == "conn-a")
                #expect(query.first(where: { $0.name == "expected_connection_generation" })?.value == "7")
            }
        }
        return (Data(try consume(method + " " + path).utf8), 200)
    }
}

@MainActor private final class AgentBridgeManagementRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .enabled
    func register() throws { Issue.record("Management must not register a new service") }
    func unregister() async throws { Issue.record("Management must not unregister the service") }
}

@Suite struct AgentBridgeManagementTests {
    private let current = #"{"workspace_id":"ws_11111111111111111111111111111111","persona_id":"persona-a","connection_id":"conn-a","connection_generation":7,"client_kind":"macos_app","run_lane_status":"idle","readiness_status":"wakeable"}"#
    private let absent = #"{"workspace_id":"ws_11111111111111111111111111111111","persona_id":"persona-a"}"#
    private let local = #"{"connections":[{"binding_key":{"environment_id":"https://my.personastack.ai","connection_id":"conn-a"},"persona_id":"persona-a","runtime_kind":"hermes","connection_generation":7,"readiness_state":"mcp_verified"}]}"#

    @MainActor private func manager(_ fixture: AgentBridgeManagementFixture, confirmStop: @escaping @MainActor (String) -> Bool = { _ in false },
                                   confirmRepair: @escaping @MainActor (String) -> Bool = { _ in false }) -> AgentBridgeSetupManager {
        let client = AgentBridgeControlClient(transport: fixture)
        let service = AgentBridgeService(registration: AgentBridgeManagementRegistration(), client: client,
            preferences: UserDefaults(suiteName: "AgentBridgeManagementTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        return AgentBridgeSetupManager(service: service, client: client, hosted: AgentBridgeHostedAuthority(transport: fixture),
            configuration: { _ in .production }, approveEnvironment: { _ in }, prepareBackgroundEnable: {},
            cookieReader: { _, _ in "personastack_session=fixture" }, confirmRuntimeStart: confirmRepair,
            confirmDisconnectStop: confirmStop, waitForSettlement: {}, csrfReader: { _ in "csrf-fixture" })
    }
    @MainActor private func command(_ action: String, manager: AgentBridgeSetupManager, view: WKWebView) async throws -> AgentBridgePageCommand {
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let state = try AgentBridgePageCommand.parse(["version": "1", "action": "state", "scope": ""])
        let response = try await manager.apply(state, view: view)
        return try AgentBridgePageCommand.parse(["version": "1", "action": action, "scope": response["scope"]!,
            "workspace_id": "ws_11111111111111111111111111111111", "persona_id": "persona-a", "connection_id": "conn-a", "connection_generation": 7])
    }

    @Test @MainActor func migrationReadinessUsesActualVerifiedHelperContract() throws {
        let remote = try JSONDecoder().decode(AgentBridgeHostedBinding.self, from: Data(current.utf8))
        let verified = try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(local.utf8))
        let key = AgentBridgeBindingKey(environmentID: "https://my.personastack.ai", connectionID: "conn-a")
        #expect(AgentBridgeSetupManager.migrationReady(remote: remote, local: verified, binding: key))
        let gatewayOnly = try JSONDecoder().decode(AgentBridgeConnections.self, from: Data(local.replacingOccurrences(of: "mcp_verified", with: "ready").utf8))
        #expect(!AgentBridgeSetupManager.migrationReady(remote: remote, local: gatewayOnly, binding: key))
    }

    @Test @MainActor func rejectedMCPCustodyCannotRepairOrStartGateway() async throws {
        for fault in ["reconnect_required", "mcp_token_rejected", "mcp_auth_missing"] {
            let broken = local.replacingOccurrences(of: "\"readiness_state\":\"mcp_verified\"", with: "\"readiness_state\":\"auth_missing\",\"diagnostic_code\":\"\(fault)\"")
            let fixture = AgentBridgeManagementFixture([.init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "check", json: broken)])
            let manager = manager(fixture, confirmRepair: { _ in Issue.record("Credential renewal must not grant gateway restart"); return true })
            let issuingView = WKWebView()
            let actual = try await self.command("repair", manager: manager, view: issuingView)
            await #expect(throws: AgentBridgeFailure.reconnectRequired) { _ = try await manager.apply(actual, view: issuingView) }
            #expect(await fixture.performed == ["GET /user/personas/external-runtime", "check"])
        }
    }

    @Test @MainActor func busyDisconnectCancellationHasNoMutation() async throws {
        let busy = current.replacingOccurrences(of: "\"idle\"", with: "\"running\"")
        let active = local.replacingOccurrences(of: "\"readiness_state\":", with: "\"active_run_id\":\"run-a\",\"readiness_state\":")
        let fixture = AgentBridgeManagementFixture([.init(operation: "GET /user/personas/external-runtime", json: busy), .init(operation: "status", json: active)])
        let manager = manager(fixture), view = WKWebView()
        let command = try await command("disconnect", manager: manager, view: view)
        await #expect(throws: AgentBridgeFailure.busy) { _ = try await manager.apply(command, view: view) }
        #expect(await fixture.performed == ["GET /user/personas/external-runtime", "status"])
    }

    @Test @MainActor func busyDisconnectStopsAndSettlesBothOwnersBeforeScopedRevoke() async throws {
        let busy = current.replacingOccurrences(of: "\"idle\"", with: "\"running\"")
        let active = local.replacingOccurrences(of: "\"readiness_state\":", with: "\"active_run_id\":\"run-a\",\"readiness_state\":")
        let steps: [AgentBridgeManagementFixture.Step] = [
            .init(operation: "GET /user/personas/external-runtime", json: busy), .init(operation: "status", json: active),
            .init(operation: "quiesce", json: #"{"quiesced":true,"active_run_ids":["run-a"]}"#),
            .init(operation: "GET /user/personas/external-runtime", json: busy), .init(operation: "POST /user/personas/stop", json: #"{"accepted":true,"ok":true}"#),
            .init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "status", json: active),
            .init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "status", json: local),
            .init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "status", json: local),
            .init(operation: "DELETE /user/personas/external-runtime", json: #"{"connection_status":"disconnected"}"#),
            .init(operation: "GET /user/personas/external-runtime", json: absent), .init(operation: "status", json: local),
            .init(operation: "disconnect", json: #"{"disconnected":true}"#)
        ]
        let fixture = AgentBridgeManagementFixture(steps), manager = manager(fixture, confirmStop: { _ in true }), view = WKWebView()
        let command = try await command("disconnect", manager: manager, view: view)
        let result = try await manager.apply(command, view: view)
        #expect(result["ok"] as? Bool == true)
        #expect(await fixture.performed == steps.map(\.operation))
    }

    @Test @MainActor func interruptedDisconnectUsesFreshAbsenceBeforeCleanupWithoutSecondRevoke() async throws {
        let steps: [AgentBridgeManagementFixture.Step] = [
            .init(operation: "GET /user/personas/external-runtime", json: absent), .init(operation: "status", json: local),
            .init(operation: "disconnect", json: #"{"disconnected":true}"#)
        ]
        let fixture = AgentBridgeManagementFixture(steps), manager = manager(fixture), view = WKWebView()
        let command = try await command("disconnect", manager: manager, view: view)
        let result = try await manager.apply(command, view: view)
        #expect(result["ok"] as? Bool == true)
        #expect(await fixture.performed == steps.map(\.operation))
    }

    @Test @MainActor func replacedOwnerBeforeStopResumesAdmissionWithoutStopOrRevoke() async throws {
        let busy = current.replacingOccurrences(of: "\"idle\"", with: "\"running\"")
        let steps: [AgentBridgeManagementFixture.Step] = [
            .init(operation: "GET /user/personas/external-runtime", json: busy), .init(operation: "status", json: local),
            .init(operation: "quiesce", json: #"{"quiesced":true,"active_run_ids":[]}"#),
            .init(operation: "GET /user/personas/external-runtime", json: current.replacingOccurrences(of: "conn-a", with: "conn-b")),
            .init(operation: "resume", json: #"{"quiesced":false,"active_run_ids":[]}"#)
        ]
        let fixture = AgentBridgeManagementFixture(steps), manager = manager(fixture, confirmStop: { _ in true }), view = WKWebView()
        let command = try await command("disconnect", manager: manager, view: view)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command, view: view) }
        #expect(await fixture.performed == steps.map(\.operation))
    }
    @Test(arguments: ["workspace", "generation", "runtime", "missing_target", "missing_generation"]) @MainActor func reopenedRepairRejectsForeignRetainedScopeBeforeSelection(_ fault: String) async throws {
        let workspace = fault == "workspace" ? "ws_22222222222222222222222222222222" : "ws_11111111111111111111111111111111"
        let generation = fault == "generation" ? 6 : 7
        let runtime = fault == "runtime" ? "openclaw" : "hermes"
        var pending = "{\"connections\":[{\"binding_key\":{\"environment_id\":\"https://my.personastack.ai\",\"connection_id\":\"conn-a\"},\"persona_id\":\"persona-a\",\"runtime_kind\":\"hermes\",\"readiness_state\":\"target_selection_required\",\"connection_generation\":\(generation),\"prepared_target\":{\"workspace_id\":\"\(workspace)\",\"account_candidate_id\":\"rt_account_a\",\"profile_candidate_id\":\"rt_profile_a\",\"runtime_kind\":\"\(runtime)\"}}]}"
        if fault == "missing_target" { pending = pending.replacingOccurrences(of: "prepared_target", with: "ignored_target") }
        if fault == "missing_generation" { pending = pending.replacingOccurrences(of: "\"connection_generation\":7", with: "\"connection_generation\":null") }
        let fixture = AgentBridgeManagementFixture([.init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "check", json: pending)])
        let manager = manager(fixture)
        let view = WKWebView()
        let command = try await command("repair", manager: manager, view: view)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(command, view: view) }
        #expect(await fixture.performed == ["GET /user/personas/external-runtime", "check"])
    }

}
