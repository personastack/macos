import Foundation
import PersonaStackCore

@MainActor
protocol DesktopLockedControlRuntimeTransport: AnyObject {
    var onConnectionLost: (@MainActor @Sendable () -> Void)? { get set }
    func connect() async throws
    func begin(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus
    func status() async throws -> DesktopCrashSupervisorControlStatus
    func heartbeat(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus
    func end() async throws -> DesktopCrashSupervisorControlStatus
    func invalidate()
}

/// Bridges the authenticated local supervisor socket to the current executor
/// lease. Construction is inert. Runtime wiring must explicitly call begin.
@MainActor
final class DesktopLockedControlRuntimeController {
    enum State: Equatable { case idle, preparing, controlling, recovering, stopping, needsAttention }
    enum Failure: Error, Equatable { case invalidScope, unavailable, notControlling }

    struct Inputs {
        let lease: DesktopControlCommandExecutor.LeaseSnapshot?
        let connectionID: UUID?
        let console: DesktopLockedControlSupervisor.Console
        let consentGranted: Bool
        let driverPID: Int32
        let guiReady: Bool
    }

    struct Operations {
        var inputs: @MainActor () -> Inputs
        var actualSessionIsUnlocked: @MainActor () -> Bool
        var prepareGUI: @MainActor (DesktopControlCommandExecutor.LeaseSnapshot, UUID, Int32) async throws -> Bool
        var now: @MainActor () -> ContinuousClock.Instant
        var monotonicNowNanoseconds: @MainActor () -> UInt64
        var sleep: @MainActor (Duration) async throws -> Void
    }

    private struct LeaseScope: Equatable {
        let token: UUID
        let installationID: String
        let workspaceID: String
        let configID: String
        let personaID: String
        let runID: String
        let generation: Int64
        let configVersion: Int64
        let hardExpires: ContinuousClock.Instant

        init(_ lease: DesktopControlCommandExecutor.LeaseSnapshot) {
            token = lease.token
            installationID = lease.installationID
            workspaceID = lease.workspaceID
            configID = lease.configID
            personaID = lease.personaID
            runID = lease.runID
            generation = lease.generation
            configVersion = lease.configVersion
            hardExpires = lease.hardExpires
        }

        func matches(_ lease: DesktopControlCommandExecutor.LeaseSnapshot) -> Bool {
            self == LeaseScope(lease)
        }
    }

    private struct ActiveScope {
        let leaseSnapshot: DesktopControlCommandExecutor.LeaseSnapshot
        let lease: LeaseScope
        let connectionID: UUID
        let consoleUserID: UInt32
        let consoleSessionID: String
        let driverPID: Int32
        let grant: DesktopLockedControlGrant
    }

    private let transportFactory: @MainActor () -> any DesktopLockedControlRuntimeTransport
    private let operations: Operations
    private var transport: (any DesktopLockedControlRuntimeTransport)?
    private var activeScope: ActiveScope?
    private var heartbeatTask: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var cleanupID: UUID?
    private var beginRequestInFlight = false
    private var mayHaveRemoteGrant = false
    private var generation = UUID()
    private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    var onStateChange: (@MainActor (State) -> Void)?

    init(transportFactory: @escaping @MainActor () -> any DesktopLockedControlRuntimeTransport,
         operations: Operations) {
        self.transportFactory = transportFactory
        self.operations = operations
    }

    var permitsExecution: Bool {
        if state == .controlling, let scope = activeScope,
           isCurrent(scope, requiresUnlocked: false, requiresGUI: false) {
            // The supervisor owns rearming after a verified ordinary lock.
            // Never turn an idle/takeover status into a fresh grant here.
            state = .recovering
            return false
        }
        guard state == .controlling, let scope = activeScope,
              isCurrent(scope, requiresUnlocked: true, requiresGUI: true) else {
            if state == .controlling { requestStop() }
            return false
        }
        return true
    }

    /// Fence GUI immediately on the runtime's lock event even if the supervisor
    /// completes the unlock before the next heartbeat samples the console.
    func observeOrdinaryLock() {
        if state == .controlling { state = .recovering }
    }

    func begin() async throws {
        try Task.checkCancellation()
        guard state == .idle, cleanupTask == nil else { throw Failure.unavailable }
        let inputs = operations.inputs()
        guard let scope = makeScope(inputs), isCurrent(scope, requiresUnlocked: false, requiresGUI: false) else {
            throw Failure.invalidScope
        }

        generation = UUID()
        let run = generation
        let client = transportFactory()
        transport = client
        activeScope = scope
        client.onConnectionLost = { [weak self] in self?.connectionLost(run: run) }
        state = .preparing

        do {
            beginRequestInFlight = true
            try await client.connect()
            beginRequestInFlight = false
            try Task.checkCancellation()
            try requireCurrent(run, scope, requiresUnlocked: false, requiresGUI: false)

            beginRequestInFlight = true
            mayHaveRemoteGrant = true
            let result: DesktopCrashSupervisorControlStatus
            do {
                result = try await client.begin(grant: scope.grant, ownedCuaPID: scope.driverPID)
                beginRequestInFlight = false
            } catch {
                beginRequestInFlight = false
                throw error
            }
            try Task.checkCancellation()
            try requireCurrent(run, scope, requiresUnlocked: true, requiresGUI: false)
            guard isControlling(result) else { throw Failure.notControlling }

            startHeartbeat(run: run)
            let guiReady = try await operations.prepareGUI(scope.leaseSnapshot, scope.connectionID, scope.driverPID)
            try Task.checkCancellation()
            try requireCurrent(run, scope, requiresUnlocked: true, requiresGUI: false)
            guard guiReady, operations.inputs().guiReady else { throw Failure.unavailable }

            guard isCurrent(run, scope, requiresUnlocked: true, requiresGUI: true) else {
                throw Failure.invalidScope
            }
            state = .controlling
        } catch {
            guard generation == run else { throw error }
            _ = await stop()
            throw error
        }
    }

    /// Stops admission synchronously, then asks the supervisor to revoke and
    /// complete lock/privacy cleanup. Repeated callers share the same cleanup.
    @discardableResult
    func stop() async -> Bool {
        if let cleanupTask { return await cleanupTask.value }
        guard state != .idle else { return true }
        if beginRequestInFlight || state == .preparing {
            generation = UUID()
            state = .stopping
            heartbeatTask?.cancel()
            heartbeatTask = nil
            transport?.invalidate()
            transport = nil
            if mayHaveRemoteGrant {
                state = .needsAttention
                return false
            }
            activeScope = nil
            state = .idle
            return true
        }
        let task = beginCleanup()
        let cleanupID = self.cleanupID
        let settled = await task.value
        if self.cleanupID == cleanupID {
            self.cleanupTask = nil
            self.cleanupID = nil
        }
        return settled
    }

    /// Runs one bounded status heartbeat. The watchdog calls this every two
    /// seconds. It is also the deterministic recovery seam for source tests.
    func observeNow() async {
        guard state == .controlling || state == .preparing || state == .recovering,
              let scope = activeScope, let client = transport else { return }
        let run = generation
        if state == .controlling, isCurrent(scope, requiresUnlocked: false, requiresGUI: false) {
            state = .recovering
        }
        let recovering = state == .recovering
        let unlocked = operations.inputs().console.lock == .unlocked
        guard isCurrent(run, scope, requiresUnlocked: recovering ? unlocked : true,
                        requiresGUI: state == .controlling) else {
            _ = await stop()
            return
        }
        do {
            let status = try await client.heartbeat(grant: scope.grant, ownedCuaPID: scope.driverPID)
            try Task.checkCancellation()
            guard generation == run else { return }
            // A lock can arrive while the heartbeat is in flight. Use the
            // current state and scope, not the state sampled before awaiting.
            if state == .controlling,
               (status.result == .accepted && status.state == .preparing
                || isCurrent(scope, requiresUnlocked: false, requiresGUI: false)) {
                state = .recovering
            }
            if state == .recovering {
                try await observeRecovery(status, run: run, scope: scope)
            } else {
                try requireCurrent(run, scope, requiresUnlocked: true, requiresGUI: state == .controlling)
                guard isControlling(status) else { throw Failure.notControlling }
            }
        } catch {
            guard generation == run else { return }
            _ = await stop()
        }
    }

    private func observeRecovery(_ status: DesktopCrashSupervisorControlStatus,
                                 run: UUID, scope: ActiveScope) async throws {
        let unlocked = operations.inputs().console.lock == .unlocked
        try requireCurrent(run, scope, requiresUnlocked: unlocked, requiresGUI: false)
        guard status.result == .accepted else { throw Failure.unavailable }
        if status.state == .preparing { return }
        guard isControlling(status) else { throw Failure.notControlling }
        // A controlling reply may predate the just-observed lock. Keep GUI
        // fenced until the next supervisor observation confirms recovery.
        guard unlocked else { return }
        let ready: Bool
        do {
            ready = try await operations.prepareGUI(scope.leaseSnapshot, scope.connectionID, scope.driverPID)
        } catch {
            // Another ordinary lock during the read-only readiness probe keeps
            // the same lease suspended. Input operations are never replayed.
            if isCurrent(run, scope, requiresUnlocked: false, requiresGUI: false) { return }
            throw error
        }
        if isCurrent(run, scope, requiresUnlocked: false, requiresGUI: false) { return }
        try requireCurrent(run, scope, requiresUnlocked: true, requiresGUI: true)
        guard ready else { throw Failure.unavailable }
        state = .controlling
    }

    private func startHeartbeat(run: UUID) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.generation == run,
                  (self.state == .controlling || self.state == .preparing || self.state == .recovering) {
                do { try await self.operations.sleep(.seconds(2)) }
                catch { break }
                guard !Task.isCancelled, self.generation == run else { break }
                await self.observeNow()
            }
            if self?.generation == run { self?.heartbeatTask = nil }
        }
    }

