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
    private var afterCheck: (@MainActor @Sendable () -> Void)?
    func setAfterCheck(_ action: @escaping @MainActor @Sendable () -> Void) { afterCheck = action }
    private let expectedAppsConfirmation: Bool?
    private let expectedHostConfirmation: Bool?
    init(_ expected: [Step], appsConfirmation: Bool? = nil, hostConfirmation: Bool? = nil) {
        self.expected = expected; expectedAppsConfirmation = appsConfirmation; expectedHostConfirmation = hostConfirmation
    }
    private func consume(_ operation: String) throws -> String {
        guard !expected.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let step = expected.removeFirst()
        performed.append(operation)
        #expect(operation == step.operation)
        guard operation == step.operation else { throw AgentBridgeFailure.invalidRequest }
        return step.json
    }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let operation = try #require(object["operation"] as? String)
        let payload = try #require(object["payload"] as? [String: Any])
        let binding = try #require(payload["binding_key"] as? [String: String])
        #expect(binding == ["environment_id": "https://my.personastack.ai", "connection_id": "conn-a"])
        if operation == "repair" {
            #expect(Set(payload.keys) == ["binding_key", "connection_generation", "target_selection_revision", "restart_confirmed", "openclaw_apps_confirmed", "hermes_host_confirmed"])
            #expect(payload["connection_generation"] as? Int == 7)
            #expect(payload["target_selection_revision"] as? Int == 9)
            #expect(payload["restart_confirmed"] as? Bool == true)
            #expect(payload["openclaw_apps_confirmed"] as? Bool == (expectedAppsConfirmation ?? false))
            #expect(payload["hermes_host_confirmed"] as? Bool == (expectedHostConfirmation ?? false))
        }
        if operation == "disconnect" {
            let proof = try #require(payload["revocation_readback"] as? [String: Any])
            #expect(proof["binding_absent"] as? Bool == true)
            #expect(proof["connection_generation"] as? Int == 7)
        }
        let result = try JSONSerialization.jsonObject(with: Data(consume(operation).utf8))
        if operation == "check", let afterCheck { await afterCheck() }
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
                                   confirmRepair: @escaping @MainActor (String) -> Bool = { _ in false },
                                   confirmApps: @escaping @MainActor (String) -> Bool = { _ in false },
                                   confirmHost: @escaping @MainActor (String) -> Bool = { _ in false },
                                   showScopeHelp: @escaping @MainActor () -> Void = {},
                                   cookieReader: @escaping @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = { _, _ in "personastack_session=fixture" }) -> AgentBridgeSetupManager {
        let client = AgentBridgeControlClient(transport: fixture)
        let service = AgentBridgeService(registration: AgentBridgeManagementRegistration(), client: client,
            preferences: UserDefaults(suiteName: "AgentBridgeManagementTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        return AgentBridgeSetupManager(service: service, client: client, hosted: AgentBridgeHostedAuthority(transport: fixture),
            configuration: { _ in .production }, approveEnvironment: { _ in }, prepareBackgroundEnable: {},
            cookieReader: cookieReader, confirmRuntimeStart: { persona, _ in confirmRepair(persona) }, confirmOpenClawApps: confirmApps, confirmHermesHost: confirmHost, showProfileScopeHelp: showScopeHelp, showHermesHostHelp: showScopeHelp,
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

    @Test(arguments: ["hermes", "openclaw"], ["exact", "foreign_persona", "foreign_binding", "stale_generation", "changed_document", "changed_cookie", "foreign_message"]) @MainActor func unverifiedGatewayScopeHelpRequiresCurrentExactOwner(_ runtimeKind: String, _ fault: String) async throws {
        let message = runtimeKind == "hermes" ? AgentBridgeSetupManager.hermesHostHelpMessage : AgentBridgeSetupManager.profileScopeHelpMessage
        var unavailable = local.replacingOccurrences(of: "hermes", with: runtimeKind)
            .replacingOccurrences(of: "\"readiness_state\":\"mcp_verified\"", with: "\"readiness_state\":\"unavailable\",\"diagnostic_code\":\"runtime_conflict\",\"diagnostic_message\":\"" + message + "\"")
        if fault == "foreign_persona" { unavailable = unavailable.replacingOccurrences(of: "persona-a", with: "persona-b") }
        if fault == "foreign_binding" { unavailable = unavailable.replacingOccurrences(of: "conn-a", with: "conn-b") }
        if fault == "stale_generation" { unavailable = unavailable.replacingOccurrences(of: "\"connection_generation\":7", with: "\"connection_generation\":6") }
        if fault == "foreign_message" { unavailable = unavailable.replacingOccurrences(of: message, with: "Untrusted profile diagnostic") }
        let fixture = AgentBridgeManagementFixture([.init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "check", json: unavailable)])
        var helpCount = 0, confirmCount = 0
        var cookie = "personastack_session=fixture"
        let manager = manager(fixture, confirmRepair: { _ in confirmCount += 1; return false }, showScopeHelp: { helpCount += 1 }, cookieReader: { _, _ in cookie })
        let view = WKWebView()
        let command = try await command("repair", manager: manager, view: view)
        if fault == "changed_document" { await fixture.setAfterCheck { manager.invalidate(view) } }
        if fault == "changed_cookie" { await fixture.setAfterCheck { cookie = "personastack_session=changed" } }
        let expected: AgentBridgeFailure = fault == "exact" ? .runtimeConflict : .scopeChanged
        await #expect(throws: expected) { _ = try await manager.apply(command, view: view) }
        #expect(helpCount == (fault == "exact" ? 1 : 0))
        #expect(confirmCount == 0)
        #expect(await fixture.performed == ["GET /user/personas/external-runtime", "check"])
    }

    @Test(arguments: ["hermes", "openclaw"], ["allow", "already_enabled", "decline_feature", "decline_repair", "changed_document", "changed_cookie", "changed_generation", "changed_account", "changed_profile", "changed_revision", "changed_inventory", "changed_runtime", "changed_after_restart"]) @MainActor func nativeFeatureAndRuntimeRepairRequireSeparateCurrentTargetAuthority(_ runtimeKind: String, _ outcome: String) async throws {
        let target = #", "target_inventory":{"inventory_generation":8,"accounts":[{"candidate_id":"rt_account_a","profiles":[{"candidate_id":"rt_profile_a","runtime_kind":"openclaw"}]}]},"target_selection":{"account_candidate_id":"rt_account_a","profile_candidate_id":"rt_profile_a","runtime_kind":"openclaw","selection_revision":9,"validated_generation":8,"state":"target_selected"}"#
        let owner = (String(current.dropLast()) + target + "}").replacingOccurrences(of: "openclaw", with: runtimeKind)
        let retained = #", "prepared_target":{"workspace_id":"ws_11111111111111111111111111111111","account_candidate_id":"rt_account_a","profile_candidate_id":"rt_profile_a","runtime_kind":"openclaw"}"#
        let verified = local.replacingOccurrences(of: "hermes", with: runtimeKind).replacingOccurrences(of: "}]}" , with: retained.replacingOccurrences(of: "openclaw", with: runtimeKind) + "}]}")
        let featureDiagnostic = runtimeKind == "hermes" ? "hermes_host_consent_required" : "mcp_apps_disabled"
        let diagnostic = outcome == "already_enabled" ? "mcp_unverified" : featureDiagnostic
        let needsRepair = verified.replacingOccurrences(of: "\"readiness_state\":\"mcp_verified\"", with: "\"readiness_state\":\"unavailable\",\"diagnostic_code\":\"" + diagnostic + "\"")
        var changed = owner
        switch outcome {
        case "changed_generation", "changed_after_restart": changed = owner.replacingOccurrences(of: "\"connection_generation\":7", with: "\"connection_generation\":8")
        case "changed_account": changed = owner.replacingOccurrences(of: "rt_account_a", with: "rt_account_b")
        case "changed_profile": changed = owner.replacingOccurrences(of: "rt_profile_a", with: "rt_profile_b")
        case "changed_revision": changed = owner.replacingOccurrences(of: "\"selection_revision\":9", with: "\"selection_revision\":10")
        case "changed_inventory": changed = owner.replacingOccurrences(of: "\"inventory_generation\":8", with: "\"inventory_generation\":9")
        case "changed_runtime": changed = owner.replacingOccurrences(of: runtimeKind, with: runtimeKind == "hermes" ? "openclaw" : "hermes")
        default: break
        }
        var steps: [AgentBridgeManagementFixture.Step] = [
            .init(operation: "GET /user/personas/external-runtime", json: owner), .init(operation: "check", json: needsRepair),
            .init(operation: "GET /user/personas/external-runtime", json: owner)
        ]
        let featureDialogInvalidates = ["changed_document", "changed_cookie"].contains(outcome)
        let featureReadbackDenies = ["changed_generation", "changed_account", "changed_profile", "changed_revision", "changed_inventory", "changed_runtime"].contains(outcome)
        if outcome != "decline_feature" && !featureDialogInvalidates && outcome != "already_enabled" {
            steps.append(.init(operation: "GET /user/personas/external-runtime", json: featureReadbackDenies ? changed : owner))
        }
        let startReached = outcome == "allow" || outcome == "already_enabled" || outcome == "decline_repair" || outcome == "changed_after_restart"
        if startReached && outcome != "decline_repair" {
            steps.append(.init(operation: "GET /user/personas/external-runtime", json: changed))
        }
        let succeeds = outcome == "allow" || outcome == "already_enabled"
        if succeeds { steps.append(.init(operation: "repair", json: verified)) }
        let fixture = AgentBridgeManagementFixture(steps, appsConfirmation: runtimeKind == "openclaw" && outcome == "allow", hostConfirmation: runtimeKind == "hermes" && outcome == "allow")
        var dialogs: [String] = [], cookie = "personastack_session=fixture"
        let view = WKWebView()
        var manager: AgentBridgeSetupManager!
        let approveFeature: @MainActor (String) -> Bool = { _ in
            dialogs.append(runtimeKind == "hermes" ? "host" : "apps")
            if outcome == "changed_document" { manager.invalidate(view) }
            if outcome == "changed_cookie" { cookie = "personastack_session=changed" }
            return outcome != "decline_feature"
        }
        manager = self.manager(fixture, confirmRepair: { _ in dialogs.append("restart"); return outcome != "decline_repair" },
            confirmApps: runtimeKind == "openclaw" ? approveFeature : { _ in Issue.record("Hermes cannot grant OpenClaw Apps"); return false },
            confirmHost: runtimeKind == "hermes" ? approveFeature : { _ in Issue.record("OpenClaw cannot grant Hermes host startup"); return false },
            cookieReader: { _, _ in cookie })
        let command = try await command("repair", manager: manager, view: view)
        if succeeds {
            let result = try await manager.apply(command, view: view)
            #expect(result["openclaw_apps_confirmed"] == nil)
            #expect(result["hermes_host_confirmed"] == nil)
            #expect((result["connections"] as? [[String: Any]])?.first?["prepared_target"] == nil)
        } else {
            let failure: AgentBridgeFailure = outcome == "decline_feature" ? (runtimeKind == "hermes" ? .hermesHostConsentRequired : .runtimeConflict) : outcome == "decline_repair" ? .runtimeConflict : .scopeChanged
            await #expect(throws: failure) { _ = try await manager.apply(command, view: view) }
        }
        let feature = runtimeKind == "hermes" ? "host" : "apps"
        #expect(dialogs == (outcome == "already_enabled" ? ["restart"] : startReached ? [feature, "restart"] : [feature]))
        #expect(await fixture.performed == steps.map(\.operation))
    }

    @Test @MainActor func hermesCheckOnlyReportsHostConsentRequirementWithoutStartingIt() async throws {
        let stopped = local.replacingOccurrences(of: "\"readiness_state\":\"mcp_verified\"", with: "\"readiness_state\":\"unavailable\",\"diagnostic_code\":\"hermes_host_consent_required\"")
        let steps: [AgentBridgeManagementFixture.Step] = [.init(operation: "GET /user/personas/external-runtime", json: current), .init(operation: "check", json: stopped)]
        let fixture = AgentBridgeManagementFixture(steps)
        let manager = manager(fixture, confirmRepair: { _ in Issue.record("Check cannot approve tools repair"); return true },
            confirmHost: { _ in Issue.record("Check cannot approve host startup"); return true })
        let view = WKWebView()
        let command = try await command("check", manager: manager, view: view)
        let response = try await manager.apply(command, view: view)
        let connection = try #require((response["connections"] as? [[String: Any]])?.first)
        #expect(connection["diagnostic_code"] as? String == "hermes_host_consent_required")
        #expect(connection["diagnostic_message"] == nil)
        #expect(connection["hermes_host_confirmed"] == nil)
        #expect(await fixture.performed == steps.map(\.operation))
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
