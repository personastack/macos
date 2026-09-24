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
}

extension CuaMCPProxyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionsRequired:
            return "Grant Accessibility and Screen Recording to CuaDriver.app, then retry setup."
        case .functionalProbeFailed:
            return "CuaDriver.app did not return a usable screenshot and accessibility snapshot. Check its permissions and retry."
        default:
            return "The local Cua service could not complete its setup check. Retry setup or repair Cua."
        }
    }
}

/// Owns one Cua stdio MCP proxy process. Only reviewed Cua tool names can be called.
public actor CuaMCPProxy {
    private let executableURL: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var bufferedOutput = Data()
    private var requestID: Int64 = 0
    private var started = false

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func start() throws -> Data {
        guard !started else { throw CuaMCPProxyError.alreadyStarted }
        process.executableURL = executableURL
        process.arguments = ["mcp"]
        process.environment = Self.allowedChildEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
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

    public func callTool(name: String, argumentsJSON: Data) throws -> Data {
        guard CuaDriverCompatibility.exposedTools.contains(name) else { throw CuaMCPProxyError.invalidToolName }
        guard let arguments = try? JSONSerialization.jsonObject(with: argumentsJSON),
              arguments is [String: Any] else { throw CuaMCPProxyError.invalidArguments }
        let params = try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
        return try request(method: "tools/call", parameters: String(decoding: params, as: UTF8.self), timeout: 60)
    }

    public func stop() {
        guard started else { return }
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        started = false
        bufferedOutput.removeAll(keepingCapacity: false)
    }

    private func request(method: String, parameters: String, timeout: Int32) throws -> Data {
        guard started, process.isRunning else { throw CuaMCPProxyError.notStarted }
        requestID += 1
        let id = requestID
        let wire = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(parameters)}\n"
        guard let bytes = wire.data(using: .utf8) else { throw CuaMCPProxyError.invalidArguments }
        do { try input.fileHandleForWriting.write(contentsOf: bytes) }
        catch { throw CuaMCPProxyError.processExited }
        do { return try readResponse(id: id, timeout: timeout) }
        catch {
            stop()
            throw error
        }
    }

    private func sendNotification(method: String) throws {
        guard started, process.isRunning else { throw CuaMCPProxyError.notStarted }
        let wire = "{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\"}\n"
        do { try input.fileHandleForWriting.write(contentsOf: Data(wire.utf8)) }
        catch { throw CuaMCPProxyError.processExited }
    }

    private func readResponse(id: Int64, timeout: Int32) throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while true {
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
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(remaining * 1000, Double(Int32.max))))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
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
            guard bufferedOutput.count <= 8 * 1024 * 1024 else { throw CuaMCPProxyError.responseTooLarge }
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
}