    private func connectionLost(run: UUID) {
        guard generation == run, state != .idle, state != .stopping else { return }
        generation = UUID()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        transport?.invalidate()
        transport = nil
        state = .needsAttention
    }

    /// Drops execution authority before the caller yields to async cleanup.
    func requestStop() {
        if state == .preparing {
            generation = UUID()
            heartbeatTask?.cancel()
            heartbeatTask = nil
            transport?.invalidate()
            transport = nil
            state = mayHaveRemoteGrant ? .needsAttention : .idle
            return
        }
        guard state == .controlling || state == .recovering else { return }
        let task = beginCleanup()
        let cleanupID = self.cleanupID
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self, self.cleanupID == cleanupID else { return }
            self.cleanupTask = nil
            self.cleanupID = nil
        }
    }

    private func beginCleanup() -> Task<Bool, Never> {
        if let cleanupTask { return cleanupTask }
        generation = UUID()
        state = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let id = UUID()
        cleanupID = id
        let run = generation
        let task = Task { @MainActor in await self.finish(run: run, sendEnd: true) }
        cleanupTask = task
        return task
    }

    private func finish(run: UUID, sendEnd: Bool) async -> Bool {
        guard generation == run, state == .stopping else { return false }
        state = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guard let client = transport else {
            guard !mayHaveRemoteGrant else {
                state = .needsAttention
                return false
            }
            activeScope = nil
            state = .idle
            return true
        }

        var settled = false
        if sendEnd, activeScope != nil {
            do {
                let result = try await client.end()
                settled = result.cleanupIsComplete
            } catch {
                settled = false
            }
        }
        guard generation == run, state == .stopping else { return false }
        client.invalidate()
        transport = nil
        if settled {
            activeScope = nil
            mayHaveRemoteGrant = false
            state = .idle
        } else {
            state = .needsAttention
        }
        return settled
    }

    private func makeScope(_ inputs: Inputs) -> ActiveScope? {
        guard let lease = inputs.lease, let connectionID = inputs.connectionID,
              inputs.consentGranted, inputs.driverPID > 0,
              inputs.console.lock == .locked, inputs.console.userID > 0,
              let sessionID = UInt32(inputs.console.sessionID),
              String(sessionID) == inputs.console.sessionID,
              lease.expires > operations.now(), lease.hardExpires > operations.now(),
              let expiry = monotonicExpiry(for: lease.hardExpires) else { return nil }
        let grant = DesktopLockedControlGrant(connectionID: connectionID, leaseToken: lease.token,
            consoleUserID: inputs.console.userID, consoleSessionID: inputs.console.sessionID,
            expiresAtMonotonicNanoseconds: expiry)
        return ActiveScope(leaseSnapshot: lease, lease: LeaseScope(lease), connectionID: connectionID,
            consoleUserID: inputs.console.userID, consoleSessionID: inputs.console.sessionID,
            driverPID: inputs.driverPID, grant: grant)
    }

    private func monotonicExpiry(for hardExpires: ContinuousClock.Instant) -> UInt64? {
        let remaining = operations.now().duration(to: hardExpires)
        guard remaining > .zero else { return nil }
        let components = remaining.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return nil }
        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        let (wholeNanoseconds, secondsOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let fractionNanoseconds = attoseconds / 1_000_000_000
        let (delta, fractionOverflow) = wholeNanoseconds.addingReportingOverflow(fractionNanoseconds)
        let maxLifetime = DesktopLockedControlGrantBroker.maximumGrantLifetimeNanoseconds
        guard !secondsOverflow, !fractionOverflow, delta > 0, delta <= maxLifetime else { return nil }
        let (deadline, overflow) = operations.monotonicNowNanoseconds().addingReportingOverflow(delta)
        return overflow ? nil : deadline
    }

    private func isCurrent(_ run: UUID, _ scope: ActiveScope,
                           requiresUnlocked: Bool, requiresGUI: Bool) -> Bool {
        generation == run && state != .stopping && isCurrent(scope,
            requiresUnlocked: requiresUnlocked, requiresGUI: requiresGUI)
    }

    private func isCurrent(_ scope: ActiveScope, requiresUnlocked: Bool, requiresGUI: Bool) -> Bool {
        let inputs = operations.inputs()
        guard let lease = inputs.lease, scope.lease.matches(lease),
              lease.expires > operations.now(), lease.hardExpires > operations.now(),
              inputs.connectionID == scope.connectionID, inputs.consentGranted,
              inputs.driverPID == scope.driverPID,
              inputs.console.userID == scope.consoleUserID,
              inputs.console.sessionID == scope.consoleSessionID else { return false }
        if requiresUnlocked {
            guard inputs.console.lock == .unlocked, operations.actualSessionIsUnlocked() else { return false }
        } else if inputs.console.lock != .locked {
            return false
        }
        return !requiresGUI || inputs.guiReady
    }

    private func requireCurrent(_ run: UUID, _ scope: ActiveScope,
                               requiresUnlocked: Bool, requiresGUI: Bool) throws {
        try Task.checkCancellation()
        guard isCurrent(run, scope, requiresUnlocked: requiresUnlocked, requiresGUI: requiresGUI) else {
            throw Failure.invalidScope
        }
    }

    private func isControlling(_ status: DesktopCrashSupervisorControlStatus) -> Bool {
        status.result == .accepted && status.state == .controlling && !status.mayStillUnlock
    }
}

