import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

@Test @MainActor
func desktopLockedControlHostReturnsPreparingThenCachedStateWithoutBlockingTransport() async throws {
    let supervisor = HostFakeSupervisor()
    let transport = HostFakeTransport()
    let leases = DesktopLockedControlSupervisorHostLeaseContext(
        nowNanoseconds: { 1 }, continuousNow: { .now }, clientIsCurrent: { transport.isClientConnected },
        processIsAlive: { $0 == 88 })
    let host = DesktopLockedControlSupervisorHost(supervisor: supervisor, transport: transport, leases: leases)
    #expect(!transport.started)
    try host.start()
    #expect(transport.started)

    let scope = hostIPCScope()
    let arm = try #require(transport.send(hostIPCRequest(1, .arm, scope: scope)))
    #expect(arm.result == .accepted && arm.state == .preparing)
    for _ in 0..<100 where !supervisor.beginEntered { await Task.yield() }
    #expect(supervisor.beginEntered)

    let preparing = try #require(transport.send(hostIPCRequest(2, .status, scope: scope)))
    #expect(preparing.state == .preparing)
    #expect(preparing.mayStillUnlock)
    supervisor.beginGate?.resume()
    supervisor.beginGate = nil
    for _ in 0..<100 where supervisor.state != .controlling { await Task.yield() }
    #expect(supervisor.state == .controlling)

    let ending = try #require(transport.send(hostIPCRequest(3, .end, scope: scope)))
    #expect(ending.state == .restoring)
    for _ in 0..<100 where supervisor.state != .idle { await Task.yield() }
    #expect(supervisor.state == .idle)
    let idle = try #require(transport.send(hostIPCRequest(4, .status, scope: scope)))
    #expect(idle.state == .idle)
}

@Test @MainActor
func desktopLockedControlHostOwnerLossFencesOldBeginBeforeNewArm() async throws {
    let supervisor = HostFakeSupervisor()
    let transport = HostFakeTransport()
    let leases = DesktopLockedControlSupervisorHostLeaseContext(
        nowNanoseconds: { 1 }, continuousNow: { .now }, clientIsCurrent: { transport.isClientConnected },
        processIsAlive: { $0 == 88 })
    let host = DesktopLockedControlSupervisorHost(supervisor: supervisor, transport: transport, leases: leases)
    try host.start()
    let first = hostIPCScope()
    #expect(transport.send(hostIPCRequest(1, .arm, scope: first))?.state == .preparing)
    for _ in 0..<100 where !supervisor.beginEntered { await Task.yield() }

    transport.loseOwner()
    let second = hostIPCScope(connection: UUID(), token: UUID())
    #expect(transport.send(hostIPCRequest(1, .arm, scope: second))?.result == .denied)
    for _ in 0..<100 where supervisor.endCount == 0 { await Task.yield() }
    #expect(supervisor.endCount == 1)

    supervisor.beginGate?.resume()
    supervisor.beginGate = nil
    for _ in 0..<100 where supervisor.state != .idle { await Task.yield() }
    #expect(supervisor.state == .idle)
    for _ in 0..<100 where !supervisor.beginReturned { await Task.yield() }
    #expect(supervisor.beginReturned)
    transport.reconnect()
    #expect(transport.send(hostIPCRequest(1, .arm, scope: second))?.state == .preparing)
    for _ in 0..<100 where supervisor.beginCount < 2 { await Task.yield() }
    #expect(supervisor.beginCount == 2)
    #expect(transport.send(hostIPCRequest(2, .end, scope: second))?.state == .restoring)
    supervisor.beginGate?.resume()
    supervisor.beginGate = nil
}

@MainActor
private final class HostFakeTransport: DesktopLockedControlSupervisorHostTransport {
    private var handler: DesktopCrashSupervisorControlIPCHandler?
    private var ownerLost: (@Sendable () -> Void)?
    private(set) var started = false
    private(set) var isClientConnected = false
    private(set) var clientHeartbeatIsCurrent = false

    func start(handler: @escaping DesktopCrashSupervisorControlIPCHandler,
               onOwnerLost: @escaping @Sendable () -> Void) throws {
        self.handler = handler
        ownerLost = onOwnerLost
        started = true
        isClientConnected = true
        clientHeartbeatIsCurrent = true
    }

    func stop() {
        isClientConnected = false
        clientHeartbeatIsCurrent = false
        ownerLost?()
    }

    func loseOwner() {
        isClientConnected = false
        clientHeartbeatIsCurrent = false
        ownerLost?()
    }

    func reconnect() {
        isClientConnected = true
        clientHeartbeatIsCurrent = true
    }

