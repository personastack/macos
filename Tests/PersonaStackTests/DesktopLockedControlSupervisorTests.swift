import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

@Test @MainActor
func desktopLockedSupervisorComposesGrantPrivacyInputAndRelockInOrder() async throws {
    let f = LockedSupervisorFixture()
    let supervisor = f.makeSupervisor()

    #expect(supervisor.state == .idle)
    #expect(f.events.isEmpty)
    try await supervisor.begin(grant: f.grant, driverPID: 44)

    #expect(supervisor.state == .controlling)
    #expect(f.broker.state == .unlockedObserved)
    #expect(f.events == ["ipc-start", "privacy-on", "input-on", "arm", "wake", "unlock-observed"])
    #expect(await supervisor.end())
    #expect(supervisor.state == .idle)
    #expect(f.broker.state == .idle)
    #expect(Array(f.events.suffix(4)) == ["ipc-stop", "relock", "privacy-off", "input-off"])
}

@Test @MainActor
func desktopLockedSupervisorEndsWhenAuthenticatedClientHeartbeatIsLost() async throws {
    let f = LockedSupervisorFixture()
    let supervisor = f.makeSupervisor()
    try await supervisor.begin(grant: f.grant, driverPID: 44)

    f.heartbeatCurrent = false
    await supervisor.observe()

    #expect(supervisor.state == .idle)
    #expect(f.broker.state == .idle)
    #expect(f.events.contains("privacy-off"))
}

@Test @MainActor
func desktopLockedSupervisorKeepsCoverUntilLateConsumedGrantIsRelocked() async throws {
    let f = LockedSupervisorFixture()
    f.unlockOnWake = false
    let supervisor = f.makeSupervisor()

    await #expect(throws: DesktopLockedControlSession.Failure.cleanupFailed) {
        try await supervisor.begin(grant: f.grant, driverPID: 44)
    }
    #expect(supervisor.state == .needsAttention)
    #expect(f.protected)
    #expect(f.broker.state == .transitionPending)

    f.locked = false // The OS completes the already-consumed authorization late.
    await supervisor.observe()

    #expect(supervisor.state == .idle)
    #expect(f.locked && !f.protected)
    #expect(f.broker.state == .idle)
}

@Test @MainActor
func desktopLockedSupervisorStaleBeginCannotStopAReplacementTransaction() async throws {
    let f = LockedSupervisorFixture()
    f.consumeOnWake = false
    f.unlockOnWake = false
    f.suspendNextSleep = true
    let supervisor = f.makeSupervisor()
    let staleBegin = Task { try await supervisor.begin(grant: f.grant, driverPID: 44) }
    for _ in 0..<100 where f.sleepGate == nil { await Task.yield() }
    #expect(f.sleepGate != nil)

    #expect(await supervisor.end())
    f.consumeOnWake = true
    f.unlockOnWake = true
    try await supervisor.begin(grant: f.grant, driverPID: 44)
    #expect(supervisor.status().state == .controlling)

    f.sleepGate?.resume()
    f.sleepGate = nil
    await #expect(throws: CancellationError.self) { try await staleBegin.value }
    #expect(supervisor.status().state == .controlling)
    #expect(f.broker.state == .unlockedObserved)
    #expect(await supervisor.end())
}

@Test @MainActor
func desktopLockedSupervisorConcurrentEndKeepsCurrentCleanupOwner() async throws {
    let f = LockedSupervisorFixture()
    let supervisor = f.makeSupervisor()
    try await supervisor.begin(grant: f.grant, driverPID: 44)
    f.suspendRelock = true

    let firstEnd = Task { await supervisor.end() }
    for _ in 0..<100 where f.relockGate == nil { await Task.yield() }
    #expect(f.relockGate != nil)
    let secondEnd = Task { await supervisor.end() }
    await Task.yield()
    f.relockGate?.resume()
    f.relockGate = nil

    #expect(await firstEnd.value)
    #expect(await secondEnd.value)
    #expect(supervisor.status().state == .idle)
    #expect(f.events.filter { $0 == "input-off" }.count == 1)
}

@Test @MainActor
func desktopLockedSupervisorRearmsAfterSecondLockWithoutDroppingPrivacy() async throws {
    let f = LockedSupervisorFixture()
    let supervisor = f.makeSupervisor()
    try await supervisor.begin(grant: f.grant, driverPID: 44)
    f.locked = true
    await supervisor.observe()
    for _ in 0..<100 where supervisor.state == .starting { await Task.yield() }
    #expect(supervisor.state == .controlling)
    #expect(f.events.filter { $0 == "arm" }.count == 2)
    #expect(f.events.filter { $0 == "privacy-on" }.count == 1)
    #expect(!f.events.contains("privacy-off"))
    #expect(f.broker.state == .unlockedObserved)
    #expect(await supervisor.end())
}

@Test @MainActor
func desktopLockedSupervisorTakeoverFencesQueuedSecondUnlock() async throws {
    let f = LockedSupervisorFixture()
    let supervisor = f.makeSupervisor()
    try await supervisor.begin(grant: f.grant, driverPID: 44)
    supervisor.onStatusChange = { status in
        if status.state == .starting { f.takeover?() }
    }
    f.locked = true
    await supervisor.observe()
    // Takeover fires when recovery is announced, before its task can run.
    for _ in 0..<100 where supervisor.state != .idle { await Task.yield() }
    #expect(supervisor.state == .idle)
    #expect(f.events.filter { $0 == "arm" }.count == 1)
    #expect(f.broker.state == .idle)
    await supervisor.observe()
    #expect(f.events.filter { $0 == "arm" }.count == 1)
}

