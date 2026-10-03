import Foundation
import Testing
import Darwin
@testable import PersonaStackCore

private func supervisorIPCScope(expiry: UInt64 = 10_000, pid: Int32 = 88) -> DesktopCrashSupervisorControlIPCScope {
    DesktopCrashSupervisorControlIPCScope(
        connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        leaseToken: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        consoleUserID: 501, auditSessionID: 7,
        expiresAtMonotonicNanoseconds: expiry, ownedCuaPID: pid
    )
}

private func supervisorIPCRequest(_ sequence: UInt64 = 1,
                                  _ operation: DesktopCrashSupervisorControlIPCOperation = .arm,
                                  scope: DesktopCrashSupervisorControlIPCScope = supervisorIPCScope())
    -> DesktopCrashSupervisorControlIPCRequest {
    DesktopCrashSupervisorControlIPCRequest(sequence: sequence, operation: operation, scope: scope)
}

@Test func desktopLockedSupervisorIPCFixedFramesRoundTripAndRejectMalformedBytes() throws {
    let scope = supervisorIPCScope()
    let request = supervisorIPCRequest(5, .heartbeat, scope: scope)
    let bytes = try DesktopCrashSupervisorControlIPCCodec.encode(request)
    #expect(bytes.count == DesktopCrashSupervisorControlIPCCodec.requestSize)
    #expect(bytes.count <= DesktopCrashSupervisorControlIPCCodec.maximumFrameSize)
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeRequest(bytes) == request)
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeRequest(Data(bytes.dropLast())) == nil)

    var malformed = bytes
    malformed[6] = 1
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeRequest(malformed) == nil)
    malformed = bytes
    malformed[5] = 99
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeRequest(malformed) == nil)

    let response = DesktopCrashSupervisorControlIPCResponse(
        sequence: request.sequence, operation: request.operation,
        status: DesktopCrashSupervisorControlStatus(result: .accepted, state: .controlling,
                                                     mayStillUnlock: false)
    )
    let responseBytes = DesktopCrashSupervisorControlIPCCodec.encode(response)
    #expect(responseBytes.count == DesktopCrashSupervisorControlIPCCodec.responseSize)
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeResponse(responseBytes, matching: request) == response)
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeResponse(responseBytes,
                                                                  matching: supervisorIPCRequest(6, .heartbeat)) == nil)
    malformed = responseBytes
    malformed[17] = 1
    #expect(DesktopCrashSupervisorControlIPCCodec.decodeResponse(malformed, matching: request) == nil)
}

@Test func desktopLockedSupervisorIPCFailsSilentAndPartialFramesByDeadline() throws {
    #expect(DesktopCrashSupervisorControlIPCServer.requestFrameTimeoutNanoseconds == 5_000_000_000)
    #expect(DesktopCrashSupervisorControlIPCServer.requestFrameDeadline(startingAt: 100) == 5_000_000_100)
    #expect(DesktopCrashSupervisorControlIPCServer.requestFrameDeadline(startingAt: .max) == nil)

    for sendPartialByte in [false, true] {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let reader = descriptors[0]
        let writer = descriptors[1]
        defer {
            Darwin.close(reader)
            Darwin.close(writer)
        }
        if sendPartialByte {
            var byte: UInt8 = 0
            #expect(Darwin.write(writer, &byte, 1) == 1)
        }

        let started = ContinuousClock.now
        let deadline = try #require(DesktopCrashSupervisorControlIPCServer.requestFrameDeadline(
            startingAt: DispatchTime.now().uptimeNanoseconds, timeoutNanoseconds: 50_000_000
        ))
        #expect(DesktopCrashSupervisorControlIPCServer.readExactly(
            reader, count: DesktopCrashSupervisorControlIPCCodec.requestSize, deadline: deadline
        ) == nil)
        #expect(started.duration(to: .now) < .seconds(2))
    }
}

@Test func desktopLockedSupervisorIPCPeerMustMatchPinnedSignatureUIDAndAuditSession() {
    let expected = DesktopCrashSupervisorControlIdentity(consoleUserID: 501, auditSessionID: 7)
    let trusted = DesktopCrashSupervisorControlPeer(processID: 44, effectiveUserID: 501,
                                                     auditSessionID: 7,
                                                     matchesPinnedReleaseCertificate: true)
    #expect(DesktopCrashSupervisorControlIPCAuthentication.authenticates(trusted, against: expected))
    #expect(!DesktopCrashSupervisorControlIPCAuthentication.authenticates(
        DesktopCrashSupervisorControlPeer(processID: 44, effectiveUserID: 502, auditSessionID: 7,
                                          matchesPinnedReleaseCertificate: true), against: expected
    ))
    #expect(!DesktopCrashSupervisorControlIPCAuthentication.authenticates(
        DesktopCrashSupervisorControlPeer(processID: 44, effectiveUserID: 501, auditSessionID: 8,
                                          matchesPinnedReleaseCertificate: true), against: expected
    ))
    #expect(!DesktopCrashSupervisorControlIPCAuthentication.authenticates(
        DesktopCrashSupervisorControlPeer(processID: 44, effectiveUserID: 501, auditSessionID: 7,
                                          matchesPinnedReleaseCertificate: false), against: expected
    ))
    #expect(!DesktopCrashSupervisorControlIPCAuthentication.authenticates(
        DesktopCrashSupervisorControlPeer(processID: 0, effectiveUserID: 501, auditSessionID: 7,
                                          matchesPinnedReleaseCertificate: true), against: expected
    ))
}

