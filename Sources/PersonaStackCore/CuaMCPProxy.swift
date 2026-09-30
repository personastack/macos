import Darwin
import Foundation

public enum CuaMCPProxyError: Error, Equatable {
    case alreadyStarted
    case notStarted
    case invalidToolName
    case invalidArguments
    case invalidResponse
    case responseTooLarge
    case timeout
    case processExited
    case invalidToolCatalog
    case permissionsRequired
    case functionalProbeFailed
    case serviceRunning
    case serviceMismatch
    case interrupted
}

extension CuaMCPProxyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionsRequired:
            return "Grant Accessibility and Screen Recording to PersonaStack in its permissions checklist, then retry setup."
        case .functionalProbeFailed:
            return "PersonaStack could not verify screen capture and accessibility. Check its permissions checklist and retry."
        case .serviceRunning:
            return "Quit CuaDriver.app, then retry Desktop Control repair. Repair will not terminate the running service or replace its managed files."
        case .serviceMismatch:
            return "PersonaStack could not verify its desktop control service. Retry the permissions setup or repair Desktop Control."
        default:
            return "The local Cua service could not complete its setup check. Retry setup or repair Cua."
        }
    }
}

/// Owns one Cua stdio MCP proxy process. Only reviewed Cua tool names can be called.
public actor CuaMCPProxy {
    // A full-resolution 5K screenshot can exceed the relay's 8 MiB frame
    // limit before the desktop app has a chance to compress it.
    private static let maximumLocalResponseBytes = 32 * 1024 * 1024
    private let executableURL: URL
    private let socketURL: URL?
    private let expectedDaemonPID: Int32?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var bufferedOutput = Data()
    private var requestID: Int64 = 0
    private var started = false
    private let interruption = CuaProxyInterruption()

    public init(executableURL: URL, socketURL: URL? = nil, expectedDaemonPID: Int32? = nil) {
        self.executableURL = executableURL
        self.socketURL = socketURL
        self.expectedDaemonPID = expectedDaemonPID
    }

    public func start() throws -> Data {
        guard !started else { throw CuaMCPProxyError.alreadyStarted }
        try verifyDaemonIdentity()
        process.executableURL = executableURL
        // The proxy may only connect to the daemon directly hosted by
        // PersonaStack. Embedded mode forbids standalone-app fallback.
        process.arguments = ["mcp"] + (socketURL.map { ["--socket", $0.path, "--embedded"] } ?? [])
        process.environment = Self.allowedChildEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw CuaMCPProxyError.processExited }
        started = true
        do {
            let response = try request(
                method: "initialize",
                parameters: #"{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"personastack-desktop","version":"1"}}"#,
                timeout: 15
            )
            try sendNotification(method: "notifications/initialized")
            return response
        } catch {
            stop()
            throw error
        }
    }

    public func listTools() throws -> Data {
        try request(method: "tools/list", parameters: "{}", timeout: 15)
    }

    public func validateToolCatalog(_ responseData: Data) throws -> Set<String> {
        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw CuaMCPProxyError.invalidToolCatalog
        }
        let names = Set(tools.compactMap { $0["name"] as? String })
        guard CuaDriverCompatibility.requiredTools.isSubset(of: names) else {
            throw CuaMCPProxyError.invalidToolCatalog
        }
        return names.intersection(CuaDriverCompatibility.exposedTools)
    }

    public func callTool(name: String, argumentsJSON: Data, timeout: Int32 = 60) throws -> Data {
        guard CuaDriverCompatibility.exposedTools.contains(name) else { throw CuaMCPProxyError.invalidToolName }
        return try invokeTool(name: name, argumentsJSON: argumentsJSON, timeout: timeout)
    }

    /// Native-only diagnostic. Remote callers cannot select a health surface.
    public func hostIdentityReport() throws -> Data {
        try invokeTool(name: "health_report", argumentsJSON: Data(#"{"include":["bundle_identity"]}"#.utf8), timeout: 5)
    }

    private func invokeTool(name: String, argumentsJSON: Data, timeout: Int32) throws -> Data {
        guard let arguments = try? JSONSerialization.jsonObject(with: argumentsJSON),
              arguments is [String: Any] else { throw CuaMCPProxyError.invalidArguments }
        let params = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
        return try request(method: "tools/call", parameters: String(decoding: params, as: UTF8.self), timeout: timeout)
    }

    public func isProcessRunning() -> Bool {
        started && process.isRunning && !interruption.isInterrupted
    }

    /// Wake a blocked tool call without waiting for this actor's synchronous read.
    /// This only stops our stdio proxy. It never signals the Cua service.
    nonisolated public func interrupt() {
        interruption.interrupt()
    }

    public func stop() {
        guard started else { return }
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now + .seconds(2)
            while process.isRunning && ContinuousClock.now < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = ContinuousClock.now + .seconds(2)
                while process.isRunning && ContinuousClock.now < killDeadline {
                    usleep(10_000)
                }
            }
        }
        started = false
        bufferedOutput.removeAll(keepingCapacity: false)
    }

    private func request(method: String, parameters: String, timeout: Int32) throws -> Data {
        if interruption.isInterrupted { throw CuaMCPProxyError.interrupted }
        guard started, process.isRunning else { throw CuaMCPProxyError.notStarted }
        do { try verifyDaemonIdentity() }
        catch {
            stop()
            throw error
        }
        requestID += 1
        let id = requestID
        let wire = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(parameters)}\n"
        guard let bytes = wire.data(using: .utf8) else { throw CuaMCPProxyError.invalidArguments }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        do {
            try writeInput(bytes, deadline: deadline)
            return try readResponse(id: id, deadline: deadline)
        }
        catch {
            stop()
            throw error
        }
    }

    private func sendNotification(method: String) throws {
        guard started, process.isRunning else { throw CuaMCPProxyError.notStarted }
        try verifyDaemonIdentity()
        let wire = "{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\"}\n"
        try writeInput(Data(wire.utf8), deadline: Date().addingTimeInterval(15))
    }

    private func writeInput(_ bytes: Data, deadline: Date) throws {
        let descriptor = input.fileHandleForWriting.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CuaMCPProxyError.processExited
        }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                if interruption.isInterrupted { throw CuaMCPProxyError.interrupted }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CuaMCPProxyError.timeout }
                var descriptors = [
                    pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0),
                    pollfd(fd: interruption.readDescriptor, events: Int16(POLLIN), revents: 0)
                ]
                let milliseconds = Int32(max(1, min(remaining * 1000, Double(Int32.max))))
                let ready = descriptors.withUnsafeMutableBufferPointer {
                    Darwin.poll($0.baseAddress, nfds_t($0.count), milliseconds)
                }
                if interruption.isInterrupted { throw CuaMCPProxyError.interrupted }
                if ready == 0 { throw CuaMCPProxyError.timeout }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw CuaMCPProxyError.processExited
                }
                if descriptors[0].revents & Int16(POLLOUT) == 0 {
                    throw CuaMCPProxyError.processExited
                }
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw CuaMCPProxyError.processExited
                }
                guard count > 0 else { throw CuaMCPProxyError.processExited }
                offset += count
            }
        }
    }

    private func readResponse(id: Int64, deadline: Date) throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            if interruption.isInterrupted { throw CuaMCPProxyError.interrupted }
            if let line = takeBufferedLine() {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CuaMCPProxyError.invalidResponse
                }
                guard (object["id"] as? NSNumber)?.int64Value == id else { continue }
                guard object["result"] != nil || object["error"] != nil else { throw CuaMCPProxyError.invalidResponse }
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CuaMCPProxyError.timeout }
            var pollDescriptors = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: interruption.readDescriptor, events: Int16(POLLIN), revents: 0)
            ]
            let milliseconds = Int32(max(1, min(remaining * 1000, Double(Int32.max))))
            let pollResult = pollDescriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), milliseconds)
            }
            if interruption.isInterrupted { throw CuaMCPProxyError.interrupted }
            if pollResult == 0 { throw CuaMCPProxyError.timeout }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CuaMCPProxyError.processExited
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { throw CuaMCPProxyError.processExited }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CuaMCPProxyError.processExited
            }
            bufferedOutput.append(contentsOf: chunk.prefix(count))
            guard bufferedOutput.count <= Self.maximumLocalResponseBytes else { throw CuaMCPProxyError.responseTooLarge }
        }
    }

    private func takeBufferedLine() -> Data? {
        guard let end = bufferedOutput.firstIndex(of: 0x0A) else { return nil }
        let line = Data(bufferedOutput[..<end])
        bufferedOutput.removeSubrange(...end)
        return line
    }

    private static func allowedChildEnvironment() -> [String: String] {
        CuaDriverCompatibility.processEnvironment(from: ProcessInfo.processInfo.environment)
    }

    private func verifyDaemonIdentity() throws {
        guard let expectedDaemonPID else { return }
        guard let socketURL, CuaSocketIdentity.peerPID(at: socketURL) == expectedDaemonPID else {
            throw CuaMCPProxyError.serviceMismatch
        }
    }
}

