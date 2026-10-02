import Foundation
import Testing
@testable import PersonaStackCore

private let grantControllerPeer = DesktopLockedControlLocalPeer(
    processIdentifier: 10, effectiveUserID: 501, auditSessionID: 7,
    signingIdentifier: "ai.personastack.app", teamIdentifier: "TEAM"
)
private let grantAuthorizationPeer = DesktopLockedControlLocalPeer(
    processIdentifier: 11, effectiveUserID: 0, auditSessionID: 7,
    signingIdentifier: "com.apple.authorizationhost", teamIdentifier: nil
)

private func lockedGrant(_ expiresAt: UInt64 = 10_000) -> DesktopLockedControlGrant {
    DesktopLockedControlGrant(connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                              leaseToken: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                              consoleUserID: 501, consoleSessionID: "session-7",
                              expiresAtMonotonicNanoseconds: expiresAt)
}

private func grantBroker(trusting peers: [DesktopLockedControlLocalPeer] = [grantControllerPeer, grantAuthorizationPeer]) -> DesktopLockedControlGrantBroker {
    DesktopLockedControlGrantBroker { peer, role in
        guard peers.contains(peer) else { return false }
        return switch role {
        case .controller: peer == grantControllerPeer
        case .authorizationMechanism: peer == grantAuthorizationPeer
        }
    }
}

@Test func desktopLockedGrantIsConsumedOnceAndFencedUntilConfirmedRelock() throws {
    let broker = grantBroker()
    let grant = lockedGrant()
    try broker.arm(grant, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    #expect(broker.state == .armed)
    #expect(broker.mayStillUnlock)
    #expect(broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                            consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                            peer: grantAuthorizationPeer, nowMonotonicNanoseconds: 2))
    #expect(broker.state == .transitionPending)
    #expect(broker.mayStillUnlock)
    #expect(!broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                             peer: grantAuthorizationPeer, nowMonotonicNanoseconds: 3))
    #expect(broker.revoke(connectionID: grant.connectionID, leaseToken: grant.leaseToken) == .awaitingOSLock)
    #expect(broker.revoke(connectionID: UUID(), leaseToken: grant.leaseToken) == .scopeMismatch)
    #expect(broker.state == .transitionPending)
    #expect(!broker.confirmActualRelock(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                         consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                                         peer: grantControllerPeer))
    #expect(broker.observeActualUnlock(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                       consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                                       peer: grantControllerPeer))
    #expect(broker.state == .unlockedObserved)
    #expect(!broker.mayStillUnlock)
    #expect(broker.confirmActualRelock(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                       consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                                       peer: grantControllerPeer))
    #expect(broker.state == .idle)
    #expect(!broker.mayStillUnlock)
}

@Test func desktopLockedGrantRevokedBeforeConsumptionCannotAllow() throws {
    let broker = grantBroker()
    let grant = lockedGrant()
    try broker.arm(grant, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    #expect(broker.revoke(connectionID: grant.connectionID, leaseToken: grant.leaseToken) == .settled)
    #expect(!broker.mayStillUnlock)
    #expect(!broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                             peer: grantAuthorizationPeer, nowMonotonicNanoseconds: 2))
    #expect(broker.state == .idle)
}

@Test func desktopLockedGrantRejectsUntrustedPeersAndScopeMismatch() throws {
    let controller = grantControllerPeer
    let auth = grantAuthorizationPeer
    let untrusted = DesktopLockedControlLocalPeer(
        processIdentifier: 12, effectiveUserID: 501, auditSessionID: 7,
        signingIdentifier: "other.app", teamIdentifier: "OTHER"
    )
    let broker = grantBroker()
    let grant = lockedGrant()
    #expect(throws: DesktopLockedControlGrantBrokerError.untrustedPeer) {
        try broker.arm(grant, peer: untrusted, nowMonotonicNanoseconds: 1)
    }
    try broker.arm(grant, peer: controller, nowMonotonicNanoseconds: 1)
    #expect(!broker.consume(connectionID: UUID(), leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                             peer: auth, nowMonotonicNanoseconds: 2))
    #expect(!broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID, consoleSessionID: "other-session",
                             peer: untrusted, nowMonotonicNanoseconds: 2))
    #expect(!broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID + 1, consoleSessionID: grant.consoleSessionID,
                             peer: auth, nowMonotonicNanoseconds: 2))
    #expect(broker.state == .armed)
}

