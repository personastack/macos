import Foundation
import LockedControlAudit

public struct DesktopLockedControlGrant: Equatable, Sendable {
    public let connectionID: UUID
    public let leaseToken: UUID
    public let consoleUserID: UInt32
    public let consoleSessionID: String
    public let expiresAtMonotonicNanoseconds: UInt64

    public init(connectionID: UUID, leaseToken: UUID, consoleUserID: UInt32,
                consoleSessionID: String, expiresAtMonotonicNanoseconds: UInt64) {
        self.connectionID = connectionID
        self.leaseToken = leaseToken
        self.consoleUserID = consoleUserID
        self.consoleSessionID = consoleSessionID
        self.expiresAtMonotonicNanoseconds = expiresAtMonotonicNanoseconds
    }

    fileprivate var hasValidScope: Bool {
        !consoleSessionID.isEmpty && consoleSessionID.utf8.count <= 128 &&
            !consoleSessionID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    fileprivate func matches(connectionID: UUID, leaseToken: UUID,
                             consoleUserID: UInt32, consoleSessionID: String) -> Bool {
        self.connectionID == connectionID && self.leaseToken == leaseToken &&
            self.consoleUserID == consoleUserID && self.consoleSessionID == consoleSessionID
    }
}

/// Credentials copied from the operating system's local peer audit data.
/// The transport adapter must populate these values from an authenticated peer.
public struct DesktopLockedControlLocalPeer: Equatable, Sendable {
    public let processIdentifier: Int32
    public let effectiveUserID: UInt32
    public let auditSessionID: UInt32
    public let signingIdentifier: String
    public let teamIdentifier: String?

