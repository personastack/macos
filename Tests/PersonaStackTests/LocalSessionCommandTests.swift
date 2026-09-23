import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionCommandTests {
    @Test func localSessionFiniteBridgeMessages() throws {
        _ = try LocalSessionCommand.parse(["version": "1", "action": "state", "scope": ""])
        _ = try LocalSessionCommand.parse(["version": "1", "action": "select_harness", "scope": "account/workspace", "harness": "claude_code"])
        let valid = ["version": "1", "action": "prepare", "scope": "account/workspace", "harness": "codex", "persona_id": "persona-a"]
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

    @Test func localSessionPendingIndependentSingleUseAndScopeFenced() throws {
        let fixture = LocalSessionBundleTests()
        let bundle = try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: fixture.fixture()), appURL: fixture.appURL, now: fixture.now)
        var pending = LocalSessionPendingRequests()
        pending.sync("account/workspace")
        let first = try pending.prepare(persona: bundle.personaID, harness: .codex, now: fixture.now)
        let second = try pending.prepare(persona: bundle.personaID, harness: .codex, now: fixture.now)
        #expect(first != second)
        try pending.consume(first, scope: pending.scope, bundle: bundle, now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(first, scope: pending.scope, bundle: bundle, now: fixture.now) }
        try pending.consume(second, scope: pending.scope, bundle: bundle, now: fixture.now)
        let old = try pending.prepare(persona: bundle.personaID, harness: .codex, now: fixture.now)
        let generation = pending.generation
        pending.sync("another-account/workspace")
        pending.sync("account/workspace")
        #expect(pending.generation != generation)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(old, scope: "account/workspace", bundle: bundle, now: fixture.now) }
        let expired = try pending.prepare(persona: bundle.personaID, harness: .codex, now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(expired, scope: pending.scope, bundle: bundle, now: fixture.now.addingTimeInterval(300)) }
        let wrongHarness = try pending.prepare(persona: bundle.personaID, harness: .claudeCode, now: fixture.now)
        #expect(throws: LocalSessionError.staleRequest) { try pending.consume(wrongHarness, scope: pending.scope, bundle: bundle, now: fixture.now) }
    }
}