@Test func desktopLockedGrantEnforcesExpiryAndBoundedScope() throws {
    let broker = grantBroker()
    let grant = lockedGrant(10)
    try broker.arm(grant, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    #expect(!broker.consume(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                             consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
                             peer: grantAuthorizationPeer, nowMonotonicNanoseconds: 10))
    #expect(broker.state == .idle)

    let malformed = DesktopLockedControlGrant(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                              consoleUserID: 501, consoleSessionID: "session\n7",
                                              expiresAtMonotonicNanoseconds: 100)
    #expect(throws: DesktopLockedControlGrantBrokerError.invalidGrant) {
        try broker.arm(malformed, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    }
    let overlong = DesktopLockedControlGrant(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                             consoleUserID: 501, consoleSessionID: String(repeating: "x", count: 129),
                                             expiresAtMonotonicNanoseconds: 100)
    #expect(throws: DesktopLockedControlGrantBrokerError.invalidGrant) {
        try broker.arm(overlong, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    }
    let tooLong = DesktopLockedControlGrant(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                            consoleUserID: 501, consoleSessionID: "session-7",
                                            expiresAtMonotonicNanoseconds: DesktopLockedControlGrantBroker.maximumGrantLifetimeNanoseconds + 2)
    #expect(throws: DesktopLockedControlGrantBrokerError.invalidGrant) {
        try broker.arm(tooLong, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    }
}

@Test func desktopLockedGrantIPCUsesFixedSizeNonceBoundMessages() {
    let nonce = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    let request = DesktopLockedControlGrantIPCMessage.encodeRequest(nonce: nonce)
    #expect(request.count == DesktopLockedControlGrantIPCMessage.requestSize)
    #expect(DesktopLockedControlGrantIPCMessage.decodeRequest(request) == nonce)
    #expect(DesktopLockedControlGrantIPCMessage.decodeRequest(Data(request.dropLast())) == nil)

    let allowed = DesktopLockedControlGrantIPCMessage.encodeResponse(nonce: nonce, allow: true)
    #expect(allowed.count == DesktopLockedControlGrantIPCMessage.responseSize)
    #expect(DesktopLockedControlGrantIPCMessage.decodeResponse(allowed, matching: nonce) == true)
    #expect(DesktopLockedControlGrantIPCMessage.decodeResponse(allowed, matching: UUID()) == nil)
    #expect(DesktopLockedControlGrantIPCMessage.decodeResponse(
        DesktopLockedControlGrantIPCMessage.encodeResponse(nonce: nonce, allow: false), matching: nonce
    ) == false)
}

@Test func desktopLockedGrantConsumptionRechecksConsoleAfterRequestRead() throws {
    let broker = grantBroker()
    let grant = lockedGrant()
    try broker.arm(grant, peer: grantControllerPeer, nowMonotonicNanoseconds: 1)
    var consumeCalls = 0
    func consume() -> Bool {
        consumeCalls += 1
        return broker.consumeCurrentGrant(consoleUserID: grant.consoleUserID,
            consoleSessionID: grant.consoleSessionID, peer: grantAuthorizationPeer,
            nowMonotonicNanoseconds: 2)
    }
    let changedIdentities: [(UInt32, String)?] = [nil, (502, "session-7"), (501, "session-8")]
    for changedIdentity in changedIdentities {
        let allowed = DesktopLockedControlGrantIPCServer.consumeForCurrentConsole(
            consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
            readIdentity: { changedIdentity }, consume: consume)
        #expect(!allowed)
        #expect(consumeCalls == 0)
        #expect(broker.state == .armed)
    }
    let allowed = DesktopLockedControlGrantIPCServer.consumeForCurrentConsole(
        consoleUserID: grant.consoleUserID, consoleSessionID: grant.consoleSessionID,
        readIdentity: { (501, "session-7") }, consume: consume)
    #expect(allowed)
    #expect(consumeCalls == 1)
    #expect(broker.state == .transitionPending)
}
