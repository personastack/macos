import Darwin
import Foundation

public protocol AgentBridgeControlTransport: Sendable {
    func exchange(_ request: Data) async throws -> Data
}

public struct AgentBridgeControlClient: Sendable {
    private let transport: any AgentBridgeControlTransport
    public init(transport: any AgentBridgeControlTransport = AgentBridgeSocketTransport()) { self.transport = transport }
    public func send<T: Decodable & Sendable>(_ request: AgentBridgeRequest, returning type: T.Type) async throws -> T {
        let data = try await transport.exchange(request.encoded())
        return try AgentBridgeResponse.decode(type, data: data, requestID: request.requestID)
    }
}

public enum AgentBridgeNativePaths {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PersonaStack/AgentBridge", isDirectory: true)
    }
    public static var socket: URL { controlDirectory(for: directory).appendingPathComponent("control.sock") }
    public static func controlDirectory(for directory: URL) -> URL {
        if directory.appendingPathComponent("control.sock").path.utf8.count <= 103 { return directory }
        return URL(fileURLWithPath: "/private/tmp/personastack-agent-bridge-\(getuid())", isDirectory: true)
    }

    public static func requirePrivate(_ url: URL, socket: Bool = false) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0, information.st_uid == getuid(),
              information.st_mode & 0o077 == 0,
              information.st_mode & S_IFMT == (socket ? S_IFSOCK : S_IFDIR) else { throw AgentBridgeFailure.serviceUnavailable }
    }

    public static func createDirectory(_ directory: URL = Self.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try requirePrivate(directory)
    }
}

public struct AgentBridgeSocketTransport: AgentBridgeControlTransport {
    private let directory: URL
    public init(directory: URL = AgentBridgeNativePaths.directory) { self.directory = directory }
    public func exchange(_ request: Data) async throws -> Data {
        let directory = directory
        return try await Task.detached { try Self.exchange(request, directory: directory) }.value
    }

    private static func exchange(_ request: Data, directory: URL) throws -> Data {
        try AgentBridgeNativePaths.requirePrivate(directory)
        let controlDirectory = AgentBridgeNativePaths.controlDirectory(for: directory)
        try AgentBridgeNativePaths.requirePrivate(controlDirectory)
        let path = controlDirectory.appendingPathComponent("control.sock")
        try AgentBridgeNativePaths.requirePrivate(path, socket: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentBridgeFailure.serviceUnavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentBridgeFailure.serviceUnavailable }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw AgentBridgeFailure.serviceUnavailable }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else { throw AgentBridgeFailure.serviceUnavailable }
        try write(request, to: descriptor)
        return try read(from: descriptor)
    }

    private static func write(_ request: Data, to descriptor: Int32) throws {
        try request.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentBridgeFailure.serviceUnavailable }
                sent += count
            }
        }
    }

    private static func read(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count <= AgentBridgeRequest.maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentBridgeFailure.serviceUnavailable }
            result.append(contentsOf: buffer.prefix(count))
            if let newline = result.firstIndex(of: 10) {
                guard newline == result.count - 1, result.count <= AgentBridgeRequest.maximumBytes else { throw AgentBridgeFailure.invalidRequest }
                return result
            }
        }
        throw AgentBridgeFailure.invalidRequest
    }
}
