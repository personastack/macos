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
    var loseResumeAck = false
    var failScopeAfterResume = false
    var scopeInvalid = false
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
                if !paused, self.loseResumeAck { self.loseResumeAck = false; throw AgentBridgeFailure.serviceUnavailable }
                if !paused, self.failScopeAfterResume { self.failScopeAfterResume = false; self.scopeInvalid = true }
                return self.version
            },
            capture: { _, _ in
                try self.record("capture")
                let data = Data("{\"migration_id\":\"11111111-1111-1111-1111-111111111111\",\"legacy_service_scope\":\"\(self.capturedScope)\",\"profile_candidate_id\":\"profile-a\"}".utf8)
                return try JSONDecoder().decode(AgentBridgeMigrationCapture.self, from: data)
            },
            stopSupervisor: { scope in #expect(scope == "user_launch_agent"); #expect(self.idle && self.paused); try self.record("stop-supervisor") },
            cancelCapture: { _ in try self.record("cancel-capture") },
            revoke: { try self.record("revoke") },
            validateScope: { self.scopes += 1; if self.scopeInvalid { throw AgentBridgeFailure.scopeChanged } },
            readiness: { _ in try self.record("ready") },
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
        try await coordinator.finish(cutover, binding: binding)
        #expect(Array(fixture.events.suffix(3)) == ["ready", "read", "resume"])
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
        #expect(!first.revocationVerified)
        #expect(first.preparedCutover != nil)
        #expect(!failedRevoke.events.contains("resume"))
        failedRevoke.fail = nil
        do { try await first.ensureRevoked() } catch { Issue.record("exact revoke retry failed: \(error)") }
        #expect(first.revocationVerified)
        #expect(failedRevoke.events.suffix(2) == ["revoke", "revoke"])
        let failedReady = AgentBridgeMigrationFixture(); failedReady.fail = "ready"
        let second = failedReady.coordinator()
        do {
            let cutover = try await second.begin()
            await #expect(throws: AgentBridgeFailure.runtimeConflict) { _ = try await second.finish(cutover, binding: binding) }
            #expect(failedReady.paused)
            #expect(!failedReady.events.contains("resume"))
        } catch { Issue.record("begin unexpectedly failed: \(error)") }
    }

    @Test(arguments: [false, true]) func completionRestoresBothPauseStatesWithoutProviderDispatch(_ wasPaused: Bool) async throws {
        let fixture = AgentBridgeMigrationFixture(); fixture.paused = wasPaused
        let coordinator = fixture.coordinator(); let cutover = try await coordinator.begin()
        try await coordinator.finish(cutover, binding: binding)
        #expect(fixture.paused == wasPaused)
        #expect(Array(fixture.events.suffix(wasPaused ? 2 : 3)) == (wasPaused ? ["ready", "read"] : ["ready", "read", "resume"]))
        #expect(!fixture.events.contains("test"))
        #expect(fixture.events.filter { $0 == "resume" }.count == (wasPaused ? 0 : 1))
    }

    @Test func failedResumeStaysPausedForRepair() async throws {
        let fixture = AgentBridgeMigrationFixture()
        let coordinator = fixture.coordinator(); let cutover = try await coordinator.begin()
        fixture.fail = "resume"
        await #expect(throws: AgentBridgeFailure.runtimeConflict) { try await coordinator.finish(cutover, binding: binding) }
        #expect(fixture.paused)
        #expect(Array(fixture.events.suffix(3)) == ["ready", "read", "resume"])
    }

    @Test(arguments: ["lost_ack", "scope_changed"]) func committedResumeRetryChecksCurrentPauseAndDoesNotResumeTwice(_ failure: String) async throws {
        let fixture = AgentBridgeMigrationFixture()
        let coordinator = fixture.coordinator(); let cutover = try await coordinator.begin()
        fixture.loseResumeAck = failure == "lost_ack"
        fixture.failScopeAfterResume = failure == "scope_changed"
        await #expect(throws: failure == "lost_ack" ? AgentBridgeFailure.serviceUnavailable : AgentBridgeFailure.scopeChanged) {
            try await coordinator.finish(cutover, binding: binding)
        }
        #expect(!fixture.paused && fixture.version == cutover.pauseVersion + 1)
        fixture.scopeInvalid = false
        try await coordinator.finish(cutover, binding: binding)
        #expect(!fixture.paused)
        #expect(fixture.events.filter { $0 == "resume" }.count == 1)
        #expect(Array(fixture.events.suffix(2)) == ["ready", "read"])
    }

    @Test(arguments: [false, true]) func laterPauseIntentCannotBeOverwrittenByMigrationRetry(_ wasPaused: Bool) async throws {
        let fixture = AgentBridgeMigrationFixture(); fixture.paused = wasPaused
        let coordinator = fixture.coordinator(); let cutover = try await coordinator.begin()
        fixture.paused = !wasPaused; fixture.version += 2
        await #expect(throws: AgentBridgeFailure.scopeChanged) { try await coordinator.finish(cutover, binding: binding) }
        #expect(fixture.paused == !wasPaused)
        #expect(!fixture.events.contains("resume"))
        #expect(Array(fixture.events.suffix(2)) == ["ready", "read"])
    }

    @Test func systemServiceRequiresManualAdminStepBeforeAnySupervisorOrRevoke() async {
        let fixture = AgentBridgeMigrationFixture(); fixture.capturedScope = "system_launch_daemon"
        await #expect(throws: AgentBridgeFailure.migrationRequired) { _ = try await fixture.coordinator().begin() }
        #expect(!fixture.events.contains("stop-supervisor") && !fixture.events.contains("revoke"))
        #expect(!fixture.paused)
    }

    @Test func pageAcceptsOpaqueMigrationProposalButRejectsMigrationAuthority() throws {
        let proposal: [String: Any] = ["version": "2", "action": "migration_prepare", "scope": "native-issued", "workspace_id": "ws_11111111111111111111111111111111",
            "persona_id": "persona-a", "connection_id": "legacy-a", "connection_generation": 7, "runtime_kind": "hermes", "profile_candidate_id": "profile-a"]
        #expect(try AgentBridgePageCommand.parse(proposal).action == "migration_prepare")
        var forged = proposal; forged["migration_id"] = UUID().uuidString
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try AgentBridgePageCommand.parse(forged) }
        forged = proposal; forged["legacy_service_scope"] = "user_launch_agent"
        #expect(throws: AgentBridgeFailure.invalidRequest) { _ = try AgentBridgePageCommand.parse(forged) }
    }

    @Test func recoveredNativeCapturePreservesOriginalPauseAndCannotRepeatLegacyCutover() async throws {
        let fixture = AgentBridgeMigrationFixture()
        fixture.paused = true; fixture.version = 8
        let coordinator = fixture.coordinator()
        let capture = try JSONDecoder().decode(AgentBridgeMigrationCapture.self, from: Data(#"{"migration_id":"11111111-1111-1111-1111-111111111111","legacy_service_scope":"user_launch_agent","profile_candidate_id":"profile-a","was_paused":false,"pause_version":8}"#.utf8))
        let cutover = try coordinator.recover(capture, wasPaused: false, pauseVersion: 8)
        #expect(coordinator.revoked && coordinator.revocationVerified)
        await #expect(throws: AgentBridgeFailure.scopeChanged) { _ = try await coordinator.begin() }
        #expect(fixture.events.isEmpty)
        try await coordinator.finish(cutover, binding: binding)
        #expect(fixture.events == ["ready", "read", "resume"])
    }
}
