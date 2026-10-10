import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private actor AgentBridgeFixtureTransport: AgentBridgeControlTransport {
    private var expected: [(String, String)]
    private(set) var operations: [String] = []
    init(_ expected: [(String, String)]) { self.expected = expected }
    func exchange(_ request: Data) throws -> Data {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let operation = try #require(object["operation"] as? String)
        operations.append(operation)
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
        for action in ["quiesce", "resume", "stop_background", "register", "execute"] {
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

    @Test @MainActor func nativeStateIssuesScopeAndForeignDocumentHasNoHelperCalls() async throws {
        let transport = AgentBridgeFixtureTransport([])
        let client = AgentBridgeControlClient(transport: transport)
        let service = AgentBridgeService(registration: AgentBridgeFixtureRegistration(), client: client, requireSignature: {}, clearDisabledPreference: {})
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
        await #expect(throws: AgentBridgeFailure.scopeChanged) { try await manager.apply(discover, view: second) }
        #expect(await transport.operations.isEmpty)
        manager.invalidate(first)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { try await manager.apply(discover, view: first) }
    }

    @Test @MainActor func registeredDocumentDiscoveryPreparationAndEnrollmentAreOrderedAndRedacted() async throws {
        let id = UUID()
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let prepared = "{\"preparation_id\":\"\(id.uuidString)\",\"device_public_key\":\"\(key)\",\"profile_candidate_id\":\"rt_profile_a\",\"expires_at\":\"2026-10-10T12:00:00Z\"}"
        let transport = AgentBridgeFixtureTransport([
            ("status", #"{"connections":[]}"#),
            ("discover", #"{"profiles":[{"profile_candidate_id":"rt_profile_a","account_candidate_id":"rt_account_a","label":"Default profile","runtime_kind":"hermes"}],"discovery_status":"complete"}"#),
            ("status", #"{"connections":[]}"#), ("prepare", prepared),
            ("enroll", #"{"binding_key":{"environment_id":"https://my.personastack.ai","connection_id":"conn-a"},"persona_id":"persona-a"}"#)
        ])
        let client = AgentBridgeControlClient(transport: transport)
        let registration = AgentBridgeFixtureRegistration()
        let service = AgentBridgeService(registration: registration, client: client, requireSignature: {}, clearDisabledPreference: {})
        let manager = AgentBridgeSetupManager(service: service, client: client, configuration: { _ in .production },
            approveEnvironment: { _ in }, prepareBackgroundEnable: {}, cookieReader: { _, _ in "personastack_session=fixture" })
        let view = WKWebView()
        manager.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
        func command(_ action: String, scope: String = "", fields: [String: Any] = [:]) throws -> AgentBridgePageCommand {
            var value = fields; value["version"] = "1"; value["action"] = action; value["scope"] = scope
            return try AgentBridgePageCommand.parse(value)
        }
        let state = try await manager.apply(command("state"), view: view)
        let scope = try #require(state["scope"] as? String)
        let discovered = try await manager.apply(command("discover", scope: scope, fields: ["runtime_kind": "hermes"]), view: view)
        #expect((discovered["profiles"] as? [[String: Any]])?.count == 1)
        let preparedResponse = try await manager.apply(command("prepare", scope: scope, fields: ["runtime_kind": "hermes",
            "persona_id": "persona-a", "workspace_id": "ws_11111111111111111111111111111111", "profile_candidate_id": "rt_profile_a"]), view: view)
        #expect((preparedResponse["desktop_preparation"] as? [String: String])?["device_public_key"] == key)
        let enroll = try command("enroll", scope: scope, fields: ["preparation_id": id.uuidString, "code": "fixture-one-use-proof"])
        let result = try await manager.apply(enroll, view: view)
        #expect(Set(result.keys) == ["ok", "connection_id", "persona_id"])
        await #expect(throws: AgentBridgeFailure.scopeChanged) { try await manager.apply(enroll, view: view) }
        #expect(await transport.operations == ["status", "discover", "status", "prepare", "enroll"])
        #expect(registration.calls == ["register"])
    }
}
