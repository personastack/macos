import Darwin
import Foundation
import Dispatch
import DesktopCLIProcess

private final class DesktopShellInputCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum DesktopProcessState: String, Sendable {
    case running
    case exited
    case cancelled
    case timedOut = "timed_out"
}

public enum DesktopProcessInput: Sendable {
    case data(Data)
    case close
    case interrupt
    case resize(rows: UInt16, columns: UInt16)
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

/// Byte storage is independent of process IO so cursor loss is deterministic in unit tests.
struct DesktopShellOutputBuffer {
    var chunks: [DesktopOutputChunk] = []
    var bufferedBytes = 0
    var nextSequence: UInt64 = 0
    var incompleteOutput = false
    let maximumBytes: Int

    init(maximumBytes: Int = DesktopShellExecutor.maximumBufferedBytesPerProcess) { self.maximumBytes = maximumBytes }

    mutating func append(_ data: Data, stream: DesktopOutputChunk.Stream) -> Bool {
        guard !data.isEmpty else { return false }
        nextSequence += 1
        chunks.append(DesktopOutputChunk(sequence: nextSequence, stream: stream, data: data))
        bufferedBytes += data.count
        var dropped = false
        while bufferedBytes > maximumBytes, !chunks.isEmpty {
            bufferedBytes -= chunks.removeFirst().data.count
            dropped = true
        }
        return dropped
    }

