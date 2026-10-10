import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private actor AgentBridgeFixtureTransport: AgentBridgeControlTransport {
    private var expected: [(String, String)]
    private let selectedTarget: AgentBridgeTargetFixture?
    private let expectedAgentChoice: String?
    private(set) var operations: [String] = []
    init(_ expected: [(String, String)], selectedTarget: AgentBridgeTargetFixture? = nil, agentChoice: String? = nil) { self.expected = expected; self.selectedTarget = selectedTarget; self.expectedAgentChoice = agentChoice }
    func exchange(_ request: Data) async throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let operation = try #require(object["operation"] as? String)
        operations.append(operation)
        if operation == "prepare", let expectedAgentChoice {
            let payload = try #require(object["payload"] as? [String: Any])
            #expect(payload["openclaw_agent_candidate_id"] as? String == expectedAgentChoice)
        }
        if operation == "check", let selectedTarget, expected.first?.1.contains("target_selection_required") != true { #expect(await selectedTarget.isSelected()) }
        guard !expected.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let next = expected.removeFirst()
        #expect(operation == next.0)
        guard operation == next.0 else { throw AgentBridgeFailure.invalidRequest }
        let result = try JSONSerialization.jsonObject(with: Data(next.1.utf8))
        return try JSONSerialization.data(withJSONObject: ["version": 1, "request_id": object["request_id"]!, "result": result])
    }
}

@MainActor
private final class AgentBridgeFixtureRegistration: AgentBridgeServiceRegistration {
    var status: SMAppService.Status = .notRegistered
    var registrationResult: SMAppService.Status = .enabled
    private(set) var calls: [String] = []
    func register() throws { calls.append("register"); status = registrationResult }
    func unregister() async throws { calls.append("unregister"); status = .notRegistered }
}

@MainActor
private final class AgentBridgeFixtureLifecycle: AgentBridgeUpdateLifecycle {
    var hasRegisteredService = true
    var busy = true
    var pendingMigration = false
    func hasPendingMigrationCapture() async throws -> Bool { pendingMigration }
    var log: [String] = []
    func quiesce() async throws -> AgentBridgeAdmission {
        log.append("quiesce")
        let json = busy ? #"{"quiesced":true,"active_run_ids":["run-a"]}"# : #"{"quiesced":true,"active_run_ids":[]}"#
        return try JSONDecoder().decode(AgentBridgeAdmission.self, from: Data(json.utf8))
    }
    func resume() async throws { log.append("resume") }
    func retireForReplacement() async throws { log.append("retire"); hasRegisteredService = false }
    func restoreAfterReplacement() async throws { log.append("restore-readback"); hasRegisteredService = true }
}

