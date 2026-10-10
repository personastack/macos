import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor
private final class AgentBridgeMigrationFixture {
    var events: [String] = []
    var paused = false
    var version = 7
    var idle = true
    var fail: String?
    var consent = true
    var work: AgentBridgeMigrationCoordinator.WorkChoice = .wait
    var scopes = 0
    var capturedScope = "user_launch_agent"
    func record(_ value: String) throws {
        events.append(value)
        if fail == value { throw AgentBridgeFailure.runtimeConflict }
    }
    func coordinator() -> AgentBridgeMigrationCoordinator {
        AgentBridgeMigrationCoordinator(.init(
            verifyReplacement: { try self.record("replacement") },
            readState: {
                try self.record("read")
                return .init(personaID: "persona-a", userPaused: self.paused, pauseVersion: self.version, laneIdle: self.idle)
            },
            stopAssignedRun: { try self.record("stop-run"); self.idle = true },
            confirmWork: { self.events.append("work-consent"); return self.work },
            confirmCutover: { self.events.append("cutover-consent"); return self.consent },
            setPause: { paused, expected in
                try self.record(paused ? "pause" : "resume")
                #expect(expected == self.version)
                self.paused = paused; self.version += 1
                return self.version
            },
            capture: {
                try self.record("capture")
                let data = Data("{\"migration_id\":\"11111111-1111-1111-1111-111111111111\",\"legacy_service_scope\":\"\(self.capturedScope)\",\"profile_candidate_id\":\"profile-a\"}".utf8)
                return try JSONDecoder().decode(AgentBridgeMigrationCapture.self, from: data)
            },
            stopSupervisor: { scope in #expect(scope == "user_launch_agent"); #expect(self.idle && self.paused); try self.record("stop-supervisor") },
            revoke: { try self.record("revoke") },
            validateScope: { self.scopes += 1 },
            readiness: { _ in try self.record("ready") },
            test: { try self.record("test") },
            wait: { try self.record("wait"); self.idle = true }
        ))
    }
}

@Suite @MainActor struct AgentBridgeMigrationTests {
    private let binding = AgentBridgeBindingKey(environmentID: "https://my.personastack.ai", connectionID: "new-a")

    @Test func waitsForWorkBeforeConsentAndPauseThenRequiresIdleBeforeSupervisorStop() async throws {
        let fixture = AgentBridgeMigrationFixture()
        fixture.idle = false
        let coordinator = fixture.coordinator()
        let cutover = try await coordinator.begin()
        #expect(fixture.events == ["replacement", "read", "work-consent", "read", "wait", "read", "cutover-consent", "read", "pause", "read", "capture", "stop-supervisor", "revoke"])
        #expect(fixture.paused)
        #expect(coordinator.revoked)
        #expect(try await coordinator.finish(cutover, binding: binding))
        #expect(Array(fixture.events.suffix(3)) == ["ready", "resume", "test"])
        #expect(!fixture.paused)
    }

    @Test func explicitStopOnlyCancelsAssignedRunBeforeCutover() async throws {
        let fixture = AgentBridgeMigrationFixture()
        fixture.idle = false; fixture.work = .stop
        _ = try await fixture.coordinator().begin()
        #expect(fixture.events.firstIndex(of: "stop-run")! < fixture.events.firstIndex(of: "cutover-consent")!)
        #expect(fixture.events.firstIndex(of: "cutover-consent")! < fixture.events.firstIndex(of: "pause")!)
    }

    @Test func cancelBeforeCutoverHasZeroPauseCaptureStopOrRevoke() async {
        let fixture = AgentBridgeMigrationFixture(); fixture.consent = false
        await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await fixture.coordinator().begin() }
        #expect(fixture.events == ["replacement", "read", "cutover-consent"])
    }

    @Test func failureBeforeRevocationRestoresOriginalPause() async {
        for point in ["capture", "stop-supervisor"] {
            let fixture = AgentBridgeMigrationFixture(); fixture.fail = point
            let coordinator = fixture.coordinator()
            await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await coordinator.begin() }
            #expect(!fixture.paused)
            #expect(!coordinator.revoked)
            #expect(fixture.events.last == "resume")
        }
    }

    @Test func revokeAndReadinessFailuresStayPausedAndNeverRestartLegacyService() async {
        let failedRevoke = AgentBridgeMigrationFixture(); failedRevoke.fail = "revoke"
        let first = failedRevoke.coordinator()
        await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await first.begin() }
        #expect(failedRevoke.paused && first.revoked)
        #expect(!failedRevoke.events.contains("resume"))
        let failedReady = AgentBridgeMigrationFixture(); failedReady.fail = "ready"
        let second = failedReady.coordinator()
        do {
            let cutover = try await second.begin()
            await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await second.finish(cutover, binding: binding) }
            #expect(failedReady.paused)
            #expect(!failedReady.events.contains("resume"))
        } catch { Issue.record("begin unexpectedly failed: \(error)") }
    }

    @Test func failedBoundedTestRepausesAndPreviouslyPausedDefersTest() async throws {
        let failedTest = AgentBridgeMigrationFixture(); failedTest.fail = "test"
        let first = failedTest.coordinator(); let cutover = try await first.begin()
        await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await first.finish(cutover, binding: binding) }
        #expect(failedTest.paused)
        #expect(Array(failedTest.events.suffix(4)) == ["ready", "resume", "test", "pause"])
        let paused = AgentBridgeMigrationFixture(); paused.paused = true
        let second = paused.coordinator(); let preserved = try await second.begin()
        #expect(try await second.finish(preserved, binding: binding) == false)
        #expect(paused.paused)
        #expect(!paused.events.contains("pause") && !paused.events.contains("resume") && !paused.events.contains("test"))
    }

    @Test func systemServiceRequiresManualAdminStepBeforeAnySupervisorOrRevoke() async {
        let fixture = AgentBridgeMigrationFixture(); fixture.capturedScope = "system_launch_daemon"
        await #expect(throws: AgentBridgeFailure.migrationRequired) { _ = try await fixture.coordinator().begin() }
        #expect(!fixture.events.contains("stop-supervisor") && !fixture.events.contains("revoke"))
        #expect(!fixture.paused)
    }

    @Test func pageAcceptsOpaqueMigrationProposalButRejectsMigrationAuthority() throws {
        let proposal: [String: Any] = ["version": "1", "action": "migration_prepare", "scope": "native-issued", "workspace_id": "ws_11111111111111111111111111111111",
            "persona_id": "persona-a", "connection_id": "legacy-a", "connection_generation": 7, "runtime_kind": "hermes", "profile_candidate_id": "profile-a"]
        #expect(try AgentBridgePageCommand.parse(proposal).action == "migration_prepare")
        var forged = proposal; forged["migration_id"] = UUID().uuidString
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try AgentBridgePageCommand.parse(forged) }
        forged = proposal; forged["legacy_service_scope"] = "user_launch_agent"
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try AgentBridgePageCommand.parse(forged) }
    }
}
