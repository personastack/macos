import Darwin
import Foundation
import LockedControlAudit

public enum DesktopCrashSupervisorControlState: UInt8, Equatable, Sendable {
    case unknown = 0
    case idle = 1
    case preparing = 2
    case controlling = 3
    case restoring = 4
    case needsAttention = 5
}

public struct DesktopCrashSupervisorControlStatus: Equatable, Sendable {
    public enum Result: UInt8, Equatable, Sendable { case accepted = 0, denied = 1 }
    public let result: Result
    public let state: DesktopCrashSupervisorControlState
    public let mayStillUnlock: Bool
    public var cleanupIsComplete: Bool { result == .accepted && state == .idle && !mayStillUnlock }

    public init(result: Result, state: DesktopCrashSupervisorControlState, mayStillUnlock: Bool) {
        self.result = result
        self.state = state
        self.mayStillUnlock = mayStillUnlock
    }
}

struct DesktopCrashSupervisorControlIdentity: Equatable, Sendable {
    public let consoleUserID: UInt32
    public let auditSessionID: UInt32

    public init(consoleUserID: UInt32, auditSessionID: UInt32) {
        self.consoleUserID = consoleUserID
        self.auditSessionID = auditSessionID
    }
}

struct DesktopCrashSupervisorControlPeer: Equatable, Sendable {
    let processID: Int32
    let effectiveUserID: UInt32
    let auditSessionID: UInt32
    let matchesPinnedReleaseCertificate: Bool

    init(processID: Int32, effectiveUserID: UInt32, auditSessionID: UInt32,
         matchesPinnedReleaseCertificate: Bool) {
        self.processID = processID
        self.effectiveUserID = effectiveUserID
        self.auditSessionID = auditSessionID
        self.matchesPinnedReleaseCertificate = matchesPinnedReleaseCertificate
    }
}

public enum DesktopCrashSupervisorControlIPCOperation: UInt8, Equatable, Sendable {
    case arm = 1
    case status = 2
    case end = 3
    case heartbeat = 4
}

public struct DesktopCrashSupervisorControlIPCScope: Equatable, Sendable {
    public let connectionID: UUID
    public let leaseToken: UUID
    public let consoleUserID: UInt32
    public let auditSessionID: UInt32
    public let expiresAtMonotonicNanoseconds: UInt64
    public let ownedCuaPID: Int32

    public init(connectionID: UUID, leaseToken: UUID, consoleUserID: UInt32,
                auditSessionID: UInt32, expiresAtMonotonicNanoseconds: UInt64,
                ownedCuaPID: Int32) {
        self.connectionID = connectionID
        self.leaseToken = leaseToken
        self.consoleUserID = consoleUserID
        self.auditSessionID = auditSessionID
        self.expiresAtMonotonicNanoseconds = expiresAtMonotonicNanoseconds
        self.ownedCuaPID = ownedCuaPID
    }

    public init(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) throws {
        guard let sessionID = UInt32(grant.consoleSessionID),
              String(sessionID) == grant.consoleSessionID else {
            throw DesktopCrashSupervisorControlIPCError.invalidScope
        }
        self.init(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                  consoleUserID: grant.consoleUserID, auditSessionID: sessionID,
                  expiresAtMonotonicNanoseconds: grant.expiresAtMonotonicNanoseconds,
                  ownedCuaPID: ownedCuaPID)
    }

