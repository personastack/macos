import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resolves an embedded executable only. No page, caller or PATH selects a program.
public final class IMessageSubprocessTransport: IMessageRPCTransport, @unchecked Sendable {
    private let executableURL: URL?
    private let bundleURL: URL
    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "ai.personastack.imessage.stdout")
    private let writeQueue = DispatchQueue(label: "ai.personastack.imessage.stdin")
    private var child: Child?
    private var retiring = false
    private var retiringPipes = 0
    private var duplicatedPipes = 0

    private struct Child: @unchecked Sendable {
        let pid: pid_t
        let processGroup: pid_t
        let input: FileHandle
        let output: FileHandle
    }

    public init(bundle: Bundle = .main) {
        executableURL = bundle.url(forAuxiliaryExecutable: "imsg")
        bundleURL = bundle.bundleURL
    }

    internal init(testExecutableURL: URL, testBundleURL: URL) {
        executableURL = testExecutableURL
        bundleURL = testBundleURL
    }

    public func launch() async throws {
        try launchOwnedProcess()
    }

    private func launchOwnedProcess() throws {
        lock.lock()
        defer { lock.unlock() }
        guard child == nil, !retiring else { throw IMessageRPCError.alreadyStarted }
        guard let executableURL, executableURL.lastPathComponent == "imsg",
              executableURL.resolvingSymlinksInPath().path.hasPrefix(bundleURL.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw IMessageRPCError.dependencyInvalid
        }
        let input = Pipe(), output = Pipe()
        let descriptors = [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                           output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor]
        guard descriptors.allSatisfy({ $0 >= 3 && fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }) else {
            throw IMessageRPCError.processExited
        }
        let pid = try Self.spawn(executable: executableURL.path, input: input.fileHandleForReading.fileDescriptor,
                                 output: output.fileHandleForWriting.fileDescriptor, descriptors: descriptors)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        guard pid > 1, pid != getpgrp(), getpgid(pid) == pid else {
            // A direct unreaped child is ours, but an unverified process group is not.
            _ = kill(pid, SIGKILL)
            Self.reap(pid)
            throw IMessageRPCError.dependencyInvalid
        }
        child = Child(pid: pid, processGroup: pid, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }

    private static func spawn(executable: String, input: Int32, output: Int32, descriptors: [Int32]) throws -> pid_t {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw IMessageRPCError.processExited }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw IMessageRPCError.processExited }
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        var emptyMask = sigset_t(), defaultSignals = sigset_t()
        sigemptyset(&emptyMask); sigemptyset(&defaultSignals); sigaddset(&defaultSignals, SIGPIPE)
        #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        guard posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw IMessageRPCError.processExited
        }
        for descriptor in descriptors {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { throw IMessageRPCError.processExited }
        }
        let argumentValues: [String] = ["imsg", "rpc"]
        let environmentValues: [String] = ["HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8"]
        let arguments = argumentValues.map { value in value.withCString { strdup($0) } }
        let environment = environmentValues.map { value in value.withCString { strdup($0) } }
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw IMessageRPCError.processExited }
        var argv = arguments + [nil], envp = environment + [nil]
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argumentBuffer in
            envp.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&pid, executable, &actions, &attributes, argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
        guard result == 0 else { throw IMessageRPCError.processExited }
        return pid
    }

    public func read(maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 8192 else { throw IMessageRPCError.invalidArguments }
        let descriptor = try duplicateDescriptor(output: true)
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                defer { self.closeDuplicate(descriptor) }
                var bytes = [UInt8](repeating: 0, count: maximumBytes)
                var count: Int
                repeat {
                    count = bytes.withUnsafeMutableBytes { buffer in
                        Self.systemRead(descriptor, buffer.baseAddress!, maximumBytes)
                    }
                } while count < 0 && errno == EINTR
                guard count >= 0 else { continuation.resume(throwing: IMessageRPCError.processExited); return }
                continuation.resume(returning: Data(bytes.prefix(count)))
            }
        }
    }

    public func write(_ data: Data) async throws {
        guard data.count <= IMessageRPCClient.maximumFrameBytes else { throw IMessageRPCError.frameTooLarge }
        let descriptor = try duplicateDescriptor(output: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                defer { self.closeDuplicate(descriptor) }
                do { try Self.writeAll(data, descriptor: descriptor); continuation.resume() }
                catch { continuation.resume(throwing: IMessageRPCError.processExited) }
            }
        }
    }

    public func terminate() async {
        guard let owned = takeChild() else { return }
        try? owned.input.close()
        setRetiringPipes(1)
        // The direct child remains unreaped until both group signals are sent.
        // Its reserved PID prevents this group identity being reused by a foreign owner.
        if owned.pid > 1, owned.processGroup == owned.pid, owned.processGroup != getpgrp() {
            _ = kill(-owned.processGroup, SIGTERM)
            try? await Task.sleep(for: .seconds(1))
            _ = kill(-owned.processGroup, SIGKILL)
        }
        await Task.detached { Self.reap(owned.pid) }.value
        try? owned.output.close()
        finishRetiring()
    }

    public func resources() async -> IMessageProviderResources? { resourceSnapshot() }

    private func resourceSnapshot() -> IMessageProviderResources {
        lock.lock(); defer { lock.unlock() }
        return .init(ownedChildren: (child == nil ? 0 : 1) + (retiring ? 1 : 0),
            ownedPipeHandles: (child == nil ? 0 : 2) + retiringPipes + duplicatedPipes)
    }

    private func setRetiringPipes(_ count: Int) { lock.lock(); defer { lock.unlock() }; retiringPipes = count }
    private func finishRetiring() { lock.lock(); defer { lock.unlock() }; retiring = false; retiringPipes = 0 }
    private func closeDuplicate(_ descriptor: Int32) {
        _ = close(descriptor)
        lock.lock(); defer { lock.unlock() }; duplicatedPipes -= 1
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
    }

    private func duplicateDescriptor(output: Bool) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let child else { throw IMessageRPCError.notStarted }
        let descriptor = dup(output ? child.output.fileDescriptor : child.input.fileDescriptor)
        guard descriptor >= 0 else { throw IMessageRPCError.processExited }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = close(descriptor)
            throw IMessageRPCError.processExited
        }
        duplicatedPipes += 1
        return descriptor
    }

    private static func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
        #else
        Glibc.read(descriptor, buffer, count)
        #endif
    }

    private static func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(descriptor, buffer, count)
        #else
        Glibc.write(descriptor, buffer, count)
        #endif
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        // Block SIGPIPE on this IO thread only. A closed provider pipe is an
        // uncertain transport failure, never a process-wide signal policy.
        var blocked = sigset_t(), previous = sigset_t(), pendingBefore = sigset_t()
        sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE)
        sigpending(&pendingBefore)
        guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { throw IMessageRPCError.processExited }
        defer {
            var pendingNow = sigset_t()
            sigpending(&pendingNow)
            if sigismember(&pendingBefore, SIGPIPE) == 0 && sigismember(&pendingNow, SIGPIPE) == 1 {
                var signal: Int32 = 0
                _ = sigwait(&blocked, &signal)
            }
            _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = systemWrite(descriptor, base.advanced(by: offset), data.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw IMessageRPCError.processExited }
                offset += written
            }
        }
    }

    private func takeChild() -> Child? {
        lock.lock(); defer { lock.unlock() }
        if child != nil { retiring = true; retiringPipes = 2 }
        defer { child = nil }
        return child
    }
}
