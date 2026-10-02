import Foundation
import AppKit
import LockedControlAudit
import PersonaStackCore

/// Long-lived owner for a single locked-control transaction. Constructing this
/// type is inert. The app must call `begin` after its ordinary authorization
/// path has approved the exact remote lease.
@MainActor
final class DesktopLockedControlSupervisor {
    struct Console: Equatable {
        let userID: UInt32
        let sessionID: String
        let lock: DesktopControlSessionLock.Snapshot
    }

    enum State: Equatable, Sendable { case idle, starting, controlling, restoring, needsAttention }
    enum Failure: Error { case invalidScope, unavailable, alreadyActive }
    struct Status: Equatable, Sendable {
        let state: State
        let mayStillUnlock: Bool
    }

    struct Operations {
        var currentController: @MainActor () throws -> DesktopLockedControlLocalPeer
        var currentConsole: @MainActor () -> Console
        var leaseForGrant: @MainActor (DesktopLockedControlGrant, Int32) -> DesktopLockedControlSession.Lease?
        var leaseIsAuthorized: @MainActor (DesktopLockedControlSession.Lease) -> Bool
        var clientHeartbeatIsCurrent: @MainActor () -> Bool
        var startLifecycleObservers: @MainActor (@escaping @MainActor () -> Void) throws -> Void
        var stopLifecycleObservers: @MainActor () -> Void
        var startGrantIPC: @MainActor () throws -> Void
        var stopGrantIPC: @MainActor () -> Void
        var stopLocalInput: @MainActor () -> Void
        var protectDisplays: @MainActor (Int32, @escaping @MainActor () -> Void,
                                          @escaping @MainActor () -> Void) throws -> Void
        var restoreDisplays: @MainActor () throws -> Void
        var armGrant: @MainActor (DesktopLockedControlGrant, DesktopLockedControlLocalPeer) throws -> Void
        var revokeGrant: @MainActor (DesktopLockedControlGrant) -> Void
        var grantMayStillUnlock: @MainActor () -> Bool
        var observeUnlock: @MainActor (DesktopLockedControlGrant, DesktopLockedControlLocalPeer) -> Bool
        var confirmRelock: @MainActor (DesktopLockedControlGrant, DesktopLockedControlLocalPeer) -> Bool
        var currentControllerIs: @MainActor (DesktopLockedControlLocalPeer) -> Bool
        var requestWake: @MainActor () throws -> Void
        var restoreOSLock: @MainActor () async -> Bool
        var nowNanoseconds: @MainActor () -> UInt64
        var sleep: @MainActor (Duration) async throws -> Void
    }

    private let operations: Operations
    private lazy var session: DesktopLockedControlSession = makeSession()
    private var watchdog: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var activeGrant: DesktopLockedControlGrant?
    private var activeLease: DesktopLockedControlSession.Lease?
    private var activePeer: DesktopLockedControlLocalPeer?
    private var activeDriverPID: Int32 = 0
    private var generation = UUID()
    private(set) var state: State = .idle { didSet { publishStatus() } }
    var onStatusChange: (@MainActor (Status) -> Void)? {
        didSet { publishStatus() }
    }

    init(operations: Operations) {
        self.operations = operations
    }

