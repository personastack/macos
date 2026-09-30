import Darwin
import Foundation

/// A session-private Unix socket. Credentials never travel through WebKit.
public final class LocalRunSocket: @unchecked Sendable {
    private let lock = NSLock()
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
        try lock.withLock {
            guard descriptor >= 0, !closed else { throw LocalRunError.connectionFailed }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let sent = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if sent < 0 && errno == EINTR { continue }
                    guard sent > 0 else { throw LocalRunError.connectionFailed }
                    offset += sent
                }
            }
        }
    }

    private func read(_ sessionID: String) {
        var decoder = LocalRunFrameDecoder(sessionID: sessionID)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let fd = lock.withLock { closed ? -1 : descriptor }
            guard fd >= 0 else { return }
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

    private func finish(_ error: Error) {
        lock.withLock { continuation?.finish(throwing: error); continuation = nil }
        close()
    }

    public func close() {
        lock.withLock {
            closed = true
            if descriptor >= 0 { _ = Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor); descriptor = -1 }
            continuation?.finish()
            continuation = nil
        }
    }
}
