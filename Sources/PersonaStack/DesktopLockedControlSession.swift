import Foundation

/// Owns the ordering around an OS authorization transaction. The caller remains
/// the authority for the cloud connection, exclusive lease, and local consent.
/// This type does not treat display wake or a plug-in Allow result as an unlock.
@MainActor
final class DesktopLockedControlSession {
    struct Lease: Equatable {
        let connectionID: UUID
        let token: UUID
        let expires: ContinuousClock.Instant
    }

    enum State: Equatable { case idle, preparing, controlling, restoring, needsAttention }
    enum Failure: Error { case unauthorized, busy, privacyUnavailable, unlockUnavailable, cleanupFailed }

    struct Operations {
        var authorized: @MainActor (Lease) -> Bool
        var sessionLocked: @MainActor () -> Bool
        var protectDisplays: @MainActor () throws -> Void
        var restoreDisplays: @MainActor () throws -> Void
        var armAuthorization: @MainActor (Lease) throws -> Void
        var revokeAuthorization: @MainActor () -> Void
        /// Confirms an in-flight OS transaction cannot unlock after cleanup.
        /// A revoked local token alone cannot cancel a decision already delivered
        /// to the authorization engine. Uncertain settlement retains privacy.
        var awaitAuthorizationSettled: @MainActor () async -> Bool
        var requestWake: @MainActor () throws -> Void
        /// Must observe the actual active console session. A successful display
        /// assertion or a custom authorization right is insufficient evidence.
        var awaitUnlockedSession: @MainActor () async -> Bool
        /// Returns true only after observing the actual OS lock.
        var restoreOSLock: @MainActor () async -> Bool
        /// Settles the previous consumed grant only after an observed unlock
        /// followed by this same console session's actual lock.
        var confirmRelockBeforeRearming: @MainActor () -> Bool = { false }
    }

    private let operations: Operations
    private let now: () -> ContinuousClock.Instant
    private var generation = UUID()
    private var protected = false
    private var authorizationAttempted = false
    private var lease: Lease?
    private var cleanup: Task<Bool, Never>?
    private(set) var state: State = .idle

    init(operations: Operations, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.operations = operations
        self.now = now
    }

    func begin(_ lease: Lease) async throws {
        guard state == .idle, cleanup == nil else { throw Failure.busy }
        guard isAuthorized(lease), operations.sessionLocked() else { throw Failure.unauthorized }
        self.lease = lease
        try await establish(lease, rearming: false)
    }

    /// An ordinary OS lock does not revoke the cloud lease. Keep privacy and
    /// settle the previous one-shot grant before requesting another unlock.
    func resumeAfterOrdinaryLock() async throws {
        guard state == .controlling, cleanup == nil, let lease,
              isAuthorized(lease), operations.sessionLocked() else { throw Failure.unauthorized }
        try await establish(lease, rearming: true)
    }

    private func establish(_ lease: Lease, rearming: Bool) async throws {
        generation = UUID()
        let attempt = generation
        state = .preparing
        do {
            if rearming {
                operations.revokeAuthorization()
                let settled = await operations.awaitAuthorizationSettled()
                guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
                guard settled, operations.sessionLocked(), isAuthorized(lease),
                      operations.confirmRelockBeforeRearming() else { throw Failure.cleanupFailed }
            } else {
                // Mark first so partial display setup also has an owner for cleanup.
                protected = true
                try operations.protectDisplays()
            }
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            guard isAuthorized(lease) else { throw Failure.unauthorized }
            authorizationAttempted = true
            try operations.armAuthorization(lease)
            try operations.requestWake()
            let unlocked = await operations.awaitUnlockedSession()
            guard generation == attempt else { throw CancellationError() }
            guard unlocked, !operations.sessionLocked(), isAuthorized(lease), !Task.isCancelled else {
                throw Failure.unlockUnavailable
            }
            state = .controlling
        } catch {
            if generation == attempt {
                guard await end() else { throw Failure.cleanupFailed }
            }
            throw error
        }
    }

    var permitsExecution: Bool {
        state == .controlling && lease.map(isAuthorized) == true && !operations.sessionLocked()
    }

    /// Stop, lease expiry, disconnect, display changes, and physical takeover
    /// converge here. Revoke synchronously before any wait or display restoration.
    @discardableResult
    func end() async -> Bool {
        generation = UUID()
        lease = nil
        operations.revokeAuthorization()
        if let cleanup { return await cleanup.value }
        guard protected else { state = .idle; return true }
        state = .restoring
        let task = Task { @MainActor [self] in
            if authorizationAttempted, !(await operations.awaitAuthorizationSettled()) {
                state = .needsAttention
                return false
            }
            let locked = operations.sessionLocked() ? true : await operations.restoreOSLock()
            guard locked else {
                state = .needsAttention
                return false
            }
            // A return value alone cannot establish a locked session.
            guard operations.sessionLocked() else { state = .needsAttention; return false }
            do { try operations.restoreDisplays() }
            catch { state = .needsAttention; return false }
            protected = false
            authorizationAttempted = false
            state = .idle
            return true
        }
        cleanup = task
        let result = await task.value
        cleanup = nil
        return result
    }

    private func isAuthorized(_ lease: Lease) -> Bool {
        now() < lease.expires && operations.authorized(lease)
    }
}
