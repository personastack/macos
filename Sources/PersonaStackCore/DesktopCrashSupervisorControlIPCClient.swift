import Darwin
import Foundation
import LockedControlAudit

/// Client operations are serialized away from the main actor. A transport
/// failure invalidates the stream; a request is never replayed on a new socket.
public final class DesktopCrashSupervisorControlIPCClient: @unchecked Sendable {
    public typealias LostHandler = @Sendable () -> Void

    private enum ConnectionState { case fresh, connecting(Int32), connected(Int32), invalidated }
    private let pinnedCertificate: Data
    private let onConnectionLost: LostHandler
    private let identityProvider: @Sendable () -> DesktopCrashSupervisorControlIdentity?
    private let peerProvider: @Sendable (Int32, Data) -> DesktopCrashSupervisorControlPeer?
    private let queue = DispatchQueue(label: "ai.personastack.supervisor-control-ipc")
    private let lock = NSLock()
    private var connectionState: ConnectionState = .fresh
    private var pendingCloseFD: Int32?
    private var activeScope: DesktopCrashSupervisorControlIPCScope?
    private var nextSequence: UInt64 = 1
    private var lossReported = false

    public init(pinnedReleaseCertificate: Data, onConnectionLost: @escaping LostHandler) {
        self.pinnedCertificate = pinnedReleaseCertificate
        self.onConnectionLost = onConnectionLost
        self.identityProvider = { DesktopCrashSupervisorControlIPCServer.currentIdentity(pinnedCertificate: pinnedReleaseCertificate) }
        self.peerProvider = { DesktopCrashSupervisorControlIPCServer.peerIdentity($0, pinnedCertificate: $1) }
    }

    init(pinnedReleaseCertificate: Data,
         identityProvider: @escaping @Sendable () -> DesktopCrashSupervisorControlIdentity?,
         peerProvider: @escaping @Sendable (Int32, Data) -> DesktopCrashSupervisorControlPeer?,
         onConnectionLost: @escaping LostHandler) {
        self.pinnedCertificate = pinnedReleaseCertificate
        self.identityProvider = identityProvider
        self.peerProvider = peerProvider
        self.onConnectionLost = onConnectionLost
    }

    public func connect() async throws {
        try await runOnQueue { try self.connectOnQueue() }
    }