    public var isValid: Bool {
        consoleUserID > 0 && auditSessionID > 0 && expiresAtMonotonicNanoseconds > 0 &&
            ownedCuaPID > 0 && connectionID != Self.zeroUUID && leaseToken != Self.zeroUUID
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

public struct DesktopCrashSupervisorControlIPCRequest: Equatable, Sendable {
    public let sequence: UInt64
    public let operation: DesktopCrashSupervisorControlIPCOperation
    public let scope: DesktopCrashSupervisorControlIPCScope

    public init(sequence: UInt64, operation: DesktopCrashSupervisorControlIPCOperation,
                scope: DesktopCrashSupervisorControlIPCScope) {
        self.sequence = sequence
        self.operation = operation
        self.scope = scope
    }
}

public struct DesktopCrashSupervisorControlIPCResponse: Equatable, Sendable {
    public let sequence: UInt64
    public let operation: DesktopCrashSupervisorControlIPCOperation
    public let status: DesktopCrashSupervisorControlStatus
}

public enum DesktopCrashSupervisorControlIPCError: Error, Equatable {
    case invalidScope
    case invalidFrame
    case unauthenticatedPeer
    case alreadyConnected
    case notConnected
    case noActiveGrant
    case staleScope
    case remoteDenied
    case uncertainOutcome
    case timedOut
    case invalidated
}

/// Exact-size bounded wire frames. Tokens stay on the authenticated local
/// connection and are never copied into logs or command responses.
public enum DesktopCrashSupervisorControlIPCCodec {
    public static let requestSize = 72
    public static let responseSize = 24
    public static let maximumFrameSize = 4096
    private static let requestMagic = Data([0x50, 0x53, 0x53, 0x43]) // PSSC
    private static let responseMagic = Data([0x50, 0x53, 0x53, 0x52]) // PSSR

    public static func encode(_ request: DesktopCrashSupervisorControlIPCRequest) throws -> Data {
        guard request.sequence > 0, request.scope.isValid else {
            throw DesktopCrashSupervisorControlIPCError.invalidScope
        }
        var data = requestMagic
        data.append(contentsOf: [1, request.operation.rawValue, 0, 0])
        data.appendBigEndian(request.sequence)
        data.appendUUID(request.scope.connectionID)
        data.appendUUID(request.scope.leaseToken)
        data.appendBigEndian(request.scope.consoleUserID)
        data.appendBigEndian(request.scope.auditSessionID)
        data.appendBigEndian(request.scope.expiresAtMonotonicNanoseconds)
        data.appendBigEndian(UInt32(bitPattern: request.scope.ownedCuaPID))
        data.append(contentsOf: [0, 0, 0, 0])
        guard data.count == requestSize, data.count <= maximumFrameSize else {
            throw DesktopCrashSupervisorControlIPCError.invalidFrame
        }
        return data
    }

    public static func decodeRequest(_ data: Data) -> DesktopCrashSupervisorControlIPCRequest? {
        guard data.count == requestSize, data.count <= maximumFrameSize,
              data.prefix(4) == requestMagic,
              data[4] == 1, data[6] == 0, data[7] == 0,
              data[68] == 0, data[69] == 0, data[70] == 0, data[71] == 0,
              let operation = DesktopCrashSupervisorControlIPCOperation(rawValue: data[5]),
              let sequence = data.readBigEndian(UInt64.self, at: 8), sequence > 0,
              let connectionID = data.readUUID(at: 16),
              let leaseToken = data.readUUID(at: 32),
              let consoleUserID = data.readBigEndian(UInt32.self, at: 48),
              let auditSessionID = data.readBigEndian(UInt32.self, at: 52),
              let expiry = data.readBigEndian(UInt64.self, at: 56),
              let cuaPID = data.readBigEndian(UInt32.self, at: 64) else { return nil }
        let scope = DesktopCrashSupervisorControlIPCScope(connectionID: connectionID,
                                                           leaseToken: leaseToken,
                                                           consoleUserID: consoleUserID,
                                                           auditSessionID: auditSessionID,
                                                           expiresAtMonotonicNanoseconds: expiry,
                                                           ownedCuaPID: Int32(bitPattern: cuaPID))
        guard scope.isValid else { return nil }
        return DesktopCrashSupervisorControlIPCRequest(sequence: sequence,
                                                       operation: operation,
                                                       scope: scope)
    }

    public static func encode(_ response: DesktopCrashSupervisorControlIPCResponse) -> Data {
        var data = responseMagic
        data.append(contentsOf: [1, response.operation.rawValue, response.status.result.rawValue,
                                 response.status.state.rawValue])
        data.appendBigEndian(response.sequence)
        data.append(response.status.mayStillUnlock ? 1 : 0)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0])
        return data
    }

