import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

@Test @MainActor
func desktopLockedWorkflowKeepsPrivacyUntilConsumedGrantUnlocksAndRelocks() async throws {
    let controller = DesktopLockedControlLocalPeer(processIdentifier: 10, effectiveUserID: 501, auditSessionID: 7,
                                                   signingIdentifier: "controller", teamIdentifier: nil)
    let mechanism = DesktopLockedControlLocalPeer(processIdentifier: 11, effectiveUserID: 0, auditSessionID: 7,
                                                  signingIdentifier: "mechanism", teamIdentifier: nil)
    let broker = DesktopLockedControlGrantBroker { peer, role in
        role == .controller ? peer == controller : peer == mechanism
    }
    let lease = DesktopLockedControlSession.Lease(connectionID: UUID(), token: UUID(), expires: .now + .seconds(90))
    let grant = DesktopLockedControlGrant(connectionID: lease.connectionID, leaseToken: lease.token,
                                          consoleUserID: 501, consoleSessionID: "7", expiresAtMonotonicNanoseconds: 90)
    var locked = true
    var protected = false
    var gate: CheckedContinuation<Bool, Never>?
    let session = DesktopLockedControlSession(operations: .init(
        authorized: { $0 == lease }, sessionLocked: { locked },
        protectDisplays: { protected = true },
        restoreDisplays: {
            #expect(locked && broker.state == .idle)
            protected = false
        },
        armAuthorization: { _ in try broker.arm(grant, peer: controller, nowMonotonicNanoseconds: 1) },
        revokeAuthorization: { _ = broker.revoke(connectionID: lease.connectionID, leaseToken: lease.token) },
        awaitAuthorizationSettled: { !broker.mayStillUnlock },
        requestWake: {
            #expect(protected)
            #expect(broker.consumeCurrentGrant(consoleUserID: 501, consoleSessionID: "7", peer: mechanism,
                                               nowMonotonicNanoseconds: 2))
        },
        awaitUnlockedSession: {
            let observed = await withCheckedContinuation { gate = $0 }
            if observed {
                locked = false
                #expect(broker.observeActualUnlock(connectionID: lease.connectionID, leaseToken: lease.token,
                                                     consoleUserID: 501, consoleSessionID: "7", peer: controller))
            }
            return observed
        },
        restoreOSLock: {
            locked = true
            return broker.confirmActualRelock(connectionID: lease.connectionID, leaseToken: lease.token,
                                               consoleUserID: 501, consoleSessionID: "7", peer: controller)
        }))
    let pending = Task { try await session.begin(lease) }
    for _ in 0..<100 where gate == nil { await Task.yield() }
    let unlock = try #require(gate)
    #expect(broker.state == .transitionPending)
    #expect(await session.end() == false)
    #expect(protected && locked)
    #expect(!session.permitsExecution)
    unlock.resume(returning: true)
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(protected && !locked)
    #expect(broker.state == .unlockedObserved)
    #expect(await session.end())
    #expect(!protected && locked)
    #expect(broker.state == .idle)
}