@Test func desktopLockedSupervisorIPCDispatchBindsScopeSequencesAndCleanup() {
    var now: UInt64 = 1
    var calls: [DesktopCrashSupervisorControlIPCOperation] = []
    let dispatcher = DesktopCrashSupervisorControlIPCDispatcher(now: { now }) { request in
        calls.append(request.operation)
        let state: DesktopCrashSupervisorControlState
        switch request.operation {
        case .arm, .heartbeat: state = .preparing
        case .status: state = .needsAttention
        case .end: state = .restoring
        }
        return DesktopCrashSupervisorControlStatus(result: .accepted, state: state,
                                                    mayStillUnlock: state == .preparing)
    }
    let scope = supervisorIPCScope()
    let arm = dispatcher.process(supervisorIPCRequest(1, .arm, scope: scope))
    #expect(arm?.status.result == .accepted)
    #expect(dispatcher.activeScope == scope)

    let wrongScope = supervisorIPCScope(pid: 89)
    let denied = dispatcher.process(supervisorIPCRequest(2, .heartbeat, scope: wrongScope))
    #expect(denied?.status.result == .denied)
    #expect(calls == [.arm])

    let heartbeat = dispatcher.process(supervisorIPCRequest(3, .heartbeat, scope: scope))
    #expect(heartbeat?.status.state == .preparing)
    #expect(dispatcher.process(supervisorIPCRequest(3, .heartbeat, scope: scope)) == nil)
    #expect(calls == [.arm, .heartbeat])

    let end = dispatcher.process(supervisorIPCRequest(4, .end, scope: scope))
    #expect(end?.status.state == .restoring)
    #expect(dispatcher.activeScope == scope)
    let status = dispatcher.process(supervisorIPCRequest(5, .status, scope: scope))
    #expect(status?.status.state == .needsAttention)
    #expect(dispatcher.activeScope == scope)
}

@Test func desktopLockedSupervisorIPCDispatchRejectsExpiredOrOverlongGrants() {
    var handlerCalls = 0
    let now: UInt64 = 100
    let dispatcher = DesktopCrashSupervisorControlIPCDispatcher(now: { now }) { _ in
        handlerCalls += 1
        return DesktopCrashSupervisorControlStatus(result: .accepted, state: .preparing,
                                                    mayStillUnlock: true)
    }
    let expired = dispatcher.process(supervisorIPCRequest(1, .arm, scope: supervisorIPCScope(expiry: 100)))
    #expect(expired?.status.result == .denied)
    let tooLong = dispatcher.process(supervisorIPCRequest(
        2, .arm, scope: supervisorIPCScope(expiry: now + DesktopCrashSupervisorControlIPCDispatcher.maximumGrantLifetimeNanoseconds + 1)
    ))
    #expect(tooLong?.status.result == .denied)
    #expect(handlerCalls == 0)
    #expect(dispatcher.activeScope == nil)
}

@Test func desktopLockedSupervisorIPCReleasesScopeOnlyAfterIdleReadback() {
    let dispatcher = DesktopCrashSupervisorControlIPCDispatcher(now: { 1 }) { request in
        let state: DesktopCrashSupervisorControlState
        switch request.operation {
        case .arm: state = .preparing
        case .end: state = .restoring
        case .status: state = .idle
        case .heartbeat: state = .controlling
        }
        return DesktopCrashSupervisorControlStatus(result: .accepted, state: state,
                                                    mayStillUnlock: state == .preparing || state == .restoring)
    }
    let firstScope = supervisorIPCScope()
    #expect(dispatcher.process(supervisorIPCRequest(1, .arm, scope: firstScope))?.status.state == .preparing)
    #expect(dispatcher.process(supervisorIPCRequest(2, .end, scope: firstScope))?.status.state == .restoring)
    #expect(dispatcher.activeScope == firstScope)
    #expect(dispatcher.process(supervisorIPCRequest(3, .status, scope: firstScope))?.status.state == .idle)
    #expect(dispatcher.activeScope == nil)

    let nextScope = supervisorIPCScope(expiry: 20_000, pid: 89)
    #expect(dispatcher.process(supervisorIPCRequest(4, .arm, scope: nextScope))?.status.state == .preparing)
    #expect(dispatcher.activeScope == nextScope)
}

@Test func desktopLockedSupervisorIPCIdleCannotReleaseAnUnsettledGrant() {
    let dispatcher = DesktopCrashSupervisorControlIPCDispatcher(now: { 1 }) { request in
        .init(result: .accepted, state: request.operation == .arm ? .preparing : .idle,
              mayStillUnlock: true)
    }
    let scope = supervisorIPCScope()
    #expect(dispatcher.process(supervisorIPCRequest(1, .arm, scope: scope))?.status.result == .accepted)
    let result = dispatcher.process(supervisorIPCRequest(2, .end, scope: scope))
    #expect(result?.status.cleanupIsComplete == false)
    #expect(dispatcher.activeScope == scope)
    #expect(dispatcher.process(supervisorIPCRequest(3, .arm, scope: supervisorIPCScope(pid: 89)))?.status.result == .denied)
    #expect(!DesktopCrashSupervisorControlStatus(result: .denied, state: .idle, mayStillUnlock: false).cleanupIsComplete)
}
