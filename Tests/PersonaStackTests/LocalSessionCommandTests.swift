import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionCommandTests {
    @Test func localSessionFiniteBridgeMessages() throws {
        _ = try LocalSessionCommand.parse(["version": "1", "action": "state", "scope": ""])
        _ = try LocalSessionCommand.parse(["version": "1", "action": "select_harness", "scope": "account/workspace", "harness": "claude_code"])
        let valid = ["version": "1", "action": "prepare", "scope": "account/workspace", "harness": "codex", "persona_id": "persona-a", "workspace_id": "ws_11111111111111111111111111111111"]
        _ = try LocalSessionCommand.parse(valid)
        let fixtureURL = try #require(Bundle.module.url(forResource: "local-session", withExtension: "json"))
        let bundle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let configure: [String: Any] = ["version": "1", "action": "configure", "scope": "account/workspace",
                                        "pending_id": UUID().uuidString, "bundle": bundle]
        if case .configure(_, _, _) = try LocalSessionCommand.parse(configure) {} else {
            Issue.record("Expected a valid API-produced bundle in the configure command")
        }
        var legacyLaunch = configure
        legacyLaunch["action"] = "launch"
        #expect(throws: LocalSessionError.invalidRequest) { try LocalSessionCommand.parse(legacyLaunch) }
        var extraField = configure
        extraField["unexpected"] = true
        #expect(throws: LocalSessionError.invalidRequest) { try LocalSessionCommand.parse(extraField) }
        for (key, value) in [("version", "2"), ("scope", ""), ("harness", "unknown"), ("persona_id", "../bad"), ("command", "anything")] {
            var invalid = valid
            invalid[key] = value
            #expect(throws: LocalSessionError.invalidRequest) { try LocalSessionCommand.parse(invalid) }
        }
        #expect(throws: LocalSessionError.invalidRequest) { try LocalSessionCommand.parse(["version": "1", "action": "launch", "scope": "account/workspace", "pending_id": UUID().uuidString]) }
    }

    @Test func nativeProfileCommandsRejectPathsAndMalformedSelectors() throws {
        let id = UUID()
        let valid = ["version": "1", "action": "select_profile", "scope": "scope", "harness": "codex", "profile_id": id.uuidString]
        if case .selectProfile(let scope, let harness, let selected) = try LocalSessionCommand.parse(valid) {
            #expect(scope == "scope" && harness == .codex && selected == id)
        } else { Issue.record("Expected a native profile selection") }
        _ = try LocalSessionCommand.parse(["version": "1", "action": "profiles", "scope": "scope", "harness": "claude_code"])
        for (field, value) in [("profile_id", "../../profile"), ("profile_id", "/Users/test/.ai/epic/codex"), ("harness", "unsupported"), ("path", "/tmp/profile"), ("executable", "/tmp/cli"), ("scope", "")] {
            var request = valid
            request[field] = value
            #expect(throws: LocalSessionError.invalidRequest) { try LocalSessionCommand.parse(request) }
        }
    }

    @Test func localSessionPendingIndependentSingleUseAndScopeFenced() throws {
        let fixture = LocalSessionBundleTests()
        let bundle = try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: fixture.fixture()), appURL: fixture.appURL, now: fixture.now)
        var pending = LocalSessionPendingRequests()
        pending.sync("account/workspace")
        let first = try pending.prepare(persona: bundle.personaID, harness: .codex, workspace: bundle.workspaceID, profile: "/fixture/profile", now: fixture.now)
        let second = try pending.prepare(persona: bundle.personaID, harness: .codex, workspace: bundle.workspaceID, profile: "/fixture/profile", now: fixture.now)
        #expect(first != second)
        func bound(_ id: UUID) throws -> LocalSessionBundle {
            var value = fixture.fixture()
            value["connection_id"] = id.uuidString.lowercased()
            value["mcp_url"] = "https://mcp.personastack.ai/v1/mcp?connection_id=" + id.uuidString.lowercased() + "&persona_id=persona-a&workspace_id=" + bundle.workspaceID
            return try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: value), appURL: fixture.appURL, now: fixture.now)
        }
        try pending.consume(first, scope: pending.scope, bundle: bound(first), now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(first, scope: pending.scope, bundle: bundle, now: fixture.now) }
        try pending.consume(second, scope: pending.scope, bundle: bound(second), now: fixture.now)
        let old = try pending.prepare(persona: bundle.personaID, harness: .codex, workspace: bundle.workspaceID, profile: "/fixture/profile", now: fixture.now)
        let generation = pending.generation
        pending.sync("another-account/workspace")
        pending.sync("account/workspace")
        #expect(pending.generation != generation)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(old, scope: "account/workspace", bundle: bundle, now: fixture.now) }
        let expired = try pending.prepare(persona: bundle.personaID, harness: .codex, workspace: bundle.workspaceID, profile: "/fixture/profile", now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(expired, scope: pending.scope, bundle: bundle, now: fixture.now.addingTimeInterval(300)) }
        let wrongHarness = try pending.prepare(persona: bundle.personaID, harness: .claudeCode, workspace: bundle.workspaceID, profile: "/fixture/profile", now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(wrongHarness, scope: pending.scope, bundle: bundle, now: fixture.now) }
    }
}