@MainActor
final class DesktopLockedControlRuntimeIPCTransport: DesktopLockedControlRuntimeTransport {
    private final class LossRouter: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@MainActor @Sendable () -> Void)?

        func install(_ handler: (@MainActor @Sendable () -> Void)?) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func signal() {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            guard let handler else { return }
            Task { @MainActor in handler() }
        }
    }

    private let client: DesktopCrashSupervisorControlIPCClient
    private let lossRouter: LossRouter

    var onConnectionLost: (@MainActor @Sendable () -> Void)? {
        didSet { lossRouter.install(onConnectionLost) }
    }

    init(pinnedReleaseCertificate: Data) {
        let router = LossRouter()
        lossRouter = router
        client = DesktopCrashSupervisorControlIPCClient(pinnedReleaseCertificate: pinnedReleaseCertificate) {
            router.signal()
        }
    }

    func connect() async throws { try await client.connect() }

    func begin(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus {
        try await client.begin(grant: grant, ownedCuaPID: ownedCuaPID)
    }

    func status() async throws -> DesktopCrashSupervisorControlStatus { try await client.status() }

    func heartbeat(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws -> DesktopCrashSupervisorControlStatus {
        try await client.heartbeat(grant: grant, ownedCuaPID: ownedCuaPID)
    }

    func end() async throws -> DesktopCrashSupervisorControlStatus { try await client.end() }

    func invalidate() {
        lossRouter.install(nil)
        client.invalidate()
    }
}