    var earliestCursor: UInt64 { chunks.first?.sequence ?? nextSequence + 1 }
    func hasGap(after cursor: UInt64) -> Bool { incompleteOutput || cursor < earliestCursor - 1 }
}

public enum DesktopTerminalMode: String, Sendable { case pipe, pty }

public struct DesktopProcessRead: Sendable {
    public let executionID: UUID
    public let chunks: [DesktopOutputChunk]
    public let nextCursor: UInt64
    public let earliestCursor: UInt64
    public let outputGap: Bool
    public let state: DesktopProcessState
    public let exitCode: Int32?
    public let signal: Int32?
    public let terminalMode: DesktopTerminalMode
    public let outputComplete: Bool
}

public struct DesktopShellDiagnostics: Sendable, Equatable {
    public let activeProcesses: Int
    public let openFileHandles: Int
    public let bufferedOutputBytes: Int
    public let outputGapsTotal: UInt64
}

public enum DesktopShellError: Error, Equatable {
    case invalidCommand
    case invalidWorkingDirectory
    case permissionDenied
    case tooManyProcesses
    case missingExecution
    case invalidInput
    case inputOutcomeUnknown
    case cancellationUnconfirmed
}

/// Bounded process sessions owned by a single already-authorized desktop control session.
/// The MCP and gateway layers must authorize each operation before calling this actor.
public protocol DesktopShellControlling: Sendable {
    func diagnostics() async -> DesktopShellDiagnostics
    func retainedExecutionIDs() async -> Set<UUID>
    func start(command: String, workingDirectory: String, timeout: TimeInterval, terminalMode: DesktopTerminalMode,
               rows: UInt16, columns: UInt16) async throws -> DesktopProcessRead
    func read(id: UUID, after cursor: UInt64, wait: Duration) async throws -> DesktopProcessRead
    func write(id: UUID, input: DesktopProcessInput) async throws
    func status(id: UUID) async throws -> DesktopProcessRead
    func cancel(id: UUID) async throws
    func requestStopAll() async
    func closeAll() async -> Bool
}

public actor DesktopShellExecutor: DesktopShellControlling {
    public static let maximumCommandBytes = 64 * 1024
    public static let maximumInputBytes = 32 * 1024
    public static let maximumReadBytes = 1024 * 1024
    public static let maximumBufferedBytesPerProcess = 4 * 1024 * 1024
    public static let maximumQueuedInputBytes = 128 * 1024
    public static let maximumProcesses = 4
    public static let maximumRetainedSessions = 16
    public static let maximumTimeout: TimeInterval = 30 * 60

    private struct Session {
        let terminalMode: DesktopTerminalMode
        let processID: pid_t
        let stdin: FileHandle
        let inputQueue: DispatchQueue
        let inputCancellation: DesktopShellInputCancellation
        var output = DesktopShellOutputBuffer()
        var state: DesktopProcessState = .running
        var exitCode: Int32?
        var signal: Int32?
        var outputReaders = 2
        var processTerminated = false
        var processGroupCleanupConfirmed = false
        var terminalState: DesktopProcessState?
        var requestedTerminalState: DesktopProcessState?
        var queuedInputBytes = 0
        var pendingInputOperations = 0
        var inputClosed = false
        var readerDrainDeadline: ContinuousClock.Instant?
        var forceCloseReaders = false
        let startedAt: ContinuousClock.Instant
        var deadlineTask: Task<Void, Never>?
        var isSettled: Bool {
            state != .running && outputReaders == 0 && (!processTerminated || processGroupCleanupConfirmed)
        }
    }

    private var sessions: [UUID: Session] = [:]
    private var outputGapsTotal: UInt64 = 0

    public init() {}

    public func retainedExecutionIDs() -> Set<UUID> { Set(sessions.keys) }

#if DEBUG
    func inputClosePendingForTesting(_ id: UUID) -> Bool { sessions[id]?.inputClosed == true }
#endif

    public func diagnostics() -> DesktopShellDiagnostics {
        DesktopShellDiagnostics(
            activeProcesses: sessions.values.filter { $0.state == .running }.count,
            openFileHandles: sessions.values.reduce(0) { $0 + $1.outputReaders + ($1.inputClosed ? 0 : 1) },
            bufferedOutputBytes: sessions.values.reduce(0) { $0 + $1.output.bufferedBytes },
            outputGapsTotal: outputGapsTotal
        )
    }

    public func start(command: String, workingDirectory: String, timeout: TimeInterval = 300,
                      terminalMode: DesktopTerminalMode = .pipe, rows: UInt16 = 24, columns: UInt16 = 80) async throws -> DesktopProcessRead {
        try DesktopControlExecution.check()
        try Self.validateStart(command: command, workingDirectory: workingDirectory, timeout: timeout, rows: rows, columns: columns)
        pruneCompletedSessions()
        guard sessions.values.filter({ $0.state == .running || $0.outputReaders > 0 }).count < Self.maximumProcesses else {
            throw DesktopShellError.tooManyProcesses
        }
        let boundedTimeout = timeout
        let id = UUID()
        let child = try Self.spawn(command: command, workingDirectory: workingDirectory, mode: terminalMode, rows: rows, columns: columns)
        var session = Session(terminalMode: terminalMode, processID: child.pid, stdin: FileHandle(fileDescriptor: child.stdin, closeOnDealloc: true),
                              inputQueue: DispatchQueue(label: "ai.personastack.desktop.shell.input.\(id.uuidString)"),
                              inputCancellation: DesktopShellInputCancellation(),
                              outputReaders: terminalMode == .pty ? 1 : 2, startedAt: .now)
        session.deadlineTask = Task.detached { [weak self] in
            do { try await Task.sleep(for: .seconds(boundedTimeout)) } catch { return }
            await self?.timeout(id)
        }
        sessions[id] = session
        Self.forward(FileHandle(fileDescriptor: child.stdout, closeOnDealloc: true), stream: .stdout, to: self, id: id)
        if child.stderr >= 0 {
            Self.forward(FileHandle(fileDescriptor: child.stderr, closeOnDealloc: true), stream: .stderr, to: self, id: id)
        }
        Self.wait(child.pid, on: self, id: id)
        do {
            return try await read(id: id, after: 0, wait: .zero)
        } catch {
            // The caller has not received the execution ID yet and cannot clean it up.
            await cancelAfterFailure(id: id)
            throw error
        }
    }

    private static func validateStart(command: String, workingDirectory: String, timeout: TimeInterval,
                                      rows: UInt16, columns: UInt16) throws {
        guard !command.isEmpty, !command.contains("\0"), command.utf8.count <= Self.maximumCommandBytes else { throw DesktopShellError.invalidCommand }
        guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0"), workingDirectory.utf8.count <= 4096 else {
            throw DesktopShellError.invalidWorkingDirectory
        }
        let accessResult = workingDirectory.withCString { Darwin.access($0, X_OK) }
        guard accessResult == 0 else { throw Self.directoryError(errno: errno) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopShellError.invalidWorkingDirectory
        }
        guard timeout.isFinite, timeout >= 1, timeout <= Self.maximumTimeout,
              rows > 0, rows <= 1000, columns > 0, columns <= 1000 else { throw DesktopShellError.invalidInput }
    }

