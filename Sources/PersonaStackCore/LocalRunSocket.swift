import Darwin
import Foundation

/// A session-private Unix socket. Credentials never travel through WebKit.
public final class LocalRunSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "ai.personastack.local-run.writer", qos: .userInitiated)
    private var queuedWriteBytes = 0
    private static let maximumQueuedWriteBytes = 32 * LocalRunFrameDecoder.maximumFrameBytes
    private var descriptor: Int32 = -1
    private var closed = false
    private var continuation: AsyncThrowingStream<LocalRunFrame, Error>.Continuation?
    public init() {}
    deinit { close() }

    public func connect(path: String, sessionID: String, secret: String) async throws -> AsyncThrowingStream<LocalRunFrame, Error> {
        guard path.utf8.count < 104 else { throw LocalRunError.connectionFailed }
        for _ in 0..<300 {
            try Task.checkCancellation()
            if lock.withLock({ closed }) { throw LocalRunError.staleSession }
            if tryConnect(path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard lock.withLock({ descriptor >= 0 && !closed }) else { throw LocalRunError.connectionFailed }
        let stream = AsyncThrowingStream<LocalRunFrame, Error>(bufferingPolicy: .bufferingOldest(512)) { continuation in
            lock.withLock { self.continuation = continuation }
        }
        try send(LocalRunFrame(type: "hello", sessionID: sessionID, secret: secret))
        DispatchQueue(label: "ai.personastack.local-run.socket", qos: .userInitiated).async { [self] in read(sessionID) }
        return stream
    }

    private func tryConnect(_ path: String) -> Bool {
        let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
        guard candidate >= 0 else { return false }
        guard fcntl(candidate, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(candidate); return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { Darwin.close(candidate); return false }
        var yes: Int32 = 1
        _ = setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return lock.withLock {
            guard !closed, descriptor < 0 else { Darwin.close(candidate); return false }
            descriptor = candidate
            return true
        }
    }

    public func send(_ frame: LocalRunFrame) throws {
        let data = try frame.encoded()
        do {
            try lock.withLock {
                guard descriptor >= 0, !closed else { throw LocalRunError.connectionFailed }
                guard queuedWriteBytes + data.count <= Self.maximumQueuedWriteBytes else { throw LocalRunError.connectionFailed }
                queuedWriteBytes += data.count
                writer.async { [self] in writeQueued(data) }
            }
        } catch {
            finish(LocalRunError.connectionFailed)
            throw error
        }
    }

    private func writeQueued(_ data: Data) {
        defer { lock.withLock { queuedWriteBytes -= data.count } }
        do {
            let fd = try duplicateDescriptor()
            defer { Darwin.close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let sent = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if sent < 0 && errno == EINTR { continue }
                    guard sent > 0 else { throw LocalRunError.connectionFailed }
                    offset += sent
                }
            }
        } catch {
            finish(LocalRunError.connectionFailed)
        }
    }

    private func duplicateDescriptor() throws -> Int32 {
        try lock.withLock {
            guard descriptor >= 0, !closed else { throw LocalRunError.connectionFailed }
            // Close can shut down the connection without allowing a reused fd
            // to redirect an in-flight read or write to an unrelated file.
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw LocalRunError.connectionFailed }
            return duplicate
        }
    }

    private func read(_ sessionID: String) {
        let fd: Int32
        do { fd = try duplicateDescriptor() }
        catch { finish(LocalRunError.connectionFailed); return }
        defer { Darwin.close(fd) }
        var decoder = LocalRunFrameDecoder(sessionID: sessionID)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !lock.withLock({ closed }) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { finish(LocalRunError.connectionFailed); return }
            do {
                for frame in try decoder.append(Data(buffer.prefix(count))) {
                    let result = lock.withLock { continuation?.yield(frame) }
                    if case .dropped = result { finish(LocalRunError.invalidFrame); return }
                }
            } catch { finish(LocalRunError.invalidFrame); return }
        }
    }

    public func close() {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        lock.withLock {
            closed = true
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}