private final class CuaProxyInterruption: @unchecked Sendable {
    private let lock = NSLock()
    private let wake = Pipe()
    private var interrupted = false

    init() {
        _ = Darwin.fcntl(wake.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    var readDescriptor: Int32 { wake.fileHandleForReading.fileDescriptor }

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func interrupt() {
        lock.lock()
        let shouldWake = !interrupted
        interrupted = true
        lock.unlock()
        guard shouldWake else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wake.fileHandleForWriting.fileDescriptor, &byte, 1)
    }
}

/// Read the kernel-reported PID of the process serving one Unix socket.
/// A socket filename or Cua's shared PID file is not an ownership proof.
public enum CuaSocketIdentity {
    public static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == Darwin.getuid(), info.pbi_ppid > 0 else { return nil }
        return Int32(info.pbi_ppid)
    }

    public static func peerPID(at socketURL: URL) -> Int32? {
        guard socketURL.isFileURL else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pending, 1, 100) > 0 else { return nil }
            var connectError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectError, &errorLength) == 0,
                  connectError == 0 else { return nil }
        }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard Darwin.getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid > 0 else { return nil }
        return pid
    }
}

/// Owns one daemon child and a private endpoint. macOS grants belong to the
/// PersonaStack host that spawns it, never a LaunchServices-started Cua app.
@MainActor
public final class CuaEmbeddedService {
    public let generation = UUID()
    public let executableURL: URL
    public let socketURL: URL
    public let directoryURL: URL
    private let process = Process()
    private let lifetime = Pipe()
    private var launched = false
    private var ownsDirectory = false