    public static func decodeResponse(_ data: Data, matching request: DesktopCrashSupervisorControlIPCRequest)
        -> DesktopCrashSupervisorControlIPCResponse? {
        guard data.count == responseSize, data.count <= maximumFrameSize,
              data.prefix(4) == responseMagic,
              data[4] == 1, data[5] == request.operation.rawValue,
              let result = DesktopCrashSupervisorControlStatus.Result(rawValue: data[6]),
              let state = DesktopCrashSupervisorControlState(rawValue: data[7]),
              let sequence = data.readBigEndian(UInt64.self, at: 8), sequence == request.sequence,
              data[16] <= 1,
              data[17] == 0, data[18] == 0, data[19] == 0,
              data[20] == 0, data[21] == 0, data[22] == 0, data[23] == 0 else { return nil }
        let status = DesktopCrashSupervisorControlStatus(result: result, state: state,
                                                          mayStillUnlock: data[16] == 1)
        return DesktopCrashSupervisorControlIPCResponse(sequence: sequence,
                                                        operation: request.operation,
                                                        status: status)
    }
}

public typealias DesktopCrashSupervisorControlIPCHandler =
    @Sendable (DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlStatus

/// Stateful request gate used by the socket server and deterministic tests.
final class DesktopCrashSupervisorControlIPCDispatcher {
    typealias Handler = (DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlStatus
    private let now: () -> UInt64
    private let handler: Handler
    private(set) var activeScope: DesktopCrashSupervisorControlIPCScope?
    private(set) var lastSequence: UInt64 = 0
    static let maximumGrantLifetimeNanoseconds: UInt64 = 30 * 60 * 1_000_000_000

    init(now: @escaping () -> UInt64, handler: @escaping Handler) {
        self.now = now
        self.handler = handler
    }

    func process(_ request: DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlIPCResponse? {
        guard lastSequence < UInt64.max,
              request.sequence == lastSequence + 1, request.sequence > lastSequence,
              request.scope.isValid else { return nil }
        lastSequence = request.sequence
        let scope = request.scope
        let response: DesktopCrashSupervisorControlStatus
        switch request.operation {
        case .arm:
            let currentTime = now()
            guard activeScope == nil,
                  scope.expiresAtMonotonicNanoseconds > currentTime,
                  scope.expiresAtMonotonicNanoseconds - currentTime <= Self.maximumGrantLifetimeNanoseconds else {
                return denied(request)
            }
            response = handler(request)
            if response.result == .accepted { activeScope = scope }
        case .status, .heartbeat:
            guard activeScope == scope else { return denied(request) }
            response = handler(request)
            if response.cleanupIsComplete { activeScope = nil }
        case .end:
            guard activeScope == scope else { return denied(request) }
            response = handler(request)
            if response.cleanupIsComplete { activeScope = nil }
        }
        return DesktopCrashSupervisorControlIPCResponse(sequence: request.sequence,
                                                        operation: request.operation,
                                                        status: response)
    }

    private func denied(_ request: DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlIPCResponse {
        let status = DesktopCrashSupervisorControlStatus(result: .denied, state: .unknown,
                                                          mayStillUnlock: true)
        return DesktopCrashSupervisorControlIPCResponse(sequence: request.sequence,
                                                        operation: request.operation,
                                                        status: status)
    }
}

enum DesktopCrashSupervisorControlIPCAuthentication {
    static func authenticates(_ peer: DesktopCrashSupervisorControlPeer,
                              against identity: DesktopCrashSupervisorControlIdentity) -> Bool {
        peer.processID > 0 && identity.consoleUserID > 0 && identity.auditSessionID > 0 &&
            peer.matchesPinnedReleaseCertificate &&
            peer.effectiveUserID == identity.consoleUserID &&
            peer.auditSessionID == identity.auditSessionID
    }
}

private extension Data {
    mutating func appendUUID(_ uuid: UUID) { Swift.withUnsafeBytes(of: uuid.uuid) { append(contentsOf: $0) } }

    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= count else { return nil }
        var value: T = 0
        for byte in self[offset..<(offset + MemoryLayout<T>.size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }

    func readUUID(at offset: Int) -> UUID? {
        guard offset >= 0, offset + 16 <= count else { return nil }
        let bytes = Array(self[offset..<(offset + 16)])
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
