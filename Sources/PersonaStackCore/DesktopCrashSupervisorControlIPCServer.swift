import Darwin
import Foundation
import LockedControlAudit

/// Long-lived controller-owned local endpoint. The production initializer uses
/// audit-token code verification. Tests use the pure dispatcher and identity rule.
public final class DesktopCrashSupervisorControlIPCServer: @unchecked Sendable {
    static let requestFrameTimeoutNanoseconds: UInt64 = 5_000_000_000

    /// Runs synchronously under the IPC lifecycle lock. The handler must enqueue
    /// MainActor work and return a cached state promptly. It must not call back
    /// into this server or wait for the locked-session transition. It must validate
    /// the exact current lease and owned CUA PID for every arm and heartbeat.
    public typealias Handler = DesktopCrashSupervisorControlIPCHandler

    private let pinnedCertificate: Data
    private let handler: Handler
    private let onOwnerLost: @Sendable () -> Void
    private let identityProvider: @Sendable () -> DesktopCrashSupervisorControlIdentity?
    private let peerProvider: @Sendable (Int32, Data) -> DesktopCrashSupervisorControlPeer?
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var generation: UUID?
    private var socketPath: String?
    private var socketIdentity: stat?
    private var activeConnectionGeneration: UUID?
    private var activeClientFD: Int32?
    private var lastHeartbeatNanoseconds: UInt64?
    private var isRunning = false

    /// `onOwnerLost` runs under the lifecycle lock. It must synchronously fence
    /// the current owner, then enqueue cleanup without calling this server again.
    public init(pinnedReleaseCertificate: Data,
                handler: @escaping Handler,
                onOwnerLost: @escaping @Sendable () -> Void) {
        self.pinnedCertificate = pinnedReleaseCertificate
        self.handler = handler
        self.onOwnerLost = onOwnerLost
        self.identityProvider = {
            DesktopCrashSupervisorControlIPCServer.currentIdentity(pinnedCertificate: pinnedReleaseCertificate)
        }
        self.peerProvider = {
            DesktopCrashSupervisorControlIPCServer.peerIdentity($0, pinnedCertificate: $1)
        }
        self.now = { DispatchTime.now().uptimeNanoseconds }
    }

    init(pinnedReleaseCertificate: Data,
         identityProvider: @escaping @Sendable () -> DesktopCrashSupervisorControlIdentity?,
         peerProvider: @escaping @Sendable (Int32, Data) -> DesktopCrashSupervisorControlPeer?,
         now: @escaping @Sendable () -> UInt64,
         handler: @escaping Handler,
         onOwnerLost: @escaping @Sendable () -> Void) {
        self.pinnedCertificate = pinnedReleaseCertificate
        self.identityProvider = identityProvider
        self.peerProvider = peerProvider
        self.now = now
        self.handler = handler
        self.onOwnerLost = onOwnerLost
    }

