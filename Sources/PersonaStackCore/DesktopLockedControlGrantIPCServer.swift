import Darwin
import Foundation
import LockedControlAudit

/// Candidate in-process server for the separately built authorization plug-in.
/// It creates no privileged helper and changes no authorization policy.
public final class DesktopLockedControlGrantIPCServer: @unchecked Sendable {
    public enum Failure: Error {
        case invalidConsoleSession
        case socketUnavailable
        case alreadyRunning
    }

    private let broker: DesktopLockedControlGrantBroker
    private let nowMonotonicNanoseconds: @Sendable () -> UInt64
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var socketIdentity: stat?
    private var socketPath: String?
    private var listenerGeneration: UUID?
    private var isRunning = false

    public init(broker: DesktopLockedControlGrantBroker,
                nowMonotonicNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.broker = broker
        self.nowMonotonicNanoseconds = nowMonotonicNanoseconds
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == -1 else { throw Failure.alreadyRunning }
        var consoleUserID: UInt32 = 0
        var sessionID: UInt32 = 0
        let pinnedCertificate = try Self.releaseCertificateBytes()
        let ownSignatureValid = pinnedCertificate.withUnsafeBytes { bytes in
            PSVerifyPersonaStackSelf(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) == 1
        }
        guard PSCurrentConsoleUserID(&consoleUserID) == 1,
              PSCurrentAuditSessionID(&sessionID) == 1,
              consoleUserID == UInt32(getuid()), consoleUserID > 0, sessionID > 0,
              ownSignatureValid else {
            throw Failure.invalidConsoleSession
        }

        let path = "/tmp/personastack-locked-grant-\(consoleUserID).sock"
        var address = sockaddr_un()
        let pathLength = path.utf8CString.count
        guard pathLength <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.socketUnavailable }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard Self.removeStaleSocket(path, owner: uid_t(consoleUserID)) else { throw Failure.socketUnavailable }
        } else if errno != ENOENT {
            throw Failure.socketUnavailable
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketUnavailable }
        let listenerFlags = fcntl(fd, F_GETFL, 0)
        guard listenerFlags >= 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, listenerFlags | O_NONBLOCK) == 0 else {
            close(fd)
            throw Failure.socketUnavailable
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                memcpy(destination.baseAddress!, UnsafeRawPointer(source), pathLength)
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        address.sun_len = UInt8(pathOffset + pathLength)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(pathOffset + pathLength))
            }
        }
        guard bindResult == 0 else { close(fd); throw Failure.socketUnavailable }
        var created = stat()
        guard lstat(path, &created) == 0,
              (created.st_mode & S_IFMT) == S_IFSOCK,
              created.st_uid == uid_t(consoleUserID) else {
            close(fd)
            throw Failure.socketUnavailable
        }
        guard chmod(path, mode_t(S_IRUSR | S_IWUSR)) == 0, listen(fd, 4) == 0 else {
            _ = Self.removeSocket(path, matching: created)
            close(fd)
            throw Failure.socketUnavailable
        }
        var identity = stat()
        guard lstat(path, &identity) == 0,
              (identity.st_mode & S_IFMT) == S_IFSOCK,
              identity.st_uid == uid_t(consoleUserID) else {
            close(fd)
            throw Failure.socketUnavailable
        }
        listener = fd
        socketPath = path
        socketIdentity = identity
        let generation = UUID()
        listenerGeneration = generation
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                close(fd)
                return
            }
            self.acceptLoop(fd, generation: generation)
        }
    }

    @discardableResult
    public func stop() -> DesktopLockedControlGrantRevokeResult {
        lock.lock()
        defer { lock.unlock() }
        let path = socketPath
        let identity = socketIdentity
        listener = -1
        socketPath = nil
        socketIdentity = nil
        listenerGeneration = nil
        isRunning = false
        let revocation = broker.revokeArmedGrant()
        if let path, let identity {
            _ = Self.removeSocket(path, matching: identity)
        }
        // The accept loop owns and closes this descriptor. Keeping it open here
        // prevents a restarted listener from reusing its number in the old loop.
        return revocation
    }

    deinit { stop() }

    private func acceptLoop(_ serverFD: Int32, generation: UUID) {
        defer { close(serverFD) }
        while isCurrent(serverFD, generation: generation) {
            var readiness = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&readiness, 1, 100)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                retireListener(serverFD, generation: generation)
                return
            }
            guard isCurrent(serverFD, generation: generation) else { return }
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                retireListener(serverFD, generation: generation)
                return
            }
            guard isCurrent(serverFD, generation: generation), fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else {
                close(client)
                continue
            }
            let flags = fcntl(client, F_GETFL, 0)
            guard flags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0 else {
                close(client)
                continue
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            serve(client, serverFD: serverFD, generation: generation)
            close(client)
        }
    }

    private func isCurrent(_ serverFD: Int32, generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && listener == serverFD && listenerGeneration == generation
    }

    private func retireListener(_ serverFD: Int32, generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, listener == serverFD, listenerGeneration == generation else { return }
        let path = socketPath
        let identity = socketIdentity
        listener = -1
        socketPath = nil
        socketIdentity = nil
        listenerGeneration = nil
        isRunning = false
        _ = broker.revokeArmedGrant()
        if let path, let identity { _ = Self.removeSocket(path, matching: identity) }
    }

    private func consumeIfCurrent(_ serverFD: Int32, generation: UUID,
                                  consoleUserID: UInt32, consoleSessionID: String,
                                  peer: DesktopLockedControlLocalPeer,
                                  nowMonotonicNanoseconds: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, listener == serverFD, listenerGeneration == generation else { return false }
        return Self.consumeForCurrentConsole(consoleUserID: consoleUserID,
                                              consoleSessionID: consoleSessionID,
                                              readIdentity: {
            var userID: UInt32 = 0
            var sessionID: UInt32 = 0
            guard PSCurrentConsoleUserID(&userID) == 1,
                  PSCurrentAuditSessionID(&sessionID) == 1 else { return nil }
            return (userID, String(sessionID))
        }, consume: {
            broker.consumeCurrentGrant(consoleUserID: consoleUserID,
                                          consoleSessionID: consoleSessionID,
                                          peer: peer,
                                          nowMonotonicNanoseconds: nowMonotonicNanoseconds)
        })
    }

    /// The request read can span a console switch. Re-read identity at the
    /// consumption boundary rather than authorizing from the pre-read snapshot.
    static func consumeForCurrentConsole(consoleUserID: UInt32, consoleSessionID: String,
                                         readIdentity: () -> (UInt32, String)?,
                                         consume: () -> Bool) -> Bool {
        guard let current = readIdentity(), current.0 == consoleUserID,
              current.1 == consoleSessionID else { return false }
        return consume()
    }

    private func serve(_ fd: Int32, serverFD: Int32, generation: UUID) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now <= UInt64.max - 1_000_000_000 else { return }
        let deadline = now + 1_000_000_000
        var processID: Int32 = 0
        var effectiveUserID: UInt32 = 0
        var peerSessionID: UInt32 = 0
        var consoleUserID: UInt32 = 0
        var currentSessionID: UInt32 = 0
        guard PSVerifyAuthorizationHostPeer(fd, &processID, &effectiveUserID, &peerSessionID) == 1,
              effectiveUserID == 0,
              PSCurrentConsoleUserID(&consoleUserID) == 1,
              PSCurrentAuditSessionID(&currentSessionID) == 1,
              consoleUserID == UInt32(getuid()),
              peerSessionID == currentSessionID,
              isCurrent(serverFD, generation: generation),
              let request = readExactly(fd, count: DesktopLockedControlGrantIPCMessage.requestSize, deadline: deadline),
              let nonce = DesktopLockedControlGrantIPCMessage.decodeRequest(request) else { return }
        let peer = DesktopLockedControlLocalPeer(processIdentifier: processID,
                                                 effectiveUserID: effectiveUserID,
                                                 auditSessionID: peerSessionID,
                                                 signingIdentifier: "com.apple.authorizationhost",
                                                 teamIdentifier: nil)
        guard isCurrent(serverFD, generation: generation) else { return }
        let allow = consumeIfCurrent(serverFD, generation: generation,
                                     consoleUserID: consoleUserID,
                                     consoleSessionID: String(currentSessionID),
                                     peer: peer,
                                     nowMonotonicNanoseconds: nowMonotonicNanoseconds())
        let response = DesktopLockedControlGrantIPCMessage.encodeResponse(nonce: nonce, allow: allow)
        writeExactly(fd, response, deadline: deadline)
    }

    private func readExactly(_ fd: Int32, count: Int, deadline: UInt64) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard Self.waitFor(fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            let amount = bytes.withUnsafeMutableBytes { rawBuffer in
                recv(fd, rawBuffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if amount < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard amount > 0 else { return nil }
            offset += amount
        }
        return Data(bytes)
    }

    private func writeExactly(_ fd: Int32, _ data: Data, deadline: UInt64) {
        var offset = 0
        while offset < data.count {
            guard Self.waitFor(fd, events: Int16(POLLOUT), deadline: deadline) else { return }
            let amount = data.withUnsafeBytes { rawBuffer in
                send(fd, rawBuffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if amount < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            guard amount > 0 else { return }
            offset += amount
        }
    }

    private static func waitFor(_ fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, max(1, milliseconds))
            if result > 0 { return (descriptor.revents & (events | Int16(POLLERR | POLLHUP | POLLNVAL))) != 0 }
            if result == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private static func releaseCertificateBytes() throws -> Data {
        guard let url = Bundle.main.url(forResource: "ReleaseSigningCertificate", withExtension: "der") else {
            throw Failure.invalidConsoleSession
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func removeStaleSocket(_ path: String, owner: uid_t) -> Bool {
        var observed = stat()
        guard lstat(path, &observed) == 0,
              (observed.st_mode & S_IFMT) == S_IFSOCK,
              observed.st_uid == owner else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0, fcntl(probe, F_SETFD, FD_CLOEXEC) == 0 else {
            if probe >= 0 { close(probe) }
            return false
        }
        let probeFlags = fcntl(probe, F_GETFL, 0)
        guard probeFlags >= 0, fcntl(probe, F_SETFL, probeFlags | O_NONBLOCK) == 0 else {
            close(probe)
            return false
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathLength = path.utf8CString.count
        guard pathLength <= MemoryLayout.size(ofValue: address.sun_path) else { close(probe); return false }
        _ = path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                memcpy(destination.baseAddress!, UnsafeRawPointer(source), pathLength)
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.size - MemoryLayout.size(ofValue: address.sun_path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(pathOffset + pathLength))
            }
        }
        let connectError = errno
        var finalError = connectError
        if result != 0, connectError == EINPROGRESS {
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            if waitFor(probe, events: Int16(POLLOUT), deadline: deadline) {
                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(probe, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 {
                    finalError = socketError
                } else {
                    finalError = errno
                }
            } else {
                finalError = ETIMEDOUT
            }
        }
        close(probe)
        guard result != 0, finalError == ECONNREFUSED else { return false }
        return removeSocket(path, matching: observed)
    }

    private static func removeSocket(_ path: String, matching identity: stat) -> Bool {
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino,
              current.st_uid == identity.st_uid,
              (current.st_mode & S_IFMT) == S_IFSOCK else { return false }
        return unlink(path) == 0
    }
}