    init(processIdentifier: Int32, effectiveUserID: UInt32,
         auditSessionID: UInt32, signingIdentifier: String, teamIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.effectiveUserID = effectiveUserID
        self.auditSessionID = auditSessionID
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public static func currentController(pinnedReleaseCertificate: Data) throws -> Self {
        let signatureValid = pinnedReleaseCertificate.withUnsafeBytes { bytes in
            PSVerifyPersonaStackSelf(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 1
        }
        guard signatureValid else {
            throw DesktopLockedControlGrantBrokerError.untrustedPeer
        }
        var sessionID: UInt32 = 0
        guard PSCurrentAuditSessionID(&sessionID) == 1, sessionID > 0 else {
            throw DesktopLockedControlGrantBrokerError.untrustedPeer
        }
        var consoleUserID: UInt32 = 0
        guard PSCurrentConsoleUserID(&consoleUserID) == 1,
              consoleUserID == UInt32(getuid()) else {
            throw DesktopLockedControlGrantBrokerError.untrustedPeer
        }
        return Self(processIdentifier: getpid(), effectiveUserID: UInt32(geteuid()),
                    auditSessionID: sessionID, signingIdentifier: "ai.personastack.desktop",
                    teamIdentifier: nil)
    }
}

public enum DesktopLockedControlGrantPeerRole: Equatable, Sendable {
    case controller
    case authorizationMechanism
}

public enum DesktopLockedControlGrantBrokerError: Error, Equatable {
    case invalidGrant
    case untrustedPeer
    case grantAlreadyActive
}

public enum DesktopLockedControlGrantRevokeResult: Equatable, Sendable {
    case settled
    case awaitingOSLock
    case scopeMismatch
}

public enum DesktopLockedControlGrantBrokerState: Equatable, Sendable {
    case idle
    case armed
    case transitionPending
    case unlockedObserved
}

/// Versioned fixed-size local socket messages. The authorization mechanism
/// carries only a fresh nonce; lease and connection scope stay broker-owned.
public enum DesktopLockedControlGrantIPCMessage {
    public static let requestSize = 24
    public static let responseSize = 24

    private static let requestMagic = Data([0x50, 0x53, 0x44, 0x51]) // PSDQ
    private static let responseMagic = Data([0x50, 0x53, 0x44, 0x52]) // PSDR
    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public static func encodeRequest(nonce: UUID) -> Data {
        var data = requestMagic
        data.append(contentsOf: [1, 1, 0, 0])
        withUnsafeBytes(of: nonce.uuid) { data.append(contentsOf: $0) }
        return data
    }

    public static func decodeRequest(_ data: Data) -> UUID? {
        guard data.count == requestSize,
              data.prefix(4) == requestMagic,
              data[4] == 1, data[5] == 1, data[6] == 0, data[7] == 0,
              let nonce = uuid(in: data[8..<requestSize]), nonce != zeroUUID else {
            return nil
        }
        return nonce
    }

    public static func encodeResponse(nonce: UUID, allow: Bool) -> Data {
        var data = responseMagic
        data.append(contentsOf: [1, allow ? 1 : 0, 0, 0])
        withUnsafeBytes(of: nonce.uuid) { data.append(contentsOf: $0) }
        return data
    }

    public static func decodeResponse(_ data: Data, matching nonce: UUID) -> Bool? {
        guard data.count == responseSize,
              data.prefix(4) == responseMagic,
              data[4] == 1, data[5] <= 1, data[6] == 0, data[7] == 0,
              uuid(in: data[8..<responseSize]) == nonce else { return nil }
        return data[5] == 1
    }

    private static func uuid(in bytes: Data.SubSequence) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let value = Array(bytes)
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
}

/// Stores one in-memory, one-shot authorization permit. A consumed permit stays
/// fenced until the caller observes and confirms the actual OS lock again.
public final class DesktopLockedControlGrantBroker: @unchecked Sendable {
    public typealias PeerVerifier = @Sendable (DesktopLockedControlLocalPeer, DesktopLockedControlGrantPeerRole) -> Bool

    public static let maximumGrantLifetimeNanoseconds: UInt64 = 30 * 60 * 1_000_000_000

    private enum Phase {
        case idle
        case armed(DesktopLockedControlGrant)
        case transitionPending(DesktopLockedControlGrant)
        case unlockedObserved(DesktopLockedControlGrant)
    }

    private let lock = NSLock()
    private let verifiesPeer: PeerVerifier
    private var phase: Phase = .idle

    public init(verifiesPeer: @escaping PeerVerifier) {
        self.verifiesPeer = verifiesPeer
    }

    public static func localController(pinnedReleaseCertificate: Data) -> Self {
        Self { peer, role in
            var currentSessionID: UInt32 = 0
            guard PSCurrentAuditSessionID(&currentSessionID) == 1,
                  peer.auditSessionID == currentSessionID else { return false }
            switch role {
            case .controller:
                let signatureValid = pinnedReleaseCertificate.withUnsafeBytes { bytes in
                    PSVerifyPersonaStackSelf(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 1
                }
                return peer.processIdentifier == getpid() && peer.effectiveUserID == UInt32(geteuid()) &&
                    peer.signingIdentifier == "ai.personastack.desktop" &&
                    signatureValid
            case .authorizationMechanism:
                return peer.effectiveUserID == 0 && peer.signingIdentifier == "com.apple.authorizationhost"
            }
        }
    }

    public var state: DesktopLockedControlGrantBrokerState {
        lock.lock()
        defer { lock.unlock() }
        return switch phase {
        case .idle: .idle
        case .armed: .armed
        case .transitionPending: .transitionPending
        case .unlockedObserved: .unlockedObserved
        }
    }

    /// True while a grant is armed or an Allow may still produce a delayed
    /// unlock. An observed unlocked session means the pending transition ended.
    public var mayStillUnlock: Bool {
        lock.lock()
        defer { lock.unlock() }
        return switch phase {
        case .armed, .transitionPending: true
        case .idle, .unlockedObserved: false
        }
    }

    public func arm(_ grant: DesktopLockedControlGrant,
                    peer: DesktopLockedControlLocalPeer,
                    nowMonotonicNanoseconds: UInt64) throws {
        guard verifiesPeer(peer, .controller) else { throw DesktopLockedControlGrantBrokerError.untrustedPeer }
        guard grant.consoleUserID > 0, grant.hasValidScope,
              grant.expiresAtMonotonicNanoseconds > nowMonotonicNanoseconds,
              grant.expiresAtMonotonicNanoseconds - nowMonotonicNanoseconds <= Self.maximumGrantLifetimeNanoseconds else {
            throw DesktopLockedControlGrantBrokerError.invalidGrant
        }

        lock.lock()
        defer { lock.unlock() }
        expireArmedGrantIfNeeded(nowMonotonicNanoseconds)
        guard case .idle = phase else { throw DesktopLockedControlGrantBrokerError.grantAlreadyActive }
        phase = .armed(grant)
    }

    /// Consumes the authorization permit before returning Allow to the caller.
    /// The caller must deny when this returns false.
    public func consume(connectionID: UUID, leaseToken: UUID,
                        consoleUserID: UInt32, consoleSessionID: String,
                        peer: DesktopLockedControlLocalPeer,
                        nowMonotonicNanoseconds: UInt64) -> Bool {
        guard verifiesPeer(peer, .authorizationMechanism) else { return false }
        return consumeCurrentGrant(consoleUserID: consoleUserID,
                                   consoleSessionID: consoleSessionID,
                                   nowMonotonicNanoseconds: nowMonotonicNanoseconds,
                                   matching: { $0.connectionID == connectionID && $0.leaseToken == leaseToken })
    }

    /// IPC adapter entry point. The controller scope remains broker-owned; the
    /// mechanism supplies only the session facts confirmed by the adapter.
    public func consumeCurrentGrant(consoleUserID: UInt32, consoleSessionID: String,
                                   peer: DesktopLockedControlLocalPeer,
                                   nowMonotonicNanoseconds: UInt64) -> Bool {
        guard verifiesPeer(peer, .authorizationMechanism) else { return false }
        return consumeCurrentGrant(consoleUserID: consoleUserID,
                                   consoleSessionID: consoleSessionID,
                                   nowMonotonicNanoseconds: nowMonotonicNanoseconds,
                                   matching: { _ in true })
    }

    private func consumeCurrentGrant(consoleUserID: UInt32, consoleSessionID: String,
                                     nowMonotonicNanoseconds: UInt64,
                                     matching: (DesktopLockedControlGrant) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        expireArmedGrantIfNeeded(nowMonotonicNanoseconds)
        guard case .armed(let grant) = phase,
              matching(grant),
              grant.consoleUserID == consoleUserID,
              grant.consoleSessionID == consoleSessionID else { return false }
        phase = .transitionPending(grant)
        return true
    }

    /// Revocation before consumption makes any later Allow impossible. After
    /// consumption, the permit remains fenced until actual relock is confirmed.
    @discardableResult
    public func revoke(connectionID: UUID, leaseToken: UUID) -> DesktopLockedControlGrantRevokeResult {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .idle:
            return .settled
        case .armed(let grant):
            guard grant.connectionID == connectionID, grant.leaseToken == leaseToken else { return .scopeMismatch }
            phase = .idle
            return .settled
        case .transitionPending(let grant), .unlockedObserved(let grant):
            guard grant.connectionID == connectionID, grant.leaseToken == leaseToken else { return .scopeMismatch }
            return .awaitingOSLock
        }
    }

    /// Stop the IPC endpoint and synchronously remove any unconsumed permit.
    /// A consumed permit remains pending until the observed unlock and relock.
    @discardableResult
    public func revokeArmedGrant() -> DesktopLockedControlGrantRevokeResult {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .idle:
            return .settled
        case .armed:
            phase = .idle
            return .settled
        case .transitionPending, .unlockedObserved:
            return .awaitingOSLock
        }
    }

    /// Record the unlocked active console session after consuming a grant.
    /// An initial locked snapshot cannot settle a pending Allow transition.
    @discardableResult
    public func observeActualUnlock(connectionID: UUID, leaseToken: UUID,
                                    consoleUserID: UInt32, consoleSessionID: String,
                                    peer: DesktopLockedControlLocalPeer) -> Bool {
        guard verifiesPeer(peer, .controller) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard case .transitionPending(let grant) = phase,
              grant.matches(connectionID: connectionID, leaseToken: leaseToken,
                            consoleUserID: consoleUserID, consoleSessionID: consoleSessionID) else { return false }
        phase = .unlockedObserved(grant)
        return true
    }

    /// Clear the consumed fence only after an unlocked session was observed
    /// and a later snapshot confirms that this same console session is locked.
    @discardableResult
    public func confirmActualRelock(connectionID: UUID, leaseToken: UUID,
                                    consoleUserID: UInt32, consoleSessionID: String,
                                    peer: DesktopLockedControlLocalPeer) -> Bool {
        guard verifiesPeer(peer, .controller) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard case .unlockedObserved(let grant) = phase,
              grant.matches(connectionID: connectionID, leaseToken: leaseToken,
                            consoleUserID: consoleUserID, consoleSessionID: consoleSessionID) else { return false }
        phase = .idle
        return true
    }

    private func expireArmedGrantIfNeeded(_ nowMonotonicNanoseconds: UInt64) {
        guard case .armed(let grant) = phase,
              nowMonotonicNanoseconds >= grant.expiresAtMonotonicNanoseconds else { return }
        phase = .idle
    }
}