    public func begin(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws
        -> DesktopCrashSupervisorControlStatus {
        try await runOnQueue {
            let scope = try DesktopCrashSupervisorControlIPCScope(grant: grant, ownedCuaPID: ownedCuaPID)
            guard scope.isValid else { throw DesktopCrashSupervisorControlIPCError.invalidScope }
            self.lock.lock()
            guard self.activeScope == nil else { self.lock.unlock(); throw DesktopCrashSupervisorControlIPCError.staleScope }
            self.lock.unlock()
            let initial = try self.perform(.arm, scope: scope, timeoutNanoseconds: 2_000_000_000)
            guard initial.result == .accepted else { throw DesktopCrashSupervisorControlIPCError.remoteDenied }
            if initial.state == .idle {
                self.invalidate()
                throw DesktopCrashSupervisorControlIPCError.remoteDenied
            }
            let deadlineResult = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(30_000_000_000)
            guard !deadlineResult.overflow else { throw DesktopCrashSupervisorControlIPCError.timedOut }
            while DispatchTime.now().uptimeNanoseconds < deadlineResult.partialValue {
                if initial.state == .controlling { return initial }
                if initial.state == .needsAttention || initial.state == .idle {
                    return initial
                }
                Thread.sleep(forTimeInterval: 0.25)
                let status = try self.perform(.heartbeat, scope: scope, timeoutNanoseconds: 2_000_000_000)
                guard status.result == .accepted else {
                    self.invalidate()
                    throw DesktopCrashSupervisorControlIPCError.remoteDenied
                }
                if status.state == .idle {
                    self.invalidate()
                    throw DesktopCrashSupervisorControlIPCError.remoteDenied
                }
                if status.state != .preparing { return status }
            }
            self.invalidate()
            throw DesktopCrashSupervisorControlIPCError.timedOut
        }
    }

    public func status() async throws -> DesktopCrashSupervisorControlStatus {
        try await runOnQueue {
            let scope: DesktopCrashSupervisorControlIPCScope
            do { scope = try self.currentScope() }
            catch DesktopCrashSupervisorControlIPCError.noActiveGrant {
                return DesktopCrashSupervisorControlStatus(result: .accepted, state: .idle,
                                                           mayStillUnlock: false)
            }
            return try self.perform(.status, scope: scope, timeoutNanoseconds: 2_000_000_000)
        }
    }

    public func heartbeat(grant: DesktopLockedControlGrant, ownedCuaPID: Int32) async throws
        -> DesktopCrashSupervisorControlStatus {
        try await runOnQueue {
            let freshScope = try DesktopCrashSupervisorControlIPCScope(grant: grant, ownedCuaPID: ownedCuaPID)
            let storedScope = try self.currentScope()
            guard freshScope == storedScope else { throw DesktopCrashSupervisorControlIPCError.staleScope }
            return try self.perform(.heartbeat, scope: freshScope, timeoutNanoseconds: 2_000_000_000)
        }
    }

    public func end() async throws -> DesktopCrashSupervisorControlStatus {
        try await runOnQueue {
            let scope: DesktopCrashSupervisorControlIPCScope
            do { scope = try self.currentScope() }
            catch DesktopCrashSupervisorControlIPCError.noActiveGrant {
                return DesktopCrashSupervisorControlStatus(result: .accepted, state: .idle,
                                                           mayStillUnlock: false)
            }
            let initial = try self.perform(.end, scope: scope, timeoutNanoseconds: 2_000_000_000)
            guard initial.result == .accepted else {
                self.invalidate()
                throw DesktopCrashSupervisorControlIPCError.remoteDenied
            }
            if initial.state == .idle { return initial }
            if initial.state == .needsAttention { return initial }
            let deadlineResult = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(30_000_000_000)
            guard !deadlineResult.overflow else { throw DesktopCrashSupervisorControlIPCError.timedOut }
            var status = initial
            while DispatchTime.now().uptimeNanoseconds < deadlineResult.partialValue {
                if status.state == .idle || status.state == .needsAttention { return status }
                Thread.sleep(forTimeInterval: 0.25)
                status = try self.perform(.heartbeat, scope: scope, timeoutNanoseconds: 2_000_000_000)
                guard status.result == .accepted else {
                    self.invalidate()
                    throw DesktopCrashSupervisorControlIPCError.remoteDenied
                }
                if status.state == .idle || status.state == .needsAttention { return status }
            }
            self.invalidate()
            throw DesktopCrashSupervisorControlIPCError.timedOut
        }
    }

    /// Synchronously shuts down the socket so it interrupts a pending begin.
    /// It never resends the command and reports loss asynchronously to the app.
    public func invalidate() {
        lock.lock()
        let fd = Self.fileDescriptor(connectionState)
        connectionState = .invalidated
        activeScope = nil
        if let fd {
            pendingCloseFD = fd
            shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
        reportConnectionLost()
        queue.async { self.closePendingDescriptor() }
    }

    private func runOnQueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let value = try operation()
                    self.closePendingDescriptor()
                    continuation.resume(returning: value)
                } catch {
                    self.closePendingDescriptor()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func connectOnQueue() throws {
        lock.lock()
        guard case .fresh = connectionState else {
            let invalidated: Bool
            if case .invalidated = connectionState { invalidated = true } else { invalidated = false }
            lock.unlock()
            throw invalidated ? DesktopCrashSupervisorControlIPCError.invalidated : DesktopCrashSupervisorControlIPCError.alreadyConnected
        }
        guard let identity = identityProvider() else {
            connectionState = .invalidated
            lock.unlock()
            throw DesktopCrashSupervisorControlIPCError.unauthenticatedPeer
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { lock.unlock(); throw DesktopCrashSupervisorControlIPCError.uncertainOutcome }
        connectionState = .connecting(fd)
        lock.unlock()
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            failConnection(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        let path = "/tmp/personastack-supervisor-control-\(identity.consoleUserID).sock"
        var address = sockaddr_un()
        let length = path.utf8CString.count
        guard length <= MemoryLayout.size(ofValue: address.sun_path) else {
            failConnection(fd)
            throw DesktopCrashSupervisorControlIPCError.invalidScope
        }
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                memcpy(target.baseAddress!, UnsafeRawPointer(source), length)
            }
        }
        let offset = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        address.sun_len = UInt8(offset + length)
        let connectDeadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(2_000_000_000)
        guard !connectDeadline.overflow else { failConnection(fd); throw DesktopCrashSupervisorControlIPCError.timedOut }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let result = Darwin.connect(fd, $0, socklen_t(offset + length))
                return result == 0 || (errno == EINPROGRESS &&
                    DesktopCrashSupervisorControlIPCServer.wait(fd, events: Int16(POLLOUT), deadline: connectDeadline.partialValue) &&
                    Self.socketConnectSucceeded(fd))
            }
        }
        guard connected, let peer = peerProvider(fd, pinnedCertificate),
              DesktopCrashSupervisorControlIPCAuthentication.authenticates(peer, against: identity) else {
            failConnection(fd)
            throw DesktopCrashSupervisorControlIPCError.unauthenticatedPeer
        }
        lock.lock()
        guard case .connecting(let connectingFD) = connectionState, connectingFD == fd else {
            lock.unlock()
            throw DesktopCrashSupervisorControlIPCError.invalidated
        }
        connectionState = .connected(fd)
        lock.unlock()
    }