    func cancelAfterFailure(id: UUID) async {
        // A cancelled task or expired command deadline must still release its child.
        await Task.detached { try? await self.stopProcess(id: id) }.value
    }

    public func read(id: UUID, after cursor: UInt64, wait: Duration = .zero) async throws -> DesktopProcessRead {
        try DesktopControlExecution.check()
        let end = ContinuousClock.now + min(max(wait, .zero), .seconds(10))
        while true {
            try DesktopControlExecution.check()
            guard let session = sessions[id] else { throw DesktopShellError.missingExecution }
            guard cursor <= session.output.nextSequence else { throw DesktopShellError.invalidInput }
            let earliest = session.output.earliestCursor
            let gap = session.output.hasGap(after: cursor)
            let selected = session.output.chunks.filter { $0.sequence > cursor }
            let chunks = Self.bounded(selected, limit: Self.maximumReadBytes)
            let nextCursor = chunks.last?.sequence ?? cursor
            if !chunks.isEmpty || session.outputReaders == 0 || ContinuousClock.now >= end {
                return DesktopProcessRead(executionID: id, chunks: chunks, nextCursor: nextCursor,
                                          earliestCursor: earliest, outputGap: gap, state: session.state,
                                          exitCode: session.exitCode, signal: session.signal, terminalMode: session.terminalMode, outputComplete: session.outputReaders == 0)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    public func write(id: UUID, input: DesktopProcessInput) async throws {
        try DesktopControlExecution.check()
        switch input {
        case .data(let data): try await sendData(data, id: id)
        case .close: try await sendEOF(id: id)
        case .interrupt: try interrupt(id: id)
        case .resize(let rows, let columns): try resize(id: id, rows: rows, columns: columns)
        }
    }

    private func sendData(_ data: Data, id: UUID) async throws {
        guard !data.isEmpty, data.count <= Self.maximumInputBytes else { throw DesktopShellError.invalidInput }
        guard var session = sessions[id], session.terminalState == nil, !session.processTerminated, !session.inputClosed,
              session.queuedInputBytes + data.count <= Self.maximumQueuedInputBytes else { throw DesktopShellError.invalidInput }
        session.queuedInputBytes += data.count
        session.pendingInputOperations += 1
        sessions[id] = session
        try await performQueuedInput(id: id, session: session, data: data)
    }

    private func sendEOF(id: UUID) async throws {
        guard var session = sessions[id], session.terminalState == nil, !session.processTerminated, !session.inputClosed else {
            throw DesktopShellError.missingExecution
        }
        var eofData: Data?
        if session.terminalMode == .pty {
            var settings = termios()
            guard tcgetattr(session.stdin.fileDescriptor, &settings) == 0 else { throw DesktopShellError.invalidInput }
            let eof = withUnsafeBytes(of: settings.c_cc) { $0[Int(VEOF)] }
            // Two EOF characters flush a pending canonical line, then signal EOF without closing output.
            eofData = Data([eof, eof])
        }
        session.inputClosed = true
        session.pendingInputOperations += 1
        sessions[id] = session
        try await performQueuedInput(id: id, session: session, data: eofData)
    }

    private func interrupt(id: UUID) throws {
        guard let session = sessions[id], session.terminalState == nil, !session.processTerminated else { throw DesktopShellError.missingExecution }
        let group = session.terminalMode == .pty ? tcgetpgrp(session.stdin.fileDescriptor) : session.processID
        guard group > 0, kill(-group, SIGINT) == 0 else { throw DesktopShellError.missingExecution }
    }

    private func resize(id: UUID, rows: UInt16, columns: UInt16) throws {
        guard let session = sessions[id], session.terminalMode == .pty, session.terminalState == nil, !session.processTerminated,
              rows > 0, rows <= 1000, columns > 0, columns <= 1000 else { throw DesktopShellError.invalidInput }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(session.stdin.fileDescriptor, TIOCSWINSZ, &size) == 0 else { throw DesktopShellError.invalidInput }
    }

    public func cancel(id: UUID) async throws {
        try DesktopControlExecution.check()
        try await stopProcess(id: id)
    }

    private func stopProcess(id: UUID) async throws {
        guard var session = sessions[id] else { throw DesktopShellError.missingExecution }
        session.inputCancellation.cancel()
        sessions[id] = session
        if session.processTerminated {
            guard session.processGroupCleanupConfirmed else { throw DesktopShellError.cancellationUnconfirmed }
            return
        }
        if !Self.processGroupExists(session.processID) { return }
        session.requestedTerminalState = .cancelled
        sessions[id] = session
        _ = kill(-session.processID, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        guard let current = sessions[id] else { throw DesktopShellError.missingExecution }
        if current.processTerminated {
            guard current.processGroupCleanupConfirmed else { throw DesktopShellError.cancellationUnconfirmed }
            return
        }
        if Self.processGroupExists(current.processID) {
            _ = kill(-current.processID, SIGKILL)
        }
        let cleanupDeadline = ContinuousClock.now + .seconds(3.5)
        while ContinuousClock.now < cleanupDeadline {
            guard let latest = sessions[id] else { throw DesktopShellError.missingExecution }
            if latest.processTerminated {
                guard latest.processGroupCleanupConfirmed else { throw DesktopShellError.cancellationUnconfirmed }
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw DesktopShellError.cancellationUnconfirmed
    }

    public func status(id: UUID) throws -> DesktopProcessRead {
        try DesktopControlExecution.check()
        guard let session = sessions[id] else { throw DesktopShellError.missingExecution }
        let earliest = session.output.earliestCursor
        return DesktopProcessRead(executionID: id, chunks: [], nextCursor: session.output.nextSequence,
                                  earliestCursor: earliest, outputGap: session.output.incompleteOutput || earliest > 1, state: session.state,
                                  exitCode: session.exitCode, signal: session.signal, terminalMode: session.terminalMode, outputComplete: session.outputReaders == 0)
    }

    @discardableResult
    public func closeAll() async -> Bool {
        for session in sessions.values { session.inputCancellation.cancel() }
        requestStopAll()
        let groupsToStop = sessions.filter { !$0.value.processTerminated }.map(\.key)
        for id in groupsToStop {
            do { try await stopProcess(id: id) }
            catch { /* The process-group check below is authoritative. */ }
        }
        for (id, var session) in Array(sessions) where session.outputReaders > 0 {
            session.forceCloseReaders = true
            sessions[id] = session
        }
        for _ in 0..<40 {
            if sessions.values.allSatisfy(\.isSettled) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard sessions.values.allSatisfy(\.isSettled) else {
            return false
        }
        for (id, session) in Array(sessions) {
            session.deadlineTask?.cancel()
            await closeInput(session, id: id)
        }
        sessions.removeAll()
        return true
    }

    public func requestStopAll() {
        for session in sessions.values { session.inputCancellation.cancel() }
        let processGroups = sessions.compactMap { id, session -> (UUID, pid_t)? in
            guard !session.processTerminated else { return nil }
            return (id, session.processID)
        }
        for (id, processID) in processGroups {
            guard var session = sessions[id], session.processID == processID else { continue }
            session.requestedTerminalState = .cancelled
            session.inputCancellation.cancel()
            sessions[id] = session
            _ = kill(-processID, SIGTERM)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.forceStopUnsettledProcesses(processGroups)
        }
    }

    private func forceStopUnsettledProcesses(_ processGroups: [(UUID, pid_t)]) {
        for (id, processID) in processGroups {
            guard let session = sessions[id], session.processID == processID,
                  !session.processTerminated, Self.processGroupExists(processID) else { continue }
            _ = kill(-processID, SIGKILL)
        }
    }

    private func append(_ data: Data, stream: DesktopOutputChunk.Stream, id: UUID) {
        guard var session = sessions[id], !data.isEmpty else { return }
        if session.output.append(data, stream: stream) { outputGapsTotal += 1 }
        sessions[id] = session
    }

    private func finish(_ id: UUID, waitStatus: Int32?) {
        guard var session = sessions[id] else { return }
        session.inputCancellation.cancel()
        if !session.inputClosed {
            session.inputClosed = true
            let inputHandle = session.stdin
            session.inputQueue.async { try? inputHandle.close() }
        }
        if let waitStatus {
            let signal = waitStatus & 0x7f
            session.terminalState = session.terminalState ?? session.requestedTerminalState ?? (signal == 0 ? .exited : .cancelled)
            session.exitCode = signal == 0 ? (waitStatus >> 8) & 0xff : nil
            session.signal = signal == 0 ? nil : signal
        } else if waitStatus == nil {
            session.processGroupCleanupConfirmed = false
        }
        Self.finishIfDrained(&session)
        sessions[id] = session
    }

    private func markLeaderExited(_ id: UUID, processGroupCleanupConfirmed: Bool) {
        guard let current = sessions[id], !current.processTerminated else { return }
        var session = current
        session.processGroupCleanupConfirmed = processGroupCleanupConfirmed
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
        session.output.incompleteOutput = true
        sessions[id] = session
        return true
    }

    private static func finishIfDrained(_ session: inout Session) {
        guard session.processTerminated else { return }
        session.state = session.terminalState ?? session.state
        if session.outputReaders == 0 { session.deadlineTask?.cancel() }
    }

    private func timeout(_ id: UUID) async {
        guard var session = sessions[id], session.state == .running, !session.processTerminated else { return }
        session.requestedTerminalState = .timedOut
        session.terminalState = .timedOut
        session.inputCancellation.cancel()
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
                // The descriptor is nonblocking. Suspend instead of blocking a
                // cooperative executor thread while other commands need cleanup.
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    static func bounded(_ chunks: [DesktopOutputChunk], limit: Int) -> [DesktopOutputChunk] {
        var result: [DesktopOutputChunk] = []
        var size = 0
        for chunk in chunks {
            if size + chunk.data.count > limit { break }
            result.append(chunk)
            size += chunk.data.count
        }
        return result
    }

    private static func spawn(command: String, workingDirectory: String, mode: DesktopTerminalMode,
                              rows: UInt16, columns: UInt16) throws -> (pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32) {
        // Resolve the desktop account shell, rather than a WebView or remote-selected executable.
        var buffer = [CChar](repeating: 0, count: 16384)
        let identity = try buffer.withUnsafeMutableBufferPointer { storage -> (shell: String, home: String, user: String) in
            var account = passwd()
            var resolved: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &account, storage.baseAddress, storage.count, &resolved) == 0,
                  resolved != nil, let shell = account.pw_shell, let home = account.pw_dir, let user = account.pw_name else {
                throw DesktopShellError.invalidCommand
            }
            return (String(cString: shell), String(cString: home), String(cString: user))
        }
        let shell = identity.shell
        guard shell.hasPrefix("/"), !shell.isEmpty else { throw DesktopShellError.invalidCommand }
        // Command is intentionally shell code. Cwd stays a chdir argument, never shell source.
        let arguments = ["-" + (shell as NSString).lastPathComponent, "-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = shell
        environment["HOME"] = identity.home
        environment["USER"] = identity.user
        environment["LOGNAME"] = identity.user
        if mode == .pty { environment["TERM"] = environment["TERM"] ?? "xterm-256color" }
        let argumentPointers = arguments.map { strdup($0) }
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else {
            throw DesktopShellError.invalidCommand
        }
        var argv = argumentPointers + [nil]
        var envp = environmentPointers + [nil]
        var child = PSDesktopCLIChild()
        let result = argv.withUnsafeMutableBufferPointer { arguments in
            envp.withUnsafeMutableBufferPointer { environment in
                ps_desktop_cli_spawn(shell, arguments.baseAddress, environment.baseAddress,
                                     workingDirectory, mode == .pty ? 1 : 0, rows, columns, &child)
            }
        }
        guard result == 0 else {
            throw result == EACCES || result == EPERM ? DesktopShellError.permissionDenied : DesktopShellError.invalidCommand
        }
        _ = fcntl(child.input, F_SETNOSIGPIPE, 1)
        _ = fcntl(child.input, F_SETFL, fcntl(child.input, F_GETFL) | O_NONBLOCK)
        return (child.pid, child.input, child.output, child.error)
    }

    static func directoryError(errno: Int32) -> DesktopShellError {
        errno == EACCES || errno == EPERM ? .permissionDenied : .invalidWorkingDirectory
    }

    private static func wait(_ pid: pid_t, on executor: DesktopShellExecutor, id: UUID) {
        Task.detached(priority: .utility) {
            var info = siginfo_t()
            var waitResult: Int32
            while true {
                waitResult = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
                if waitResult == 0 && info.si_pid != 0 { break }
                if waitResult == -1 && errno != EINTR { break }
                // Waiting for a child must not occupy a cooperative executor
                // thread needed by cancellation, deadlines, or pipe readers.
                try? await Task.sleep(for: .milliseconds(25))
            }
            var cleanupConfirmed = false
            if waitResult == 0 {
                cleanupConfirmed = await stopLiveProcesses(inProcessGroup: pid)
            }
            await executor.markLeaderExited(id, processGroupCleanupConfirmed: cleanupConfirmed)
            var status: Int32 = 0
            var reapResult = waitpid(pid, &status, 0)
            while reapResult == -1 && errno == EINTR {
                reapResult = waitpid(pid, &status, 0)
            }
            await executor.finish(id, waitStatus: reapResult == pid ? status : nil)
        }
    }

    private func pruneCompletedSessions() {
        let completed = sessions.filter { $0.value.state != .running && $0.value.outputReaders == 0 && $0.value.pendingInputOperations == 0 }
            .sorted { $0.value.startedAt < $1.value.startedAt }
        let excess = max(0, sessions.count - Self.maximumRetainedSessions + 1)
        for (id, _) in completed.prefix(excess) { sessions.removeValue(forKey: id) }
    }

    private static func processGroupExists(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func stopLiveProcesses(inProcessGroup processGroupID: pid_t) async -> Bool {
        var signalSent = false
        var consecutiveEmptySnapshots = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            switch hasLiveProcess(inProcessGroup: processGroupID) {
            case .some(false):
                consecutiveEmptySnapshots += 1
                if consecutiveEmptySnapshots == 2 { return true }
            case .some(true):
                consecutiveEmptySnapshots = 0
                if !signalSent {
                    let result = kill(-processGroupID, SIGKILL)
                    guard result == 0 || errno == ESRCH else { return false }
                    signalSent = true
                }
            case nil:
                consecutiveEmptySnapshots = 0
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func hasLiveProcess(inProcessGroup processGroupID: pid_t) -> Bool? {
        var processIDs = [pid_t](repeating: 0, count: 256)
        let bufferSize = Int32(processIDs.count * MemoryLayout<pid_t>.stride)
        let bytes = processIDs.withUnsafeMutableBufferPointer {
            proc_listpgrppids(processGroupID, $0.baseAddress, bufferSize)
        }
        guard bytes >= 0, Int(bytes) < processIDs.count else { return nil }
        let count = Int(bytes)
        for processID in processIDs.prefix(count) {
            var info = proc_bsdinfo()
            let infoBytes = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info,
                                         Int32(MemoryLayout<proc_bsdinfo>.size))
            if infoBytes == 0 && errno == ESRCH { continue }
            guard infoBytes == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_pid == UInt32(processID),
                  info.pbi_pgid == UInt32(processGroupID) else { return nil }
            if info.pbi_status != UInt32(SZOMB) { return true }
        }
        return false
    }

    private func performQueuedInput(id: UUID, session: Session, data: Data?) async throws {
        let deadline = DesktopControlExecution.deadline
        let commandCancellation = DesktopShellInputCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.inputQueue.async {
                    var closeStarted = false
                    let result = Result<Void, Error> {
                        if let data {
                            try Self.writeInput(data, descriptor: session.stdin.fileDescriptor,
                                                cancellation: session.inputCancellation,
                                                commandCancellation: commandCancellation, deadline: deadline)
                        } else {
                            try Self.checkInput(cancellation: session.inputCancellation,
                                                commandCancellation: commandCancellation, deadline: deadline)
                            closeStarted = true
                            do { try session.stdin.close() }
                            catch { throw DesktopShellError.inputOutcomeUnknown }
                        }
                    }
                    let reopenInput = data == nil && !closeStarted
                    Task {
                        await self.finishInputOperation(id, byteCount: data?.count ?? 0, reopenInput: reopenInput)
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            commandCancellation.cancel()
        }
    }

    private func finishInputOperation(_ id: UUID, byteCount: Int, reopenInput: Bool) {
        guard var session = sessions[id] else { return }
        session.queuedInputBytes = max(0, session.queuedInputBytes - byteCount)
        session.pendingInputOperations = max(0, session.pendingInputOperations - 1)
        if reopenInput { session.inputClosed = false }
        sessions[id] = session
    }

    private static func checkInput(cancellation: DesktopShellInputCancellation,
                                   commandCancellation: DesktopShellInputCancellation,
                                   deadline: Date?, bytesWritten: Int = 0) throws {
        if let deadline, deadline <= Date() {
            if bytesWritten > 0 { throw DesktopShellError.inputOutcomeUnknown }
            throw DesktopControlExecution.Expired()
        }
        if cancellation.isCancelled() || commandCancellation.isCancelled() {
            if bytesWritten > 0 { throw DesktopShellError.inputOutcomeUnknown }
            throw CancellationError()
        }
    }

    private static func writeInput(_ data: Data, descriptor: Int32,
                                   cancellation: DesktopShellInputCancellation,
                                   commandCancellation: DesktopShellInputCancellation, deadline: Date?) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { throw DesktopShellError.invalidInput }
            var offset = 0
            while offset < data.count {
                try checkInput(cancellation: cancellation, commandCancellation: commandCancellation,
                               deadline: deadline, bytesWritten: offset)
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&state, 1, 100)
                    continue
                }
                if offset > 0 { throw DesktopShellError.inputOutcomeUnknown }
                throw DesktopShellError.invalidInput
            }
        }
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

public extension DesktopShellError {
    var code: String {
        switch self {
        case .invalidCommand, .invalidWorkingDirectory, .invalidInput: "invalid_arguments"
        case .permissionDenied: "desktop_permission_denied"
        case .tooManyProcesses: "desktop_process_limit"
        case .missingExecution: "desktop_execution_not_found"
        case .inputOutcomeUnknown, .cancellationUnconfirmed: "outcome_unknown"
        }
    }
    var message: String {
        switch self {
        case .invalidCommand, .invalidWorkingDirectory, .invalidInput: "The desktop CLI arguments are invalid."
        case .permissionDenied: "The desktop account does not have OS permission for this operation."
        case .tooManyProcesses: "Four desktop commands are already running. Finish or cancel one before starting another."
        case .missingExecution: "This execution is unavailable to the current control lease."
        case .inputOutcomeUnknown, .cancellationUnconfirmed: "The CLI operation outcome is uncertain. Read its current state before acting again."
        }
    }
}