@MainActor
private final class LockedSupervisorFixture {
    let connectionID = UUID()
    let leaseToken = UUID()
    let controller = DesktopLockedControlLocalPeer(processIdentifier: 10, effectiveUserID: 501,
                                                   auditSessionID: 7, signingIdentifier: "controller",
                                                   teamIdentifier: nil)
    let mechanism = DesktopLockedControlLocalPeer(processIdentifier: 11, effectiveUserID: 0,
                                                  auditSessionID: 7, signingIdentifier: "mechanism",
                                                  teamIdentifier: nil)
    var now: UInt64 = 1
    var locked = true
    var heartbeatCurrent = true
    var unlockOnWake = true
    var consumeOnWake = true
    var suspendNextSleep = false
    var sleepGate: CheckedContinuation<Void, Never>?
    var suspendRelock = false
    var relockGate: CheckedContinuation<Void, Never>?
    var protected = false
    var takeover: (@MainActor () -> Void)?
    var events: [String] = []
    lazy var broker = DesktopLockedControlGrantBroker { peer, role in
        role == .controller ? peer == self.controller : peer == self.mechanism
    }
    lazy var grant = DesktopLockedControlGrant(connectionID: connectionID, leaseToken: leaseToken,
                                               consoleUserID: 501, consoleSessionID: "7",
                                               expiresAtMonotonicNanoseconds: 60_000_000_000)
    lazy var lease = DesktopLockedControlSession.Lease(connectionID: connectionID, token: leaseToken,
                                                       expires: .now + .seconds(60))

    func makeSupervisor() -> DesktopLockedControlSupervisor {
        DesktopLockedControlSupervisor(operations: .init(
            currentController: { self.controller },
            currentConsole: {
                .init(userID: 501, sessionID: "7", lock: self.locked ? .locked : .unlocked)
            },
            leaseForGrant: { grant, pid in grant == self.grant && pid == 44 ? self.lease : nil },
            leaseIsAuthorized: { $0 == self.lease && self.heartbeatCurrent },
            clientHeartbeatIsCurrent: { self.heartbeatCurrent },
            startLifecycleObservers: { _ in },
            stopLifecycleObservers: {},
            startGrantIPC: { self.events.append("ipc-start") },
            stopGrantIPC: { self.events.append("ipc-stop"); _ = self.broker.revokeArmedGrant() },
            stopLocalInput: { self.events.append("input-off") },
            protectDisplays: { pid, takeover, failure in
                #expect(pid == 44 && self.locked)
                self.protected = true
                self.events.append("privacy-on")
                self.events.append("input-on")
                self.takeover = takeover
                _ = failure
            },
            restoreDisplays: {
                #expect(self.locked && !self.broker.mayStillUnlock)
                self.protected = false
                self.events.append("privacy-off")
            },
            armGrant: { grant, peer in
                try self.broker.arm(grant, peer: peer, nowMonotonicNanoseconds: self.now)
                self.events.append("arm")
            },
            revokeGrant: { grant in _ = self.broker.revoke(connectionID: grant.connectionID,
                                                            leaseToken: grant.leaseToken) },
            grantMayStillUnlock: { self.broker.mayStillUnlock },
            observeUnlock: { grant, peer in
                let accepted = self.broker.observeActualUnlock(connectionID: grant.connectionID,
                                                               leaseToken: grant.leaseToken,
                                                               consoleUserID: grant.consoleUserID,
                                                               consoleSessionID: grant.consoleSessionID,
                                                               peer: peer)
                if accepted { self.events.append("unlock-observed") }
                return accepted
            },
            confirmRelock: { grant, peer in
                if self.broker.state == .idle { return true }
                return self.broker.confirmActualRelock(connectionID: grant.connectionID,
                                                leaseToken: grant.leaseToken,
                                                consoleUserID: grant.consoleUserID,
                                                consoleSessionID: grant.consoleSessionID,
                                                peer: peer)
            },
            currentControllerIs: { $0 == self.controller },
            requestWake: {
                #expect(self.protected)
                if self.consumeOnWake {
                    #expect(self.broker.consumeCurrentGrant(consoleUserID: 501, consoleSessionID: "7",
                                                            peer: self.mechanism,
                                                            nowMonotonicNanoseconds: self.now))
                }
                self.events.append("wake")
                if self.unlockOnWake { self.locked = false }
            },
            restoreOSLock: {
                self.locked = true
                self.events.append("relock")
                if self.suspendRelock {
                    self.suspendRelock = false
                    await withCheckedContinuation { self.relockGate = $0 }
                }
                return true
            },
            nowNanoseconds: { self.now },
            sleep: { _ in
                if self.suspendNextSleep {
                    self.suspendNextSleep = false
                    await withCheckedContinuation { self.sleepGate = $0 }
                }
                self.now += 100_000_000
                await Task.yield()
            }))
    }
}
