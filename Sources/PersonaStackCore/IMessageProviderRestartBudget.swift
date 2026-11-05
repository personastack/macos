import Foundation

public struct IMessageProviderResources: Equatable, Sendable {
    public let ownedChildren: Int
    public let ownedPipeHandles: Int
    public init(ownedChildren: Int, ownedPipeHandles: Int) { self.ownedChildren = ownedChildren; self.ownedPipeHandles = ownedPipeHandles }
}

public struct IMessageRPCDiagnostics: Sendable {
    public let bufferedBytes: Int
    public let requestPending: Bool
    public let started: Bool
    public let ready: Bool
    public let cleanupPending: Bool
    public let resources: IMessageProviderResources?
    public let restarts: IMessageProviderRestartBudget.Snapshot
}

public struct IMessageRuntimeDiagnostics: Sendable {
    public let waitingCommands: Int
    public let activeCommand: Bool
    public let cleanupPending: Bool
    public let restorationPending: Bool
}

/// App-lifetime failure memory. Healthy closes and caller cancellation do not
/// spend a restart. Once exhausted, only an explicit local Retry can reset it.
public final class IMessageProviderRestartBudget: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let recentRestarts: Int
        public let exhausted: Bool
    }
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var restarts: [Date] = []
    private var needsRestart = false
    private var exhausted = false

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    func beforeLaunch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !exhausted else { throw IMessageRPCError.restartLimitReached }
        let instant = now()
        restarts.removeAll { instant.timeIntervalSince($0) >= 300 }
        guard needsRestart else { return }
        guard restarts.count < 3 else {
            exhausted = true
            throw IMessageRPCError.restartLimitReached
        }
        restarts.append(instant)
        needsRestart = false
    }

    func recordUnexpectedFailure() {
        lock.lock(); defer { lock.unlock() }
        needsRestart = true
    }

    /// The caller must first join provider cleanup and withdraw old work.
    func resetAfterExplicitRetry() {
        lock.lock(); defer { lock.unlock() }
        restarts.removeAll(); needsRestart = false; exhausted = false
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let instant = now()
        let count = restarts.filter { instant.timeIntervalSince($0) < 300 }.count
        return .init(recentRestarts: count, exhausted: exhausted)
    }
}
