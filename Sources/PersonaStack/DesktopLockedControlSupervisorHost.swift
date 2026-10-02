import Darwin
import Foundation
import PersonaStackCore

@MainActor
protocol DesktopLockedControlSupervisorDriving: AnyObject {
    var onStatusChange: (@MainActor (DesktopLockedControlSupervisor.Status) -> Void)? { get set }
    func begin(grant: DesktopLockedControlGrant, driverPID: Int32) async throws
    func end() async -> Bool
    func status() -> DesktopLockedControlSupervisor.Status
    func observe() async
}

extension DesktopLockedControlSupervisor: DesktopLockedControlSupervisorDriving {}

@MainActor
protocol DesktopLockedControlSupervisorHostTransport: AnyObject {
    var isClientConnected: Bool { get }
    var clientHeartbeatIsCurrent: Bool { get }
    func start(handler: @escaping DesktopCrashSupervisorControlIPCHandler,
               onOwnerLost: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Owns the supervisor protocol endpoint. Construction is inert. `start()`
/// only opens the authenticated local socket. A request arms session work later.
@MainActor
final class DesktopLockedControlSupervisorHost {
    private let supervisor: any DesktopLockedControlSupervisorDriving
    private let transport: any DesktopLockedControlSupervisorHostTransport
    private let leases: DesktopLockedControlSupervisorHostLeaseContext
    private let bridge: DesktopLockedControlSupervisorHostBridge
    private var isStarted = false

    init(supervisor: any DesktopLockedControlSupervisorDriving,
         transport: any DesktopLockedControlSupervisorHostTransport,
         leases: DesktopLockedControlSupervisorHostLeaseContext) {
        self.supervisor = supervisor
        self.transport = transport
        self.leases = leases
        bridge = DesktopLockedControlSupervisorHostBridge()
        installCallbacks()
    }

    func start() throws {
        guard !isStarted else { throw DesktopCrashSupervisorControlIPCError.alreadyConnected }
        try transport.start(handler: { [bridge] request in bridge.handle(request) },
                            onOwnerLost: { [bridge] in bridge.ownerLost() })
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        transport.stop()
        isStarted = false
    }

    /// Create one host for the login-agent process. Runtime authority arrives
    /// only through the signed app's scoped requests and fresh heartbeat.
    static func production(pinnedReleaseCertificate: Data) -> Self {
        let bridge = DesktopLockedControlSupervisorHostBridge()
        let transport = DesktopLockedControlSupervisorSocketTransport(pinnedReleaseCertificate: pinnedReleaseCertificate)
        let leases = DesktopLockedControlSupervisorHostLeaseContext(
            clientIsCurrent: { transport.isClientConnected && transport.clientHeartbeatIsCurrent },
            processIsAlive: Self.isProcessAlive)
        let supervisor = DesktopLockedControlSupervisor.production(
            pinnedReleaseCertificate: pinnedReleaseCertificate,
            leaseForGrant: { leases.lease(for: $0, driverPID: $1) },
            leaseIsAuthorized: { leases.isAuthorized($0) },
            clientHeartbeatIsCurrent: { transport.isClientConnected && transport.clientHeartbeatIsCurrent })
        return Self(supervisor: supervisor, transport: transport, leases: leases, bridge: bridge)
    }

    private init(supervisor: any DesktopLockedControlSupervisorDriving,
                 transport: any DesktopLockedControlSupervisorHostTransport,
                 leases: DesktopLockedControlSupervisorHostLeaseContext,
                 bridge: DesktopLockedControlSupervisorHostBridge) {
        self.supervisor = supervisor
        self.transport = transport
        self.leases = leases
        self.bridge = bridge
        installCallbacks()
    }

    private func installCallbacks() {
        let callbackBridge = bridge
        supervisor.onStatusChange = { [weak callbackBridge, weak leases] status in
            if status.state == .idle && !status.mayStillUnlock { leases?.clearAfterSupervisorIdle() }
            callbackBridge?.publish(status)
        }
        bridge.setEnqueue { [weak self] command in
            Task { @MainActor [weak self] in await self?.process(command) }
        }
    }

    private func process(_ command: DesktopLockedControlSupervisorHostBridge.Command) async {
        guard bridge.isCurrent(command) else { return }
        switch command.operation {
        case .arm:
            guard let grant = leases.activate(command.scope) else {
                bridge.complete(command, status: .init(result: .accepted, state: .idle, mayStillUnlock: false))
                return
            }
            do {
                try await supervisor.begin(grant: grant, driverPID: command.scope.ownedCuaPID)
                guard bridge.isCurrent(command) else { return }
                bridge.complete(command, status: Self.ipcStatus(supervisor.status()))
            } catch {
                guard bridge.isCurrent(command) else { return }
                let status = supervisor.status()
                bridge.complete(command, status: Self.ipcStatus(status))
                if status.state == .idle { leases.clear(command.scope) }
            }
        case .status:
            await supervisor.observe()
            guard bridge.isCurrent(command) else { return }
            bridge.complete(command, status: Self.ipcStatus(supervisor.status()))
        case .heartbeat:
            guard leases.isCurrent(command.scope) else {
                _ = await supervisor.end()
                bridge.complete(command, status: Self.ipcStatus(supervisor.status()))
                return
            }
            await supervisor.observe()
            guard bridge.isCurrent(command) else { return }
            bridge.complete(command, status: Self.ipcStatus(supervisor.status()))
        case .end, .ownerLost:
            let cleaned = await supervisor.end()
            guard bridge.isCurrent(command) else { return }
            let status = Self.ipcStatus(supervisor.status())
            if cleaned {
                leases.clear(command.scope)
                bridge.complete(command, status: status, clearLostScope: command.operation == .ownerLost)
            } else {
                bridge.complete(command, status: status)
            }
        }
    }

    private static func ipcStatus(_ status: DesktopLockedControlSupervisor.Status,
                                  result: DesktopCrashSupervisorControlStatus.Result = .accepted)
        -> DesktopCrashSupervisorControlStatus {
        let mapped: DesktopCrashSupervisorControlState = switch status.state {
        case .idle: .idle
        case .starting: .preparing
        case .controlling: .controlling
        case .restoring: .restoring
        case .needsAttention: .needsAttention
        }
        return DesktopCrashSupervisorControlStatus(result: result, state: mapped,
                                                   mayStillUnlock: status.mayStillUnlock)
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Maps the fixed IPC scope to one retained in-process lease. Re-resolving a
/// scope never extends its monotonic expiry or creates a replacement token.
@MainActor
final class DesktopLockedControlSupervisorHostLeaseContext {
    private let nowNanoseconds: @MainActor () -> UInt64
    private let continuousNow: @MainActor () -> ContinuousClock.Instant
    private let clientIsCurrent: @MainActor () -> Bool
    private let processIsAlive: @MainActor (Int32) -> Bool
    private var scope: DesktopCrashSupervisorControlIPCScope?
    private var retainedGrant: DesktopLockedControlGrant?
    private var retainedLease: DesktopLockedControlSession.Lease?

    init(nowNanoseconds: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         continuousNow: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         clientIsCurrent: @escaping @MainActor () -> Bool,
         processIsAlive: @escaping @MainActor (Int32) -> Bool) {
        self.nowNanoseconds = nowNanoseconds
        self.continuousNow = continuousNow
        self.clientIsCurrent = clientIsCurrent
        self.processIsAlive = processIsAlive
    }

    func activate(_ value: DesktopCrashSupervisorControlIPCScope) -> DesktopLockedControlGrant? {
        guard scope == nil, value.isValid else { return nil }
        let now = nowNanoseconds()
        guard value.expiresAtMonotonicNanoseconds > now,
              value.expiresAtMonotonicNanoseconds - now <= DesktopLockedControlGrantBroker.maximumGrantLifetimeNanoseconds,
              value.ownedCuaPID > 0, processIsAlive(value.ownedCuaPID), clientIsCurrent(),
              value.expiresAtMonotonicNanoseconds - now <= UInt64(Int64.max) else { return nil }
        let grant = DesktopLockedControlGrant(connectionID: value.connectionID,
                                              leaseToken: value.leaseToken,
                                              consoleUserID: value.consoleUserID,
                                              consoleSessionID: String(value.auditSessionID),
                                              expiresAtMonotonicNanoseconds: value.expiresAtMonotonicNanoseconds)
        let expiry = continuousNow() + .nanoseconds(Int64(value.expiresAtMonotonicNanoseconds - now))
        scope = value
        retainedGrant = grant
        retainedLease = DesktopLockedControlSession.Lease(connectionID: value.connectionID,
                                                          token: value.leaseToken, expires: expiry)
        return grant
    }

    func lease(for grant: DesktopLockedControlGrant, driverPID: Int32) -> DesktopLockedControlSession.Lease? {
        guard grant == retainedGrant, let scope, scope.ownedCuaPID == driverPID,
              isCurrent(scope), let retainedLease else { return nil }
        return retainedLease
    }

    func isAuthorized(_ lease: DesktopLockedControlSession.Lease) -> Bool {
        guard lease == retainedLease, let scope else { return false }
        return isCurrent(scope) && continuousNow() < lease.expires
    }

    func isCurrent(_ value: DesktopCrashSupervisorControlIPCScope) -> Bool {
        scope == value && nowNanoseconds() < value.expiresAtMonotonicNanoseconds &&
            clientIsCurrent() && processIsAlive(value.ownedCuaPID)
    }

    func clear(_ value: DesktopCrashSupervisorControlIPCScope) {
        guard scope == value else { return }
        clearAfterSupervisorIdle()
    }

    func clearAfterSupervisorIdle() {
        scope = nil
        retainedGrant = nil
        retainedLease = nil
    }
}

@MainActor
private final class DesktopLockedControlSupervisorSocketTransport: DesktopLockedControlSupervisorHostTransport {
    private let pinnedReleaseCertificate: Data
    private var server: DesktopCrashSupervisorControlIPCServer?

    init(pinnedReleaseCertificate: Data) {
        self.pinnedReleaseCertificate = pinnedReleaseCertificate
    }

    var isClientConnected: Bool { server?.isClientConnected == true }
    var clientHeartbeatIsCurrent: Bool { server?.clientHeartbeatIsCurrent == true }

    func start(handler: @escaping DesktopCrashSupervisorControlIPCHandler,
               onOwnerLost: @escaping @Sendable () -> Void) throws {
        guard server == nil else { throw DesktopCrashSupervisorControlIPCError.alreadyConnected }
        let server = DesktopCrashSupervisorControlIPCServer(
            pinnedReleaseCertificate: pinnedReleaseCertificate,
            handler: handler, onOwnerLost: onOwnerLost)
        try server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

/// Lock-protected synchronous IPC view. The socket callback never waits for
/// MainActor and never reads transport state while the server lock is held.
private final class DesktopLockedControlSupervisorHostBridge: @unchecked Sendable {
    enum Operation: Sendable { case arm, status, heartbeat, end, ownerLost }
    struct Command: Sendable {
        let operation: Operation
        let scope: DesktopCrashSupervisorControlIPCScope
        let generation: UUID
    }

    private let lock = NSLock()
    private var activeScope: DesktopCrashSupervisorControlIPCScope?
    private var generation = UUID()
    private var cachedStatus = DesktopCrashSupervisorControlStatus(result: .accepted, state: .idle,
                                                                    mayStillUnlock: false)
    private var lostOwner = false
    private var enqueue: (@Sendable (Command) -> Void)?

    func setEnqueue(_ value: @escaping @Sendable (Command) -> Void) {
        lock.lock(); defer { lock.unlock() }
        enqueue = value
    }

    func handle(_ request: DesktopCrashSupervisorControlIPCRequest) -> DesktopCrashSupervisorControlStatus {
        var command: Command?
        var enqueueCommand: (@Sendable (Command) -> Void)?
        var response: DesktopCrashSupervisorControlStatus
        lock.lock()
        switch request.operation {
        case .arm:
            guard activeScope == nil, cachedStatus.cleanupIsComplete else {
                response = Self.denied
                break
            }
            generation = UUID()
            activeScope = request.scope
            lostOwner = false
            cachedStatus = .init(result: .accepted, state: .preparing, mayStillUnlock: false)
            response = cachedStatus
            command = Command(operation: .arm, scope: request.scope, generation: generation)
        case .status, .heartbeat, .end:
            guard activeScope == request.scope else {
                response = Self.denied
                break
            }
            if cachedStatus.cleanupIsComplete {
                activeScope = nil
                lostOwner = false
                response = cachedStatus
                break
            }
            response = cachedStatus
            let operation: Operation
            switch request.operation {
            case .status: operation = .status
            case .heartbeat: operation = .heartbeat
            case .end:
                generation = UUID()
                operation = .end
                cachedStatus = .init(result: .accepted, state: .restoring,
                                     mayStillUnlock: cachedStatus.mayStillUnlock)
                response = cachedStatus
            case .arm: operation = .arm
            }
            command = Command(operation: operation, scope: request.scope, generation: generation)
        }
        if let command { enqueueCommand = enqueue }
        lock.unlock()
        if let command, let enqueueCommand { enqueueCommand(command) }
        return response
    }

    func ownerLost() {
        var command: Command?
        var enqueueCommand: (@Sendable (Command) -> Void)?
        lock.lock()
        if let scope = activeScope, !lostOwner {
            lostOwner = true
            if cachedStatus.cleanupIsComplete {
                activeScope = nil
                lostOwner = false
            } else {
                generation = UUID()
                cachedStatus = .init(result: .accepted, state: .restoring,
                                     mayStillUnlock: cachedStatus.mayStillUnlock)
                command = Command(operation: .ownerLost, scope: scope, generation: generation)
                enqueueCommand = enqueue
            }
        }
        lock.unlock()
        if let command, let enqueueCommand { enqueueCommand(command) }
    }

    func publish(_ value: DesktopLockedControlSupervisor.Status) {
        lock.lock(); defer { lock.unlock() }
        let state = Self.map(value.state)
        cachedStatus = DesktopCrashSupervisorControlStatus(result: .accepted, state: state,
                                                           mayStillUnlock: value.mayStillUnlock)
        if lostOwner && cachedStatus.cleanupIsComplete {
            activeScope = nil
            lostOwner = false
        }
    }

    func complete(_ command: Command, status: DesktopCrashSupervisorControlStatus,
                  clearLostScope: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard activeScope == command.scope, generation == command.generation else { return }
        cachedStatus = status
        if status.cleanupIsComplete && (clearLostScope || command.operation == .ownerLost) {
            activeScope = nil
            lostOwner = false
        }
    }

    func isCurrent(_ command: Command) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeScope == command.scope && generation == command.generation
    }

    private static var denied: DesktopCrashSupervisorControlStatus {
        .init(result: .denied, state: .unknown, mayStillUnlock: true)
    }

    private static func map(_ state: DesktopLockedControlSupervisor.State) -> DesktopCrashSupervisorControlState {
        switch state {
        case .idle: .idle
        case .starting: .preparing
        case .controlling: .controlling
        case .restoring: .restoring
        case .needsAttention: .needsAttention
        }
    }
}