    private func perform(_ operation: DesktopCrashSupervisorControlIPCOperation,
                         scope: DesktopCrashSupervisorControlIPCScope,
                         timeoutNanoseconds: UInt64) throws -> DesktopCrashSupervisorControlStatus {
        guard scope.isValid else { throw DesktopCrashSupervisorControlIPCError.invalidScope }
        lock.lock()
        guard case .connected(let fd) = connectionState else {
            let invalidated: Bool
            if case .invalidated = connectionState { invalidated = true } else { invalidated = false }
            lock.unlock()
            throw invalidated ? DesktopCrashSupervisorControlIPCError.invalidated : DesktopCrashSupervisorControlIPCError.notConnected
        }
        let sequence = nextSequence
        guard sequence > 0, sequence < UInt64.max else {
            lock.unlock()
            failConnection(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        nextSequence += 1
        lock.unlock()
        let request = DesktopCrashSupervisorControlIPCRequest(sequence: sequence, operation: operation, scope: scope)
        let bytes = try DesktopCrashSupervisorControlIPCCodec.encode(request)
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(timeoutNanoseconds)
        guard !deadline.overflow,
              DesktopCrashSupervisorControlIPCServer.writeExactly(fd, bytes, deadline: deadline.partialValue),
              let responseBytes = DesktopCrashSupervisorControlIPCServer.readExactly(fd,
                                                                                     count: DesktopCrashSupervisorControlIPCCodec.responseSize,
                                                                                     deadline: deadline.partialValue),
              let response = DesktopCrashSupervisorControlIPCCodec.decodeResponse(responseBytes, matching: request) else {
            failConnection(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        lock.lock()
        guard case .connected(let currentFD) = connectionState, currentFD == fd else {
            lock.unlock()
            throw DesktopCrashSupervisorControlIPCError.invalidated
        }
        if operation == .arm, response.status.result == .accepted { activeScope = scope }
        if response.status.cleanupIsComplete { activeScope = nil }
        lock.unlock()
        return response.status
    }

    private func currentScope() throws -> DesktopCrashSupervisorControlIPCScope {
        lock.lock()
        defer { lock.unlock() }
        guard case .connected = connectionState else { throw DesktopCrashSupervisorControlIPCError.notConnected }
        guard let activeScope else { throw DesktopCrashSupervisorControlIPCError.noActiveGrant }
        return activeScope
    }

    private func failConnection(_ fd: Int32) {
        lock.lock()
        let isCurrent = Self.fileDescriptor(connectionState) == fd
        if isCurrent {
            connectionState = .invalidated
            activeScope = nil
        }
        lock.unlock()
        if isCurrent { shutdown(fd, SHUT_RDWR); close(fd); reportConnectionLost() }
    }

    private func closePendingDescriptor() {
        lock.lock()
        let fd = pendingCloseFD
        pendingCloseFD = nil
        lock.unlock()
        if let fd { close(fd) }
    }

    private func reportConnectionLost() {
        lock.lock()
        guard !lossReported else { lock.unlock(); return }
        lossReported = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.onConnectionLost() }
    }

    private static func fileDescriptor(_ state: ConnectionState) -> Int32? {
        switch state {
        case .fresh, .invalidated: nil
        case .connecting(let fd), .connected(let fd): fd
        }
    }

    private static func socketConnectSucceeded(_ fd: Int32) -> Bool {
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }
}