    private func makeSession() -> DesktopLockedControlSession {
        let ops = operations
        return DesktopLockedControlSession(operations: .init(
            authorized: { [weak self] lease in
                guard let self, self.activeLease == lease,
                      let grant = self.activeGrant, let peer = self.activePeer,
                      ops.nowNanoseconds() < grant.expiresAtMonotonicNanoseconds,
                      self.matchesCurrentConsole(grant),
                      self.leaseStillCurrent(grant),
                      ops.leaseIsAuthorized(lease) else { return false }
                return ops.currentControllerIs(peer)
            },
            sessionLocked: { [weak self] in self?.operations.currentConsole().lock == .locked },
            protectDisplays: { [weak self] in
                guard let self else { throw Failure.unavailable }
                try ops.protectDisplays(self.activeDriverPID,
                                               { [weak self] in self?.requestEnd() },
                                               { [weak self] in self?.requestEnd() })
            },
            restoreDisplays: { [weak self] in
                guard let self, let grant = self.activeGrant, let peer = self.activePeer,
                      ops.confirmRelock(grant, peer) else { throw Failure.unavailable }
                self.publishStatus()
                try ops.restoreDisplays()
            },
            armAuthorization: { [weak self] lease in
                guard let self, let grant = self.activeGrant, let peer = self.activePeer,
                      lease == self.activeLease else { throw Failure.invalidScope }
                try ops.armGrant(grant, peer)
                self.publishStatus()
            },
            revokeAuthorization: { [weak self] in
                guard let self, let grant = self.activeGrant else { return }
                ops.revokeGrant(grant)
                self.publishStatus()
            },
            awaitAuthorizationSettled: { !ops.grantMayStillUnlock() },
            requestWake: { try ops.requestWake() },
            awaitUnlockedSession: { [weak self] in
                guard let self, let grant = self.activeGrant, let peer = self.activePeer else { return false }
                return await self.waitForUnlock(grant: grant, peer: peer, run: self.generation)
            },
            restoreOSLock: { [weak self] in
                let locked = await ops.restoreOSLock()
                guard let self, locked, let grant = self.activeGrant, self.activePeer != nil else { return false }
                return self.matchesCurrentConsole(grant, lock: .locked)
            },
            confirmRelockBeforeRearming: { [weak self] in
                guard let self, let grant = self.activeGrant, let peer = self.activePeer,
                      self.matchesCurrentConsole(grant, lock: .locked) else { return false }
                return ops.confirmRelock(grant, peer)
            }))
    }

    func begin(grant: DesktopLockedControlGrant, driverPID: Int32) async throws {
        guard state == .idle, watchdog == nil else { throw Failure.alreadyActive }
        let peer = try operations.currentController()
        let console = operations.currentConsole()
        guard driverPID > 0, peer.processIdentifier > 0,
              console.lock == .locked,
              console.userID == grant.consoleUserID,
              console.sessionID == grant.consoleSessionID,
              operations.nowNanoseconds() < grant.expiresAtMonotonicNanoseconds,
              let lease = operations.leaseForGrant(grant, driverPID),
              lease.connectionID == grant.connectionID, lease.token == grant.leaseToken,
              operations.clientHeartbeatIsCurrent(),
              operations.leaseIsAuthorized(lease) else { throw Failure.invalidScope }

        generation = UUID()
        let run = generation
        activeGrant = grant
        activeLease = lease
        activePeer = peer
        activeDriverPID = driverPID
        state = .starting
        do {
            try operations.startLifecycleObservers { [weak self] in self?.requestEnd() }
            try operations.startGrantIPC()
            try await session.begin(lease)
            guard generation == run, session.permitsExecution else { throw Failure.unavailable }
            state = .controlling
            startWatchdog(run)
        } catch {
            guard generation == run else { throw error }
            state = .restoring
            operations.stopGrantIPC()
            if await session.end() {
                clearActive()
            } else {
                state = .needsAttention
                startWatchdog(run)
            }
            throw error
        }
    }

    func end() async -> Bool {
        generation = UUID()
        let cleanupGeneration = generation
        recoveryTask?.cancel()
        recoveryTask = nil
        state = .restoring
        watchdog?.cancel()
        watchdog = nil
        operations.stopGrantIPC()
        publishStatus()
        let cleaned = await session.end()
        guard cleanupGeneration == generation else { return cleaned }
        guard cleaned else {
            state = .needsAttention
            startWatchdog(cleanupGeneration)
            return false
        }
        clearActive()
        return true
    }

    func observe() async { await reconcile() }

    func status() -> Status { Status(state: state, mayStillUnlock: operations.grantMayStillUnlock()) }

    fileprivate func requestEnd() {
        guard state == .controlling || state == .starting else { return }
        // Invalidate before yielding. A queued ordinary-lock recovery must
        // never rearm after local takeover or lifecycle loss.
        generation = UUID()
        state = .restoring
        recoveryTask?.cancel()
        recoveryTask = nil
        if let activeGrant { operations.revokeGrant(activeGrant); publishStatus() }
        Task { @MainActor [weak self] in _ = await self?.end() }
    }