    public var isClientConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && activeConnectionGeneration == generation
    }

    public var clientHeartbeatIsCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, activeConnectionGeneration == generation,
              let lastHeartbeatNanoseconds else { return false }
        let current = now()
        return current >= lastHeartbeatNanoseconds && current - lastHeartbeatNanoseconds < 5_000_000_000
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == -1 else { throw DesktopCrashSupervisorControlIPCError.alreadyConnected }
        guard let identity = identityProvider(),
              identity.consoleUserID == UInt32(getuid()), geteuid() == getuid(),
              DesktopCrashSupervisorControlIPCAuthentication.authenticates(DesktopCrashSupervisorControlPeer(processID: getpid(),
                                                                     effectiveUserID: UInt32(geteuid()),
                                                                     auditSessionID: identity.auditSessionID,
                                                                     matchesPinnedReleaseCertificate: pinnedCertificate.withUnsafeBytes { bytes in
                                                                        PSVerifyPersonaStackSelf(bytes.bindMemory(to: UInt8.self).baseAddress,
                                                                                                 bytes.count) == 1
                                                                     }),
                                   against: identity) else {
            throw DesktopCrashSupervisorControlIPCError.unauthenticatedPeer
        }
        let path = Self.socketPath(for: identity.consoleUserID)
        guard Self.removeStaleSocket(path, owner: uid_t(identity.consoleUserID)) else {
            var existing = stat()
            if lstat(path, &existing) == 0 { throw DesktopCrashSupervisorControlIPCError.uncertainOutcome }
            if errno != ENOENT { throw DesktopCrashSupervisorControlIPCError.uncertainOutcome }
            return try createListener(path, identity: identity)
        }
        try createListener(path, identity: identity)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        let path = socketPath
        let identity = socketIdentity
        let clientFD = activeClientFD
        listener = -1
        generation = nil
        socketPath = nil
        socketIdentity = nil
        activeConnectionGeneration = nil
        activeClientFD = nil
        lastHeartbeatNanoseconds = nil
        isRunning = false
        if let path, let identity { _ = Self.removeSocket(path, matching: identity) }
        if let clientFD { shutdown(clientFD, SHUT_RDWR) }
        onOwnerLost()
    }

    private func createListener(_ path: String, identity: DesktopCrashSupervisorControlIdentity) throws {
        var address = sockaddr_un()
        let pathLength = path.utf8CString.count
        guard pathLength <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw DesktopCrashSupervisorControlIPCError.invalidScope
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DesktopCrashSupervisorControlIPCError.uncertainOutcome }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                memcpy(target.baseAddress!, UnsafeRawPointer(source), pathLength)
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        address.sun_len = UInt8(pathOffset + pathLength)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(pathOffset + pathLength))
            }
        }
        guard bound == 0 else { close(fd); throw DesktopCrashSupervisorControlIPCError.uncertainOutcome }
        var created = stat()
        guard lstat(path, &created) == 0, (created.st_mode & S_IFMT) == S_IFSOCK,
              created.st_uid == uid_t(identity.consoleUserID),
              chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0, listen(fd, 2) == 0 else {
            _ = Self.removeSocket(path, matching: created)
            close(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        var current = stat()
        guard lstat(path, &current) == 0 else {
            _ = Self.removeSocket(path, matching: created)
            close(fd)
            throw DesktopCrashSupervisorControlIPCError.uncertainOutcome
        }
        listener = fd
        generation = UUID()
        socketPath = path
        socketIdentity = current
        isRunning = true
        let listenerGeneration = generation!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { close(fd); return }
            self.acceptLoop(fd, generation: listenerGeneration)
        }
    }

    private func acceptLoop(_ serverFD: Int32, generation: UUID) {
        defer { close(serverFD) }
        while isCurrent(serverFD, generation: generation) {
            var readiness = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
            let result = poll(&readiness, 1, 100)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                retire(serverFD, generation: generation)
                return
            }
            guard isCurrent(serverFD, generation: generation) else { return }
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                retire(serverFD, generation: generation)
                return
            }
            guard fcntl(clientFD, F_SETFD, FD_CLOEXEC) == 0 else { close(clientFD); continue }
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            guard clientFlags >= 0, fcntl(clientFD, F_SETFL, clientFlags | O_NONBLOCK) == 0 else {
                close(clientFD)
                continue
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            serve(clientFD, serverFD: serverFD, generation: generation)
            close(clientFD)
        }
    }

    private func serve(_ clientFD: Int32, serverFD: Int32, generation: UUID) {
        guard isCurrent(serverFD, generation: generation),
              let expected = identityProvider(),
              let peer = peerProvider(clientFD, pinnedCertificate),
              DesktopCrashSupervisorControlIPCAuthentication.authenticates(peer, against: expected) else { return }
        lock.lock()
        guard isRunning, listener == serverFD, self.generation == generation else {
            lock.unlock()
            return
        }
        activeConnectionGeneration = generation
        activeClientFD = clientFD
        // The authenticated persistent connection is the initial liveness proof.
        // The first arm request refreshes it before async session preparation starts.
        lastHeartbeatNanoseconds = now()
        lock.unlock()

        var dispatcher = DesktopCrashSupervisorControlIPCDispatcher(now: now, handler: handler)
        while isCurrent(serverFD, generation: generation) {
            // An authenticated connection is not yet a lease. Bound the first
            // frame as well so an idle client cannot block this serial listener.
            guard let requestDeadline = Self.requestFrameDeadline(startingAt: now()),
                  let frame = Self.readExactly(clientFD, count: DesktopCrashSupervisorControlIPCCodec.requestSize,
                                               deadline: requestDeadline),
                  let request = DesktopCrashSupervisorControlIPCCodec.decodeRequest(frame),
                  let currentIdentity = identityProvider(),
                  let currentPeer = peerProvider(clientFD, pinnedCertificate),
                  DesktopCrashSupervisorControlIPCAuthentication.authenticates(currentPeer, against: currentIdentity),
                  request.scope.consoleUserID == currentIdentity.consoleUserID,
                  request.scope.auditSessionID == currentIdentity.auditSessionID,
                  let response = dispatchIfCurrent(request, dispatcher: &dispatcher,
                                                   serverFD: serverFD, generation: generation) else {
                ownerLostIfCurrent(generation: generation)
                return
            }
            if request.operation == .heartbeat || request.operation == .arm {
                lock.lock()
                if isRunning && self.generation == generation {
                    lastHeartbeatNanoseconds = now()
                }
                lock.unlock()
            }
            let bytes = DesktopCrashSupervisorControlIPCCodec.encode(response)
            let responseDeadline = now().addingReportingOverflow(2_000_000_000)
            guard !responseDeadline.overflow,
                  Self.writeExactly(clientFD, bytes, deadline: responseDeadline.partialValue) else {
                ownerLostIfCurrent(generation: generation)
                return
            }
        }
    }

    private func dispatchIfCurrent(_ request: DesktopCrashSupervisorControlIPCRequest,
                                   dispatcher: inout DesktopCrashSupervisorControlIPCDispatcher,
                                   serverFD: Int32, generation: UUID)
        -> DesktopCrashSupervisorControlIPCResponse? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, listener == serverFD, self.generation == generation else { return nil }
        return dispatcher.process(request)
    }

    private func ownerLostIfCurrent(generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, self.generation == generation,
              activeConnectionGeneration == generation else { return }
        activeConnectionGeneration = nil
        activeClientFD = nil
        lastHeartbeatNanoseconds = nil
        onOwnerLost()
    }

    private func isCurrent(_ fd: Int32, generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && listener == fd && self.generation == generation
    }

    private func retire(_ fd: Int32, generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, listener == fd, self.generation == generation else { return }
        let path = socketPath
        let identity = socketIdentity
        listener = -1
        self.generation = nil
        socketPath = nil
        socketIdentity = nil
        activeConnectionGeneration = nil
        activeClientFD = nil
        lastHeartbeatNanoseconds = nil
        isRunning = false
        if let path, let identity { _ = Self.removeSocket(path, matching: identity) }
        onOwnerLost()
    }

    static func currentIdentity(pinnedCertificate: Data) -> DesktopCrashSupervisorControlIdentity? {
        var consoleUserID: UInt32 = 0
        var sessionID: UInt32 = 0
        let signed = pinnedCertificate.withUnsafeBytes { bytes in
            PSVerifyPersonaStackSelf(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 1
        }
        guard signed, PSCurrentConsoleUserID(&consoleUserID) == 1,
              PSCurrentAuditSessionID(&sessionID) == 1,
              consoleUserID == UInt32(getuid()), geteuid() == getuid(), sessionID > 0 else { return nil }
        return DesktopCrashSupervisorControlIdentity(consoleUserID: consoleUserID,
                                                      auditSessionID: sessionID)
    }

    static func peerIdentity(_ fd: Int32, pinnedCertificate: Data) -> DesktopCrashSupervisorControlPeer? {
        var processID: Int32 = 0
        var effectiveUserID: UInt32 = 0
        var sessionID: UInt32 = 0
        let signed = pinnedCertificate.withUnsafeBytes { bytes in
            PSVerifyPersonaStackPeer(fd, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                     &processID, &effectiveUserID, &sessionID) == 1
        }
        guard signed else { return nil }
        return DesktopCrashSupervisorControlPeer(processID: processID,
                                                  effectiveUserID: effectiveUserID,
                                                  auditSessionID: sessionID,
                                                  matchesPinnedReleaseCertificate: true)
    }

    private static func socketPath(for uid: UInt32) -> String {
        "/tmp/personastack-supervisor-control-\(uid).sock"
    }

    private static func removeStaleSocket(_ path: String, owner: uid_t) -> Bool {
        var observed = stat()
        guard lstat(path, &observed) == 0,
              (observed.st_mode & S_IFMT) == S_IFSOCK, observed.st_uid == owner else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        let flags = fcntl(probe, F_GETFL, 0)
        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = path.utf8CString.count
        guard length <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                memcpy(target.baseAddress!, UnsafeRawPointer(source), length)
            }
        }
        let offset = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        address.sun_len = UInt8(offset + length)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(offset + length))
            }
        }
        guard result != 0, errno == ECONNREFUSED else { return false }
        return removeSocket(path, matching: observed)
    }

    private static func removeSocket(_ path: String, matching identity: stat) -> Bool {
        var current = stat()
        guard lstat(path, &current) == 0, current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino, current.st_uid == identity.st_uid,
              (current.st_mode & S_IFMT) == S_IFSOCK else { return false }
        return unlink(path) == 0
    }

    static func readExactly(_ fd: Int32, count: Int, deadline: UInt64) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            guard wait(fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            let amount = data.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard amount > 0 else { return nil }
            offset += amount
        }
        return data
    }

    static func requestFrameDeadline(startingAt now: UInt64,
                                     timeoutNanoseconds: UInt64 = requestFrameTimeoutNanoseconds) -> UInt64? {
        let deadline = now.addingReportingOverflow(timeoutNanoseconds)
        return deadline.overflow ? nil : deadline.partialValue
    }

    static func writeExactly(_ fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        var offset = 0
        while offset < data.count {
            guard wait(fd, events: Int16(POLLOUT), deadline: deadline) else { return false }
            let amount = data.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            guard amount > 0 else { return false }
            offset += amount
        }
        return true
    }

    static func wait(_ fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else { return false }
            let milliseconds = Int32(min((deadline - current + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, max(1, milliseconds))
            if result > 0 { return descriptor.revents & (events | Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }
}