    public init(executableURL: URL) {
        self.executableURL = executableURL
        directoryURL = URL(fileURLWithPath: "/tmp/ps-cua-\(UUID().uuidString)", isDirectory: true)
        socketURL = directoryURL.appendingPathComponent("control.sock")
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool {
        launched && process.isRunning
            && CuaSocketIdentity.parentPID(of: process.processIdentifier) == Darwin.getpid()
            && CuaSocketIdentity.peerPID(at: socketURL) == process.processIdentifier
    }

    public static func arguments(socketURL: URL, pidFileURL: URL) -> [String] {
        ["serve", "--embedded", "--parent-liveness-stdio", "--socket", socketURL.path, "--pid-file", pidFileURL.path]
    }

    public func start(isCurrent: @MainActor () throws -> Void) async throws {
        guard !launched else { throw CuaMCPProxyError.alreadyStarted }
        try isCurrent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        ownsDirectory = true
        process.executableURL = executableURL
        process.arguments = Self.arguments(socketURL: socketURL, pidFileURL: directoryURL.appendingPathComponent("daemon.pid"))
        process.environment = CuaDriverCompatibility.processEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardInput = lifetime
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            launched = true
            let deadline = ContinuousClock.now + .seconds(10)
            repeat {
                try isCurrent()
                guard process.isRunning else { throw CuaMCPProxyError.processExited }
                guard CuaSocketIdentity.parentPID(of: process.processIdentifier) == Darwin.getpid() else {
                    throw CuaMCPProxyError.serviceMismatch
                }
                if let peerPID = CuaSocketIdentity.peerPID(at: socketURL) {
                    guard peerPID == process.processIdentifier else { throw CuaMCPProxyError.serviceMismatch }
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            throw CuaMCPProxyError.timeout
        } catch {
            _ = await stop()
            throw error
        }
    }

    public func stop() async -> Bool {
        try? lifetime.fileHandleForWriting.close()
        if launched && process.isRunning {
            // EOF lets the embedded daemon settle its owned work first.
            let gracefulDeadline = ContinuousClock.now + .seconds(1)
            while process.isRunning && ContinuousClock.now < gracefulDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { process.terminate() }
            let terminateDeadline = ContinuousClock.now + .seconds(1)
            while process.isRunning && ContinuousClock.now < terminateDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            let killDeadline = ContinuousClock.now + .milliseconds(500)
            while process.isRunning && ContinuousClock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !process.isRunning else { return false }
        }
        if ownsDirectory {
            do { try FileManager.default.removeItem(at: directoryURL) }
            catch { return false }
            ownsDirectory = false
        }
        return true
    }
}