    private func startWatchdog(_ run: UUID) {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.generation == run {
                do { try await self.operations.sleep(.milliseconds(200)) }
                catch { break }
                await self.reconcile(run: run)
            }
        }
    }

    private func reconcile(run: UUID? = nil) async {
        if let run, generation != run { return }
        guard let grant = activeGrant else { return }
        let console = operations.currentConsole()
        let expired = operations.nowNanoseconds() >= grant.expiresAtMonotonicNanoseconds
        let scopeLost = console.userID != grant.consoleUserID || console.sessionID != grant.consoleSessionID
        let leaseLost = activeLease.map { !leaseStillCurrent(grant) || !operations.leaseIsAuthorized($0) } ?? true
        if state == .needsAttention, !scopeLost, console.lock == .unlocked,
           let peer = activePeer {
            if operations.observeUnlock(grant, peer) { publishStatus() }
        }
        if state == .needsAttention || expired || scopeLost || leaseLost ||
            (state == .controlling && console.lock != .unlocked && console.lock != .locked) {
            _ = await end()
        } else if state == .controlling && console.lock == .locked {
            resumeAfterOrdinaryLock()
        }
    }

    private func resumeAfterOrdinaryLock() {
        guard state == .controlling, recoveryTask == nil else { return }
        let run = generation
        state = .starting
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, self.generation == run, self.state == .starting,
                  !Task.isCancelled else { return }
            defer { if self.generation == run { self.recoveryTask = nil } }
            do {
                try await self.session.resumeAfterOrdinaryLock()
                guard self.generation == run, self.state == .starting else { return }
                self.state = .controlling
            } catch {
                guard self.generation == run, self.state == .starting else { return }
                _ = await self.end()
            }
        }
    }

    private func waitForUnlock(grant: DesktopLockedControlGrant,
                               peer: DesktopLockedControlLocalPeer,
                               run: UUID) async -> Bool {
        let deadline = operations.nowNanoseconds().addingClamped(10_000_000_000)
        while !Task.isCancelled, generation == run,
              operations.nowNanoseconds() < deadline {
            guard operations.nowNanoseconds() < grant.expiresAtMonotonicNanoseconds,
                  leaseStillCurrent(grant),
                  let lease = activeLease, operations.leaseIsAuthorized(lease),
                  operations.currentControllerIs(peer) else { return false }
            let current = operations.currentConsole()
            guard current.userID == grant.consoleUserID,
                  current.sessionID == grant.consoleSessionID else { return false }
            if current.lock == .unlocked {
                let observed = brokerObserveUnlock(grant, peer: peer)
                if observed { publishStatus() }
                return observed
            }
            guard current.lock == .locked else { return false }
            do { try await operations.sleep(.milliseconds(100)) }
            catch { return false }
        }
        return false
    }

    private func clearActive() {
        operations.stopLocalInput()
        operations.stopLifecycleObservers()
        activeGrant = nil
        activeLease = nil
        activePeer = nil
        activeDriverPID = 0
        state = .idle
    }

    private func matchesCurrentConsole(_ grant: DesktopLockedControlGrant,
                                       lock: DesktopControlSessionLock.Snapshot? = nil) -> Bool {
        let current = operations.currentConsole()
        return current.userID == grant.consoleUserID && current.sessionID == grant.consoleSessionID
            && (lock == nil || current.lock == lock)
    }

    private func leaseStillCurrent(_ grant: DesktopLockedControlGrant) -> Bool {
        guard let lease = activeLease else { return false }
        return operations.clientHeartbeatIsCurrent()
            && operations.leaseForGrant(grant, activeDriverPID) == lease
    }

    private func publishStatus() { onStatusChange?(status()) }

    // Broker state changes are deliberately supplied through these narrow
    // callbacks so unit tests never need a real Authorization host or socket.
    private func brokerObserveUnlock(_ grant: DesktopLockedControlGrant,
                                     peer: DesktopLockedControlLocalPeer) -> Bool {
        operations.observeUnlock(grant, peer)
    }

    /// Production wiring remains inert until `begin` starts the grant socket,
    /// blackens displays, and installs the local-input filter.
    static func production(pinnedReleaseCertificate: Data,
                           leaseForGrant: @escaping @MainActor (DesktopLockedControlGrant, Int32) -> DesktopLockedControlSession.Lease?,
                           leaseIsAuthorized: @escaping @MainActor (DesktopLockedControlSession.Lease) -> Bool,
                           clientHeartbeatIsCurrent: @escaping @MainActor () -> Bool) -> Self {
        let broker = DesktopLockedControlGrantBroker.localController(
            pinnedReleaseCertificate: pinnedReleaseCertificate)
        let server = DesktopLockedControlGrantIPCServer(broker: broker)
        let lifecycle = DesktopLockedControlLifecycleObservers()
        let privacy = DesktopDisplayPrivacySession {
            DesktopControlSessionLock.currentSnapshot() == .locked
        }
        let supervisor = Self(operations: .init(
            currentController: { try DesktopLockedControlLocalPeer.currentController(
                pinnedReleaseCertificate: pinnedReleaseCertificate) },
            currentConsole: Self.readCurrentConsole,
            leaseForGrant: leaseForGrant,
            leaseIsAuthorized: leaseIsAuthorized,
            clientHeartbeatIsCurrent: clientHeartbeatIsCurrent,
            startLifecycleObservers: { callback in try lifecycle.start(callback) },
            stopLifecycleObservers: { lifecycle.stop() },
            startGrantIPC: { try server.start() },
            stopGrantIPC: { _ = server.stop() },
            stopLocalInput: {
                let input = DesktopLockedControlLocalInput.shared
                input.end()
                input.onTakeover = nil
                input.onFailure = nil
            },
            protectDisplays: { pid, takeover, failure in
                try privacy.concealAllDisplays()
                let input = DesktopLockedControlLocalInput.shared
                input.onTakeover = takeover
                input.onFailure = failure
                try input.begin(driverPID: pid)
            },
            restoreDisplays: { try privacy.restoreDisplays() },
            armGrant: { grant, peer in
                try broker.arm(grant, peer: peer,
                               nowMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            },
            revokeGrant: { grant in
                _ = broker.revoke(connectionID: grant.connectionID, leaseToken: grant.leaseToken)
            },
            grantMayStillUnlock: { broker.mayStillUnlock },
            observeUnlock: { grant, peer in
                broker.observeActualUnlock(connectionID: grant.connectionID, leaseToken: grant.leaseToken,
                                           consoleUserID: grant.consoleUserID,
                                           consoleSessionID: grant.consoleSessionID, peer: peer)
            },
            confirmRelock: { grant, peer in
                if broker.state == .idle { return true }
                return broker.confirmActualRelock(connectionID: grant.connectionID,
                                                   leaseToken: grant.leaseToken,
                                                   consoleUserID: grant.consoleUserID,
                                                   consoleSessionID: grant.consoleSessionID, peer: peer)
            },
            currentControllerIs: { peer in
                guard let current = try? DesktopLockedControlLocalPeer.currentController(
                    pinnedReleaseCertificate: pinnedReleaseCertificate) else { return false }
                return peer == current
            },
            requestWake: { try DesktopLockedControlSystemSession.requestDisplayWake() },
            restoreOSLock: { await DesktopLockedControlSystemSession.restoreLock() },
            nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
            sleep: { try await Task.sleep(for: $0) }))
        privacy.onInvalidation = { [weak supervisor] in supervisor?.requestEnd() }
        return supervisor
    }

    private static func readCurrentConsole() -> Console {
        var uid: UInt32 = 0
        var sessionID: UInt32 = 0
        guard PSCurrentConsoleUserID(&uid) == 1,
              PSCurrentAuditSessionID(&sessionID) == 1,
              uid > 0, sessionID > 0 else {
            return Console(userID: 0, sessionID: "", lock: .unknown)
        }
        return Console(userID: uid, sessionID: String(sessionID),
                       lock: DesktopControlSessionLock.currentSnapshot())
    }
}

@MainActor
private final class DesktopLockedControlLifecycleObservers {
    private var tokens: [NSObjectProtocol] = []

    func start(_ callback: @escaping @MainActor () -> Void) throws {
        guard tokens.isEmpty else { throw DesktopLockedControlSupervisor.Failure.alreadyActive }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { callback() }
            })
        }
    }

    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }
}

private extension UInt64 {
    func addingClamped(_ delta: UInt64) -> UInt64 { self > UInt64.max - delta ? UInt64.max : self + delta }
}