    func send(_ request: DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlStatus? {
        handler?(request)
    }
}

@MainActor
private final class HostFakeSupervisor: DesktopLockedControlSupervisorDriving {
    var onStatusChange: (@MainActor (DesktopLockedControlSupervisor.Status) -> Void)?
    private(set) var state: DesktopLockedControlSupervisor.State = .idle {
        didSet { onStatusChange?(status()) }
    }
    private(set) var mayStillUnlock = false
    private(set) var beginEntered = false
    private(set) var beginReturned = false
    private(set) var beginCount = 0
    private(set) var endCount = 0
    var beginGate: CheckedContinuation<Void, Never>?
    private var generation = 0

    func begin(grant: DesktopLockedControlGrant, driverPID: Int32) async throws {
        #expect(driverPID == 88)
        #expect(grant.consoleUserID == 501)
        beginCount += 1
        let run = generation
        mayStillUnlock = true
        state = .starting
        beginEntered = true
        await withCheckedContinuation { beginGate = $0 }
        guard run == generation else { beginReturned = true; throw CancellationError() }
        mayStillUnlock = false
        state = .controlling
        beginReturned = true
    }

    func end() async -> Bool {
        endCount += 1
        generation += 1
        state = .restoring
        mayStillUnlock = false
        state = .idle
        return true
    }

    func status() -> DesktopLockedControlSupervisor.Status {
        .init(state: state, mayStillUnlock: mayStillUnlock)
    }

    func observe() async {}
}

private func hostIPCScope(connection: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          token: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    -> DesktopCrashSupervisorControlIPCScope {
    .init(connectionID: connection, leaseToken: token, consoleUserID: 501, auditSessionID: 7,
          expiresAtMonotonicNanoseconds: 10_000_000_000, ownedCuaPID: 88)
}

private func hostIPCRequest(_ sequence: UInt64, _ operation: DesktopCrashSupervisorControlIPCOperation,
                            scope: DesktopCrashSupervisorControlIPCScope)
    -> DesktopCrashSupervisorControlIPCRequest {
    .init(sequence: sequence, operation: operation, scope: scope)
}

@Test @MainActor
func desktopLockedControlHostEndFencesAnArmStillQueuedOnMainActor() async throws {
    let supervisor = HostFakeSupervisor()
    let transport = HostFakeTransport()
    let leases = DesktopLockedControlSupervisorHostLeaseContext(
        nowNanoseconds: { 1 }, continuousNow: { .now }, clientIsCurrent: { transport.isClientConnected },
        processIsAlive: { $0 == 88 })
    let host = DesktopLockedControlSupervisorHost(supervisor: supervisor, transport: transport, leases: leases)
    try host.start()
    let scope = hostIPCScope()
    #expect(transport.send(hostIPCRequest(1, .arm, scope: scope))?.state == .preparing)
    #expect(transport.send(hostIPCRequest(2, .end, scope: scope))?.state == .restoring)
    for _ in 0..<100 where supervisor.endCount == 0 { await Task.yield() }
    #expect(supervisor.endCount == 1)
    #expect(supervisor.beginCount == 0)
    let settled = transport.send(hostIPCRequest(3, .status, scope: scope))
    #expect(settled?.result == .accepted && settled?.state == .idle)
}

@Test @MainActor
func desktopLockedControlHostIdleObservationReleasesLeaseContextForNextArm() async throws {
    let supervisor = HostFakeSupervisor()
    let transport = HostFakeTransport()
    let leases = DesktopLockedControlSupervisorHostLeaseContext(
        nowNanoseconds: { 1 }, continuousNow: { .now }, clientIsCurrent: { transport.isClientConnected },
        processIsAlive: { $0 == 88 })
    let host = DesktopLockedControlSupervisorHost(supervisor: supervisor, transport: transport, leases: leases)
    try host.start()
    let scope = hostIPCScope()
    #expect(transport.send(hostIPCRequest(1, .arm, scope: scope))?.state == .preparing)
    for _ in 0..<100 where !supervisor.beginEntered { await Task.yield() }
    supervisor.beginGate?.resume()
    supervisor.beginGate = nil
    for _ in 0..<100 where !supervisor.beginReturned { await Task.yield() }
    #expect(supervisor.state == .controlling)
    // The supervisor watchdog can finish independently of an app end request.
    #expect(await supervisor.end())
    #expect(transport.send(hostIPCRequest(2, .status, scope: scope))?.state == .idle)
    let next = hostIPCScope(connection: UUID(), token: UUID())
    #expect(transport.send(hostIPCRequest(3, .arm, scope: next))?.state == .preparing)
    for _ in 0..<100 where supervisor.beginCount < 2 { await Task.yield() }
    #expect(supervisor.beginCount == 2)
    supervisor.beginGate?.resume()
    supervisor.beginGate = nil
    #expect(transport.send(hostIPCRequest(4, .end, scope: next))?.state == .restoring)
}
