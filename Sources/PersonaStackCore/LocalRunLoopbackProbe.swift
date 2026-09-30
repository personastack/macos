import Darwin
import Foundation

/// A bounded, content-free probe proving that the guest reaches Mac loopback.
/// DNS registration alone is insufficient after macOS clears packet-filter rules.
public final class LocalRunLoopbackProbe: @unchecked Sendable {
    public let port: UInt16
    public let nonce = UUID().uuidString
    private let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false

    public init() throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalRunError.connectionFailed }
        let descriptor = self.descriptor
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard bind(descriptor, pointer, length) == 0, listen(descriptor, 1) == 0 else { return false }
                return getsockname(descriptor, pointer, &length) == 0
            }
        }
        guard result else { Darwin.close(descriptor); throw LocalRunError.connectionFailed }
        port = UInt16(bigEndian: address.sin_port)
    }
    public func start() {
        DispatchQueue(label: "ai.personastack.local-run.loopback").async { [self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            var yes: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var input = [UInt8](repeating: 0, count: 4096)
            guard Darwin.read(client, &input, input.count) > 0 else { return }
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(nonce.utf8.count)\r\nConnection: close\r\n\r\n\(nonce)".utf8)
            _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        }
    }
    public func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }
    deinit { stop() }
}
