import Foundation

/// Created only after native redeems an API-authorized launch ticket. It is never
/// registered as a WebKit command handler or a remotely reachable HTTP service.
public actor LocalRunHostExecutor {
    private let shell: DesktopShellExecutor
    private let workspace: URL
    private var closed = false
    private var generation = UUID()
    private var active: Set<UUID> = []
    public init(workspace: URL, shell: DesktopShellExecutor = DesktopShellExecutor()) {
        self.workspace = workspace; self.shell = shell
    }

    public func execute(_ request: LocalRunHostRequest, requestID: String) async -> LocalRunReply {
        guard !closed, request.operation == "exec", let arguments = request.command,
              !arguments.isEmpty, arguments.count <= 128,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 }) else {
            return LocalRunReply(request_id: requestID, stderr: "Native command unavailable.", exit_code: 126)
        }
        var directory = request.working_directory ?? workspace.path
        if directory == "/workspace" { directory = workspace.path }
        else if directory.hasPrefix("/workspace/") { directory = workspace.appendingPathComponent(String(directory.dropFirst(11))).path }
        else if directory == "/host" { directory = "/" }
        else if directory.hasPrefix("/host/") { directory = String(directory.dropFirst(5)) }
        let epoch = generation
        do {
            var result = try await shell.start(command: arguments.map(Self.quote).joined(separator: " "), workingDirectory: directory)
            active.insert(result.executionID)
            let executionID = result.executionID
            defer { active.remove(executionID) }
            guard !closed, generation == epoch else { try await shell.cancel(id: result.executionID); throw LocalRunError.staleSession }
            if let input = request.stdin, !input.isEmpty {
                try await shell.write(id: result.executionID, input: .data(Data(input.utf8)))
            }
            try await shell.write(id: result.executionID, input: .close)
            var stdout = Data(), stderr = Data()
            while true {
                for chunk in result.chunks {
                    if chunk.stream == .stdout { Self.append(chunk.data, to: &stdout) }
                    else { Self.append(chunk.data, to: &stderr) }
                }
                guard result.state == .running, !closed, generation == epoch else { break }
                result = try await shell.read(id: result.executionID, after: result.nextCursor, wait: .milliseconds(100))
            }
            return LocalRunReply(request_id: requestID, stdout: String(decoding: stdout, as: UTF8.self),
                                 stderr: String(decoding: stderr, as: UTF8.self), exit_code: Int(result.exitCode ?? 130))
        } catch {
            return LocalRunReply(request_id: requestID, stderr: "The native command could not complete. Check macOS permissions.", exit_code: 126)
        }
    }

    public func cancelActive() async {
        generation = UUID()
        let executions = active
        for id in executions { try? await shell.cancel(id: id) }
    }

    public func close() async -> Bool { closed = true; generation = UUID(); return await shell.closeAll() }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func append(_ chunk: Data, to data: inout Data) {
        let limit = 256 * 1024
        if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
    }
}
