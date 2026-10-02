import Foundation
import Testing
@testable import PersonaStack

@MainActor
private final class LockedSessionFixture {
    var events: [String] = []
    var authorized = true
    var locked = true
    var privacyFails = false
    var unlockSucceeds = true
    var lockSucceeds = true
    var restoreFails = false
    var gate: CheckedContinuation<Bool, Never>?
    var suspendUnlock = false
    var settled = true
    var relockConfirmed = true
    var clock = ContinuousClock.now
    lazy var session = DesktopLockedControlSession(operations: .init(
        authorized: { [self] _ in authorized },
        sessionLocked: { [self] in locked },
        protectDisplays: { [self] in events.append("protect"); if privacyFails { throw Failure.test } },
        restoreDisplays: { [self] in events.append("restore"); if restoreFails { throw Failure.test } },
        armAuthorization: { [self] _ in events.append("arm") },
        revokeAuthorization: { [self] in events.append("revoke") },
        awaitAuthorizationSettled: { [self] in settled },
        requestWake: { [self] in events.append("wake") },
        awaitUnlockedSession: { [self] in
            events.append("observe-unlock")
            let result = suspendUnlock ? await withCheckedContinuation { gate = $0 } : unlockSucceeds
            if result { locked = false }
            return result
        },
        restoreOSLock: { [self] in
            events.append("lock")
            if lockSucceeds { locked = true }
            return lockSucceeds
        },
        confirmRelockBeforeRearming: { [self] in
            events.append("confirm-relock")
            return locked && relockConfirmed
        }), now: { [self] in clock })
    enum Failure: Error { case test }
    var lease: DesktopLockedControlSession.Lease {
        .init(connectionID: UUID(), token: UUID(), expires: clock + .seconds(90))
    }
}

@Suite @MainActor
struct DesktopLockedControlSessionTests {
    @Test func protectsBeforeAuthorizationAndRestoresOnlyAfterObservedLock() async throws {
        let fixture = LockedSessionFixture()
        try await fixture.session.begin(fixture.lease)
        #expect(fixture.events == ["protect", "arm", "wake", "observe-unlock"])
        #expect(fixture.session.permitsExecution)
        #expect(await fixture.session.end())
        #expect(fixture.events.suffix(3) == ["revoke", "lock", "restore"])
        #expect(fixture.session.state == .idle)
        #expect(!fixture.session.permitsExecution)
    }

    @Test func secondLockRearmsSameLeaseWithoutRestoringPrivacy() async throws {
        let fixture = LockedSessionFixture()
        let lease = fixture.lease
        try await fixture.session.begin(lease)
        fixture.locked = true
        try await fixture.session.resumeAfterOrdinaryLock()
        #expect(fixture.events == ["protect", "arm", "wake", "observe-unlock",
            "revoke", "confirm-relock", "arm", "wake", "observe-unlock"])
        #expect(fixture.session.permitsExecution)
        #expect(await fixture.session.end())
        #expect(fixture.events.filter { $0 == "restore" }.count == 1)
    }

    @Test func secondLockMustSettlePreviousGrantBeforeRearming() async throws {
        let fixture = LockedSessionFixture()
        try await fixture.session.begin(fixture.lease)
        fixture.locked = true
        fixture.settled = false
        await #expect(throws: DesktopLockedControlSession.Failure.cleanupFailed) {
            try await fixture.session.resumeAfterOrdinaryLock()
        }
        #expect(fixture.events.filter { $0 == "arm" }.count == 1)
        #expect(!fixture.events.contains("restore"))
        #expect(fixture.session.state == .needsAttention)
        fixture.settled = true
        #expect(await fixture.session.end())
    }

    @Test func consentAndExpiryDenyBeforeAnyOSMutation() async {
        let fixture = LockedSessionFixture()
        fixture.authorized = false
        await #expect(throws: DesktopLockedControlSession.Failure.unauthorized) {
            try await fixture.session.begin(fixture.lease)
        }
        fixture.authorized = true
        let expired = fixture.lease
        fixture.clock += .seconds(91)
        await #expect(throws: DesktopLockedControlSession.Failure.unauthorized) {
            try await fixture.session.begin(expired)
        }
        #expect(fixture.events.isEmpty)
    }

    @Test func privacyFailureNeverArmsAndWakeWithoutUnlockNeverAdmits() async {
        let privacy = LockedSessionFixture()
        privacy.privacyFails = true
        await #expect(throws: LockedSessionFixture.Failure.test) { try await privacy.session.begin(privacy.lease) }
        #expect(privacy.events == ["protect", "revoke", "restore"])
        let wake = LockedSessionFixture()
        wake.unlockSucceeds = false
        await #expect(throws: DesktopLockedControlSession.Failure.unlockUnavailable) { try await wake.session.begin(wake.lease) }
        #expect(!wake.session.permitsExecution)
        #expect(wake.events == ["protect", "arm", "wake", "observe-unlock", "revoke", "restore"])
    }

    @Test func revokedOrExpiredLeaseCannotKeepExecutionAfterUnlock() async throws {
        let fixture = LockedSessionFixture()
        try await fixture.session.begin(fixture.lease)
        fixture.authorized = false
        #expect(!fixture.session.permitsExecution)
        #expect(await fixture.session.end())
        fixture.authorized = true
        try await fixture.session.begin(fixture.lease)
        fixture.clock += .seconds(91)
        #expect(!fixture.session.permitsExecution)
        #expect(await fixture.session.end())
    }

    @Test func failedRelockRetainsProtectionAndCanBeRetried() async throws {
        let fixture = LockedSessionFixture()
        try await fixture.session.begin(fixture.lease)
        fixture.lockSucceeds = false
        #expect(await fixture.session.end() == false)
        #expect(fixture.session.state == .needsAttention)
        #expect(!fixture.events.contains("restore"))
        await #expect(throws: DesktopLockedControlSession.Failure.busy) { try await fixture.session.begin(fixture.lease) }
        fixture.lockSucceeds = true
        #expect(await fixture.session.end())
        #expect(fixture.events.last == "restore")
    }

    @Test func stopFencesPendingAuthorization() async throws {
        let fixture = LockedSessionFixture()
        fixture.suspendUnlock = true
        let task = Task { try await fixture.session.begin(fixture.lease) }
        for _ in 0..<100 where fixture.gate == nil { await Task.yield() }
        let gate = try #require(fixture.gate)
        fixture.settled = false
        #expect(await fixture.session.end() == false)
        #expect(!fixture.events.contains("restore"))
        gate.resume(returning: true)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!fixture.session.permitsExecution)
        fixture.settled = true
        #expect(await fixture.session.end())
        #expect(fixture.session.state == .idle)
    }
}