@Suite struct AgentBridgeTests {
    @Test func finitePageBoundaryRejectsNativeOnlyCommandsAndRawAuthority() throws {
        let valid: [String: Any] = ["version": "1", "action": "prepare", "scope": "native-document",
            "runtime_kind": "hermes", "workspace_id": "ws_11111111111111111111111111111111",
            "persona_id": "persona-a", "profile_candidate_id": "rt_profile_a"]
        _ = try AgentBridgePageCommand.parse(valid)
        for extra in ["gateway_url", "token", "path", "command", "document_id", "restart_confirmed"] {
            var input = valid; input[extra] = "untrusted"
            #expect(throws: AgentBridgeFailure.invalidRequest) { try AgentBridgePageCommand.parse(input) }
        }
        for action in ["quiesce", "resume", "stop_background", "register", "execute", "migration_help", "migration_repair", "migration_cancel"] {
            #expect(throws: AgentBridgeFailure.invalidRequest) {
                try AgentBridgePageCommand.parse(["version": "1", "action": action, "scope": "native-document"])
            }
        }
        var path = valid; path["profile_candidate_id"] = "/Users/example/.hermes"
        #expect(throws: AgentBridgeFailure.invalidRequest) { try AgentBridgePageCommand.parse(path) }
    }

    @Test func longSocketPathUsesOnlyFixedNativeUserPrivateFallback() {
        let normal = URL(fileURLWithPath: "/Users/test/Library/Application Support/PersonaStack/AgentBridge")
        #expect(AgentBridgeNativePaths.controlDirectory(for: normal) == normal)
        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 100) + "/Library/Application Support/PersonaStack/AgentBridge")
        let fallback = AgentBridgeNativePaths.controlDirectory(for: long)
        #expect(fallback.path.hasPrefix("/private/tmp/personastack-agent-bridge-"))
        #expect(fallback.appendingPathComponent("control.sock").path.utf8.count <= 103)
    }

    @Test func responseEnvelopeRejectsForeignIDAndAmbiguousResults() throws {
        let id = UUID()
        let json: [String: Any] = ["version": 1, "request_id": id.uuidString,
                                   "result": ["connections": []]]
        _ = try AgentBridgeResponse.decode(AgentBridgeConnections.self,
            data: JSONSerialization.data(withJSONObject: json), requestID: id)
        #expect(throws: AgentBridgeFailure.invalidRequest) {
            try AgentBridgeResponse.decode(AgentBridgeConnections.self, data: JSONSerialization.data(withJSONObject: json), requestID: UUID())
        }
        var ambiguous = json; ambiguous["error"] = ["code": "busy", "message": "busy"]
        #expect(throws: AgentBridgeFailure.invalidRequest) {
            try AgentBridgeResponse.decode(AgentBridgeConnections.self, data: JSONSerialization.data(withJSONObject: ambiguous), requestID: id)
        }
        var extra = json; extra["token"] = "fixture-secret"
        #expect(throws: AgentBridgeFailure.invalidRequest) {
            try AgentBridgeResponse.decode(AgentBridgeConnections.self, data: JSONSerialization.data(withJSONObject: extra), requestID: id)
        }
    }

    @Test func documentPreparationExpiresAndCannotCrossDocumentOrReplay() throws {
        var scope = AgentBridgeDocumentScope()
        scope.synchronize("native-document")
        let document = scope.documentID
        let id = UUID(), now = Date(timeIntervalSince1970: 123)
        try scope.retain(id, now: now)
        #expect(throws: AgentBridgeFailure.scopeChanged) {
            try scope.consume(id, scope: scope.scope, documentID: UUID(), now: now)
        }
        try scope.consume(id, scope: scope.scope, documentID: document, now: now)
        #expect(throws: AgentBridgeFailure.scopeChanged) {
            try scope.consume(id, scope: scope.scope, documentID: document, now: now)
        }
        let expired = UUID(); try scope.retain(expired, now: now)
        #expect(throws: AgentBridgeFailure.scopeChanged) {
            try scope.consume(expired, scope: scope.scope, documentID: document, now: now.addingTimeInterval(300))
        }
        scope.invalidate()
        #expect(scope.documentID != document)
    }

    @Test @MainActor func serviceRegistersBeforeControlReadbackAndApprovalCannotEnroll() async throws {
        let registration = AgentBridgeFixtureRegistration()
        registration.registrationResult = .requiresApproval
        let transport = AgentBridgeFixtureTransport([])
        let preferences = UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!
        let service = AgentBridgeService(registration: registration, client: AgentBridgeControlClient(transport: transport),
                                         preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        await #expect(throws: AgentBridgeFailure.backgroundApprovalRequired) { try await service.ensureEnabled() }
        #expect(registration.calls == ["register"])
        #expect(await transport.operations.isEmpty)
        registration.status = .notRegistered; registration.registrationResult = .enabled
        let readyTransport = AgentBridgeFixtureTransport([("status", #"{"connections":[]}"#)])
        let ready = AgentBridgeService(registration: registration, client: AgentBridgeControlClient(transport: readyTransport),
                                      preferences: preferences, requireSignature: {}, clearDisabledPreference: {})
        try await ready.ensureEnabled()
        #expect(await readyTransport.operations == ["status"])
        #expect(registration.status == .enabled)
        // Normal Quit has no service callback and cannot unregister this owner.
        #expect(registration.calls == ["register", "register"])
    }

    @Test @MainActor func busyUpdateDoesNotCancelOrReplaceAndCancellationResumes() async throws {
        let lifecycle = AgentBridgeFixtureLifecycle()
        let preferences = UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: preferences)
        await #expect(throws: AgentBridgeFailure.busy) { try await handoff.prepareReplacement() }
        #expect(lifecycle.log == ["quiesce"])
        try await handoff.cancelReplacement()
        #expect(lifecycle.log == ["quiesce", "resume"])
        // Explicit API Stop is outside this owner. Its authoritative idle
        // readback permits the next quiesce, rather than invoking Pause here.
        lifecycle.busy = false
        try await handoff.prepareReplacement()
        #expect(lifecycle.log == ["quiesce", "resume", "quiesce", "retire"])
        #expect(preferences.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        try await handoff.restoreAtLaunch()
        #expect(lifecycle.log.suffix(2) == ["restore-readback", "resume"])
        #expect(!preferences.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
    }

    @Test @MainActor func retainedMigrationBlocksReplacementBeforeQuiesceOrUnregister() async throws {
        let lifecycle = AgentBridgeFixtureLifecycle()
        lifecycle.busy = false; lifecycle.pendingMigration = true
        let preferences = UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!
        let handoff = AgentBridgeUpdateHandoff(service: lifecycle, preferences: preferences, pendingNativeMigration: { false })
        await #expect(throws: AgentBridgeFailure.migrationIncomplete) { try await handoff.prepareReplacement() }
        #expect(lifecycle.log.isEmpty)
        #expect(!preferences.bool(forKey: AgentBridgeUpdateHandoff.restoreKey))
        lifecycle.pendingMigration = false
        let nativeCutover = AgentBridgeUpdateHandoff(service: lifecycle, preferences: preferences, pendingNativeMigration: { true })
        await #expect(throws: AgentBridgeFailure.migrationIncomplete) { try await nativeCutover.prepareReplacement() }
        #expect(lifecycle.log.isEmpty)
    }

    @Test @MainActor func nativeStateIssuesScopeAndForeignDocumentHasNoHelperCalls() async throws {
        let transport = AgentBridgeFixtureTransport([])
        let client = AgentBridgeControlClient(transport: transport)
        let service = AgentBridgeService(registration: AgentBridgeFixtureRegistration(), client: client, preferences: UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        let manager = AgentBridgeSetupManager(service: service, client: client, configuration: { _ in .production },
            approveEnvironment: { _ in }, prepareBackgroundEnable: {}, cookieReader: { _, _ in "personastack_session=fixture" })
        let first = WKWebView(), second = WKWebView()
        manager.register(first, appURL: DesktopEnvironmentConfiguration.production.appURL)
        manager.register(second, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let state = try AgentBridgePageCommand.parse(["version": "1", "action": "state", "scope": ""])
        let response = try await manager.apply(state, view: first)
        let scope = try #require(response["scope"] as? String)
        #expect(UUID(uuidString: scope) != nil)
        let discover = try AgentBridgePageCommand.parse(["version": "1", "action": "discover", "scope": scope, "runtime_kind": "hermes"])
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(discover, view: second) }
        #expect(await transport.operations.isEmpty)
        manager.invalidate(first)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(discover, view: first) }
    }

    @Test(arguments: [false, true], ["hermes", "openclaw"]) @MainActor func registeredDocumentDiscoveryPreparationAndEnrollmentAreOrderedAndRedacted(_ staleInventory: Bool, _ runtimeKind: String) async throws {
        try await enrollmentWorkflow(staleInventory: staleInventory, runtimeKind: runtimeKind, reopen: false)
    }
    @Test(arguments: ["hermes", "openclaw"]) @MainActor func interruptedEnrollmentReopensAndRepairsWithoutNewPairing(_ runtimeKind: String) async throws {
        try await enrollmentWorkflow(staleInventory: true, runtimeKind: runtimeKind, reopen: true)
    }
    @MainActor private func enrollmentWorkflow(staleInventory: Bool, runtimeKind: String, reopen: Bool) async throws {
        let id = UUID()
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let prepared = "{\"preparation_id\":\"\(id.uuidString)\",\"device_public_key\":\"\(key)\",\"profile_candidate_id\":\"rt_profile_a\",\"expires_at\":\"2026-10-10T12:00:00Z\"}"
        let targetFixture = AgentBridgeTargetFixture()
        await targetFixture.configure(pending: true, stale: staleInventory, runtime: runtimeKind)
        let discoveryJSON = "{\"profiles\":[{\"profile_candidate_id\":\"rt_profile_a\",\"account_candidate_id\":\"rt_account_a\",\"label\":\"Default profile\",\"runtime_kind\":\"\(runtimeKind)\",\"openclaw_agents\":[{\"agent_candidate_id\":\"rt_agent_a\",\"label\":\"Research\"},{\"agent_candidate_id\":\"rt_agent_b\",\"label\":\"Writer\"}]}],\"discovery_status\":\"complete\"}"
        let readinessJSON = "{\"connections\":[{\"binding_key\":{\"environment_id\":\"https://my.personastack.ai\",\"connection_id\":\"conn-a\"},\"persona_id\":\"persona-a\",\"runtime_kind\":\"\(runtimeKind)\",\"readiness_state\":\"mcp_verified\",\"connection_generation\":7,\"prepared_target\":{\"workspace_id\":\"ws_11111111111111111111111111111111\",\"account_candidate_id\":\"rt_account_a\",\"profile_candidate_id\":\"rt_profile_a\",\"runtime_kind\":\"\(runtimeKind)\"}}]}"
        var expected: [(String, String)] = [
            ("status", #"{"connections":[]}"#),
            ("discover", discoveryJSON),
            ("status", #"{"connections":[]}"#), ("prepare", prepared),
            ("enroll", #"{"binding_key":{"environment_id":"https://my.personastack.ai","connection_id":"conn-a"},"persona_id":"persona-a"}"#)
        ]
        if reopen {
            let pending = "{\"connections\":[{\"binding_key\":{\"environment_id\":\"https://my.personastack.ai\",\"connection_id\":\"conn-a\"},\"persona_id\":\"persona-a\",\"runtime_kind\":\"\(runtimeKind)\",\"readiness_state\":\"target_selection_required\",\"connection_generation\":7,\"prepared_target\":{\"workspace_id\":\"ws_11111111111111111111111111111111\",\"account_candidate_id\":\"rt_account_a\",\"profile_candidate_id\":\"rt_profile_a\",\"runtime_kind\":\"\(runtimeKind)\"}}]}"
            expected.append(("check", pending))
        }
        expected.append(contentsOf: [("check", readinessJSON), ("check", readinessJSON)])
        if reopen { expected.append(("status", readinessJSON)) }
        let transport = AgentBridgeFixtureTransport(expected, selectedTarget: targetFixture, agentChoice: runtimeKind == "openclaw" ? "rt_agent_b" : nil)
        let client = AgentBridgeControlClient(transport: transport)
        let registration = AgentBridgeFixtureRegistration()
        let service = AgentBridgeService(registration: registration, client: client, preferences: UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        let manager = AgentBridgeSetupManager(service: service, client: client, hosted: AgentBridgeHostedAuthority(transport: targetFixture), configuration: { _ in .production },
            approveEnvironment: { _ in }, prepareBackgroundEnable: {}, cookieReader: { _, _ in "personastack_session=fixture" },
            chooseOpenClawAgent: { _, _ in "rt_agent_b" }, waitForSettlement: {}, csrfReader: { _ in "csrf-fixture" })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        func command(_ action: String, scope: String = "", fields: [String: Any] = [:]) throws -> AgentBridgePageCommand {
            var value = fields; value["version"] = "1"; value["action"] = action; value["scope"] = scope
            return try AgentBridgePageCommand.parse(value)
        }
        let state = try await manager.apply(command("state"), view: view)
        let scope = try #require(state["scope"] as? String)
        let discovered = try await manager.apply(command("discover", scope: scope, fields: ["runtime_kind": runtimeKind]), view: view)
        #expect((discovered["profiles"] as? [[String: Any]])?.count == 1)
        #expect((discovered["profiles"] as? [[String: Any]])?.first?["openclaw_agents"] == nil)
        let preparedResponse = try await manager.apply(command("prepare", scope: scope, fields: ["runtime_kind": runtimeKind,
            "persona_id": "persona-a", "workspace_id": "ws_11111111111111111111111111111111", "profile_candidate_id": "rt_profile_a"]), view: view)
        #expect((preparedResponse["desktop_preparation"] as? [String: String])?["device_public_key"] == key)
        let enroll = try command("enroll", scope: scope, fields: ["preparation_id": id.uuidString, "code": "fixture-one-use-proof"])
        if staleInventory {
            await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(enroll, view: view) }
            #expect(await transport.operations.last == "enroll")
        }
        let result: [String: Any]
        if reopen {
            manager.invalidate(view)
            manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
            let fresh = try await manager.apply(command("state"), view: view)
            let repair = try command("repair", scope: try #require(fresh["scope"] as? String), fields: [
                "workspace_id": "ws_11111111111111111111111111111111", "persona_id": "persona-a", "connection_id": "conn-a", "connection_generation": 7])
            result = try await manager.apply(repair, view: view)
            #expect((result["connections"] as? [[String: Any]])?.first?["prepared_target"] == nil)
        } else { result = try await manager.apply(enroll, view: view) }
        #expect(Set(result.keys) == (reopen ? ["ok", "connection_id", "persona_id", "connections"] : ["ok", "connection_id", "persona_id"]))
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await manager.apply(enroll, view: view) }
        #expect(await transport.operations == (reopen ? ["status", "discover", "status", "prepare", "enroll", "check", "check", "check", "status"] : ["status", "discover", "status", "prepare", "enroll", "check", "check"]))
        #expect(await targetFixture.saves == (staleInventory ? [7, 8] : [7]))
        #expect(registration.calls == ["register"])
    }
    @Test(arguments: [false, true]) @MainActor func nativeAgentPickerCancelOrDocumentChangeNeverPrepares(_ changedDocument: Bool) async throws {
        let transport = AgentBridgeFixtureTransport([
            ("status", #"{"connections":[]}"#),
            ("discover", #"{"profiles":[{"profile_candidate_id":"rt_profile_a","account_candidate_id":"rt_account_a","label":"Work","runtime_kind":"openclaw","openclaw_agents":[{"agent_candidate_id":"rt_a","label":"Research"},{"agent_candidate_id":"rt_b","label":"Writer"}]}],"discovery_status":"complete"}"#),
            ("status", #"{"connections":[]}"#)
        ])
        let client = AgentBridgeControlClient(transport: transport)
        let service = AgentBridgeService(registration: AgentBridgeFixtureRegistration(), client: client,
            preferences: UserDefaults(suiteName: "AgentBridgeTests." + UUID().uuidString)!, requireSignature: {}, clearDisabledPreference: {})
        let view = WKWebView()
        var manager: AgentBridgeSetupManager!
        manager = AgentBridgeSetupManager(service: service, client: client, configuration: { _ in .production },
            approveEnvironment: { _ in }, prepareBackgroundEnable: {}, cookieReader: { _, _ in "personastack_session=fixture" },
            chooseOpenClawAgent: { _, _ in if changedDocument { manager.invalidate(view); return "rt_b" }; return nil })
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        let state = try await manager.apply(AgentBridgePageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: view)
        let scope = try #require(state["scope"] as? String)
        _ = try await manager.apply(AgentBridgePageCommand.parse(["version": "1", "action": "discover", "scope": scope, "runtime_kind": "openclaw"]), view: view)
        let command = try AgentBridgePageCommand.parse(["version": "1", "action": "prepare", "scope": scope, "runtime_kind": "openclaw",
            "persona_id": "persona-a", "workspace_id": "ws_11111111111111111111111111111111", "profile_candidate_id": "rt_profile_a"])
        let expected: AgentBridgeFailure = changedDocument ? .scopeChanged : .runtimeConflict
        await #expect(throws: expected) { _ = try await manager.apply(command, view: view) }
        #expect(await transport.operations == ["status", "discover", "status"])
    }

}
