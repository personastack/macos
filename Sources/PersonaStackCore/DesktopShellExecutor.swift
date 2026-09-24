import Darwin
import Foundation
import Dispatch

public enum DesktopProcessState: String, Sendable {
    case running
    case exited
    case cancelled
    case timedOut
}

public enum DesktopProcessInput: Sendable {
    case data(Data)
    case close
    case interrupt
}

public struct DesktopOutputChunk: Sendable, Equatable {
    public let sequence: UInt64
    public let stream: Stream
    public let data: Data

    public enum Stream: String, Sendable {
        case stdout
        case stderr
    }
}

public struct DesktopProcessRead: Sendable {
    public let executionID: UUID
    public let chunks: [DesktopOutputChunk]
    public let nextCursor: UInt64
    public let earliestCursor: UInt64
    public let outputGap: Bool
    public let state: DesktopProcessState
    public let exitCode: Int32?
    public let signal: Int32?
}

public enum DesktopShellError: Error, Equatable {
    case invalidCommand
    case invalidWorkingDirectory
    case permissionDenied
    case tooManyProcesses
    case missingExecution
    case invalidInput
    case cancellationUnconfirmed
}

/// Bounded process sessions owned by a single already-authorized desktop control session.
/// The MCP and gateway layers must authorize each operation before calling this actor.
public actor DesktopShellExecutor {
    public static let maximumCommandBytes = 64 * 1024
    public static let maximumInputBytes = 32 * 1024
    public static let maximumReadBytes = 1024 * 1024
    public static let maximumBufferedBytesPerProcess = 4 * 1024 * 1024
    public static let maximumQueuedInputBytes = 128 * 1024
    public static let maximumProcesses = 4
    public static let maximumRetainedSessions = 16
    public static let maximumTimeout: TimeInterval = 30 * 60

    private struct Session {
        let processID: pid_t
        let stdin: FileHandle
        let inputQueue: DispatchQueue
        var chunks: [DesktopOutputChunk] = []
        var bufferedBytes = 0
        var totalBytes: UInt64 = 0
        var nextSequence: UInt64 = 0
        var state: DesktopProcessState = .running
        var exitCode: Int32?
        var signal: Int32?
        var outputReaders = 2
        var processTerminated = false
        var terminalState: DesktopProcessState?
        var requestedTerminalState: DesktopProcessState?
        var queuedInputBytes = 0
        var readerDrainDeadline: ContinuousClock.Instant?
        var forceCloseReaders = false
        var incompleteOutput = false
        let startedAt: ContinuousClock.Instant
        var deadlineTask: Task<Void, Never>?
    }

    private var sessions: [UUID: Session] = [:]

    public init() {}

    public func start(command: String, workingDirectory: String, timeout: TimeInterval = 300) async throws -> DesktopProcessRead {
        guard !command.isEmpty, command.utf8.count <= Self.maximumCommandBytes else { throw DesktopShellError.invalidCommand }
        guard workingDirectory.hasPrefix("/") else {
            throw DesktopShellError.invalidWorkingDirectory
        }
        let accessResult = workingDirectory.withCString { Darwin.access($0, X_OK) }
        guard accessResult == 0 else { throw Self.directoryError(errno: errno) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopShellError.invalidWorkingDirectory
        }
        pruneCompletedSessions()
        guard sessions.values.filter({ $0.state == .running }).count < Self.maximumProcesses else {
            throw DesktopShellError.tooManyProcesses
        }
        let boundedTimeout = min(max(timeout, 1), Self.maximumTimeout)
        let id = UUID()
        let child = try Self.spawn(command: command, workingDirectory: workingDirectory)
        var session = Session(processID: child.pid, stdin: FileHandle(fileDescriptor: child.stdin, closeOnDealloc: true),
                              inputQueue: DispatchQueue(label: "ai.personastack.desktop.shell.input.\(id.uuidString)"),
                              startedAt: .now)
        session.deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(boundedTimeout))
            await self?.timeout(id)
        }
        sessions[id] = session
        Self.forward(FileHandle(fileDescriptor: child.stdout, closeOnDealloc: true), stream: .stdout, to: self, id: id)
        Self.forward(FileHandle(fileDescriptor: child.stderr, closeOnDealloc: true), stream: .stderr, to: self, id: id)
        Self.wait(child.pid, on: self, id: id)
        return try await read(id: id, after: 0, wait: .seconds(1))
    }

    public func read(id: UUID, after cursor: UInt64, wait: Duration = .zero) async throws -> DesktopProcessRead {
        let end = ContinuousClock.now + min(max(wait, .zero), .seconds(10))
        while true {
            guard let session = sessions[id] else { throw DesktopShellError.missingExecution }
            let earliest = session.chunks.first?.sequence ?? session.nextSequence + 1
            let gap = session.incompleteOutput || cursor < earliest - 1
            let selected = session.chunks.filter { $0.sequence > cursor }
            let chunks = Self.bounded(selected, limit: Self.maximumReadBytes)
            let nextCursor = chunks.last?.sequence ?? cursor
            if !chunks.isEmpty || session.state != .running || ContinuousClock.now >= end {
                return DesktopProcessRead(executionID: id, chunks: chunks, nextCursor: nextCursor,
                                          earliestCursor: earliest, outputGap: gap, state: session.state,
                                          exitCode: session.exitCode, signal: session.signal)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func write(id: UUID, input: DesktopProcessInput) async throws {
        switch input {
        case .data(let data):
            guard !data.isEmpty, data.count <= Self.maximumInputBytes else { throw DesktopShellError.invalidInput }
            guard var session = sessions[id], session.terminalState == nil,
                  session.queuedInputBytes + data.count <= Self.maximumQueuedInputBytes else { throw DesktopShellError.invalidInput }
            session.queuedInputBytes += data.count
            sessions[id] = session
            let inputQueue = session.inputQueue
            let inputHandle = session.stdin
            try await withCheckedThrowingContinuation { continuation in
                inputQueue.async {
                    do { try inputHandle.write(contentsOf: data); continuation.resume() }
                    catch { continuation.resume(throwing: DesktopShellError.invalidInput) }
                    Task { await self.finishInputWrite(id, byteCount: data.count) }
                }
            }
        case .close:
            guard let session = sessions[id], session.terminalState == nil else { throw DesktopShellError.missingExecution }
            try await withCheckedThrowingContinuation { continuation in
                session.inputQueue.async {
                    do { try session.stdin.close(); continuation.resume() }
                    catch { continuation.resume(throwing: DesktopShellError.invalidInput) }
                }
            }
        case .interrupt:
            guard let session = sessions[id], session.terminalState == nil else { throw DesktopShellError.missingExecution }
            guard kill(-session.processID, SIGINT) == 0 else { throw DesktopShellError.missingExecution }
        }
    }

    public func cancel(id: UUID) async throws {
        guard var session = sessions[id] else { throw DesktopShellError.missingExecution }
        guard !session.processTerminated else { return }
        if !Self.processGroupExists(session.processID) { return }
        session.requestedTerminalState = .cancelled
        sessions[id] = session
        _ = kill(-session.processID, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        if let current = sessions[id], !current.processTerminated, Self.processGroupExists(current.processID) {
            _ = kill(-current.processID, SIGKILL)
        }
        try? await Task.sleep(for: .milliseconds(100))
        if let current = sessions[id], !current.processTerminated, Self.processGroupExists(current.processID) {
            throw DesktopShellError.cancellationUnconfirmed
        }
    }

    public func status(id: UUID) throws -> DesktopProcessRead {
        guard let session = sessions[id] else { throw DesktopShellError.missingExecution }
        let earliest = session.chunks.first?.sequence ?? session.nextSequence + 1
        return DesktopProcessRead(executionID: id, chunks: [], nextCursor: 0,
                                  earliestCursor: earliest, outputGap: false, state: session.state,
                                  exitCode: session.exitCode, signal: session.signal)
    }

    @discardableResult
    public func closeAll() async -> Bool {
        let running = sessions.filter { !$0.value.processTerminated }.map(\.key)
        var cancellationConfirmed = true
        for id in running {
            do { try await cancel(id: id) }
            catch { cancellationConfirmed = false }
        }
        for (id, var session) in Array(sessions) where session.state == .running {
            session.forceCloseReaders = true
            sessions[id] = session
        }
        for _ in 0..<15 {
            let unsettled = sessions.values.contains { $0.state == .running || Self.processGroupExists($0.processID) }
            if !unsettled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard cancellationConfirmed,
              !sessions.values.contains(where: { $0.state == .running || Self.processGroupExists($0.processID) }) else {
            return false
        }
        for (id, session) in Array(sessions) {
            session.deadlineTask?.cancel()
            await closeInput(session, id: id)
        }
        sessions.removeAll()
        return true
    }

    private func append(_ data: Data, stream: DesktopOutputChunk.Stream, id: UUID) {
        guard var session = sessions[id], !data.isEmpty else { return }
        session.nextSequence += 1
        let chunk = DesktopOutputChunk(sequence: session.nextSequence, stream: stream, data: data)
        session.totalBytes += UInt64(data.count)
        session.bufferedBytes += data.count
        session.chunks.append(chunk)
        while session.bufferedBytes > Self.maximumBufferedBytesPerProcess, !session.chunks.isEmpty {
            session.bufferedBytes -= session.chunks.removeFirst().data.count
        }
        sessions[id] = session
    }

    private func finish(_ id: UUID, waitStatus: Int32) {
        guard var session = sessions[id] else { return }
        if session.terminalState == nil {
            let signal = waitStatus & 0x7f
            session.terminalState = session.requestedTerminalState ?? (signal == 0 ? .exited : .cancelled)
            session.exitCode = signal == 0 ? (waitStatus >> 8) & 0xff : nil
            session.signal = signal == 0 ? nil : signal
        }
        Self.finishIfDrained(&session)
        sessions[id] = session
    }

    private func markLeaderExited(_ id: UUID) {
        guard var session = sessions[id], !session.processTerminated else { return }
        session.processTerminated = true
        session.readerDrainDeadline = ContinuousClock.now + .seconds(2)
        sessions[id] = session
    }

    private func finishStream(_ id: UUID) {
        guard var session = sessions[id] else { return }
        session.outputReaders = max(0, session.outputReaders - 1)
        Self.finishIfDrained(&session)
        sessions[id] = session
    }

    private func shouldStopReader(_ id: UUID) -> Bool {
        guard var session = sessions[id] else { return true }
        guard session.forceCloseReaders || session.readerDrainDeadline.map({ ContinuousClock.now >= $0 }) == true else { return false }
        session.incompleteOutput = true
        sessions[id] = session
        return true
    }

    private static func finishIfDrained(_ session: inout Session) {
        guard session.processTerminated, session.outputReaders == 0 else { return }
        session.state = session.terminalState ?? session.state
        session.deadlineTask?.cancel()
    }

    private func timeout(_ id: UUID) async {
        guard var session = sessions[id], session.state == .running, !session.processTerminated else { return }
        session.requestedTerminalState = .timedOut
        session.terminalState = .timedOut
        sessions[id] = session
        _ = kill(-session.processID, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        if let current = sessions[id], !current.processTerminated, Self.processGroupExists(current.processID) {
            _ = kill(-current.processID, SIGKILL)
        }
    }

    private static func forward(_ handle: FileHandle, stream: DesktopOutputChunk.Stream, to executor: DesktopShellExecutor, id: UUID) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        Task.detached(priority: .utility) {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                if await executor.shouldStopReader(id) {
                    try? handle.close()
                    await executor.finishStream(id)
                    return
                }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    await executor.append(Data(buffer.prefix(count)), stream: stream, id: id)
                    continue
                }
                if count == 0 {
                    try? handle.close()
                    await executor.finishStream(id)
                    return
                }
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    try? handle.close()
                    await executor.finishStream(id)
                    return
                }
                if await executor.shouldStopReader(id) {
                    try? handle.close()
                    await executor.finishStream(id)
                    return
                }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptorState, 1, 100)
            }
        }
    }

    private static func bounded(_ chunks: [DesktopOutputChunk], limit: Int) -> [DesktopOutputChunk] {
        var result: [DesktopOutputChunk] = []
        var size = 0
        for chunk in chunks {
            if size + chunk.data.count > limit { break }
            result.append(chunk)
            size += chunk.data.count
        }
        return result
    }

    private static func childEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        return source.filter { allowed.contains($0.key) }
    }

    private static func spawn(command: String, workingDirectory: String) throws -> (pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32) {
        var input = [Int32](repeating: -1, count: 2)
        var output = [Int32](repeating: -1, count: 2)
        var error = [Int32](repeating: -1, count: 2)
        guard pipe(&input) == 0 else { throw DesktopShellError.invalidCommand }
        guard pipe(&output) == 0 else { _ = Darwin.close(input[0]); _ = Darwin.close(input[1]); throw DesktopShellError.invalidCommand }
        guard pipe(&error) == 0 else {
            _ = Darwin.close(input[0]); _ = Darwin.close(input[1]); _ = Darwin.close(output[0]); _ = Darwin.close(output[1])
            throw DesktopShellError.invalidCommand
        }
        for descriptor in [input[0], input[1], output[0], output[1], error[0], error[1]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        var spawned = false
        defer {
            if spawned {
                _ = Darwin.close(input[0]); _ = Darwin.close(output[1]); _ = Darwin.close(error[1])
            } else {
                for descriptor in [input[0], input[1], output[0], output[1], error[0], error[1]] where descriptor >= 0 {
                    _ = Darwin.close(descriptor)
                }
            }
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw DesktopShellError.invalidCommand }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, input[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, output[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, error[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, input[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, output[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, error[1]) == 0 else { throw DesktopShellError.invalidCommand }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { throw DesktopShellError.invalidCommand }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw DesktopShellError.invalidCommand }

        let childScript = command + "; _personastack_status=$?; wait; exit $_personastack_status"
        let childCommand = "/bin/zsh -lc " + shellQuote(childScript)
        let script = "cd -- " + shellQuote(workingDirectory) +
            " && trap 'wait; exit 143' TERM; trap 'wait; exit 130' INT; " +
            childCommand + "; _personastack_status=$?; wait; exit $_personastack_status"
        let arguments = ["/bin/zsh", "-lc", script]
        let environment = childEnvironment().map { "\($0.key)=\($0.value)" }
        let cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { $0.withCString { strdup($0) } }
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { $0.withCString { strdup($0) } }
        guard cArguments.allSatisfy({ $0 != nil }), cEnvironment.allSatisfy({ $0 != nil }) else {
            cArguments.forEach { if let pointer = $0 { free(pointer) } }
            cEnvironment.forEach { if let pointer = $0 { free(pointer) } }
            throw DesktopShellError.invalidCommand
        }
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = cArguments + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = cEnvironment + [nil]
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argvBuffer.baseAddress, envBuffer.baseAddress)
            }
        }
        guard result == 0 else {
            throw result == EACCES || result == EPERM ? DesktopShellError.permissionDenied : DesktopShellError.invalidCommand
        }
        spawned = true
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        return (pid, input[1], output[0], error[0])
    }

    static func directoryError(errno: Int32) -> DesktopShellError {
        errno == EACCES || errno == EPERM ? .permissionDenied : .invalidWorkingDirectory
    }

    private static func wait(_ pid: pid_t, on executor: DesktopShellExecutor, id: UUID) {
        Task.detached(priority: .utility) {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            await executor.markLeaderExited(id)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            await executor.finish(id, waitStatus: status)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func pruneCompletedSessions() {
        let completed = sessions.filter { $0.value.state != .running }.sorted { $0.value.startedAt < $1.value.startedAt }
        let excess = max(0, sessions.count - Self.maximumRetainedSessions + 1)
        for (id, _) in completed.prefix(excess) { sessions.removeValue(forKey: id) }
    }

    private static func processGroupExists(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func finishInputWrite(_ id: UUID, byteCount: Int) {
        guard var session = sessions[id] else { return }
        session.queuedInputBytes = max(0, session.queuedInputBytes - byteCount)
        sessions[id] = session
    }

    private func closeInput(_ session: Session, id: UUID) async {
        await withCheckedContinuation { continuation in
            session.inputQueue.async {
                try? session.stdin.close()
                continuation.resume()
            }
        }
        sessions.removeValue(forKey: id)
    }
}
