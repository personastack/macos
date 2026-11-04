import Foundation
import Testing
@testable import PersonaStackCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Test(arguments: [false, true])
func iMessageSubprocessTransportStopsItsOwnedDescendantsAfterTimeoutOrCancellation(cancel: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("imsg")
    let identities = root.appendingPathComponent("owned-pids")
    let methods = String(decoding: try JSONEncoder().encode(IMessageRPCMethod.allCases.map(\.rawValue)), as: UTF8.self)
    let initialized = "{\"jsonrpc\":\"2.0\",\"id\":\"1:1\",\"result\":{\"protocol_version\":1,\"personastack_adapter_revision\":2,\"database\":{\"ready\":true},\"methods\":\(methods)}}"
    // This disposable fake starts one TERM-resistant descendant. It reads no
    // user files and writes only identities under this test's temporary directory.
    let script = """
    #!/bin/sh
    IFS= read -r first || exit 1
    printf '%s\\n' \(shellLiteral(initialized))
    IFS= read -r second || exit 1
    trap '' TERM
    /bin/sh -c 'trap "" TERM; while :; do :; done' &
    child=$!
    printf '%s\\n%s\\n' "$$" "$child" > \(shellLiteral(identities.path))
    while :; do :; done
    """
    try Data((script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let transport = IMessageSubprocessTransport(testExecutableURL: executable, testBundleURL: root)
    let client = IMessageRPCClient(transport: transport, readTimeoutSeconds: cancel ? 5 : 0.2, sendTimeoutSeconds: 1)
    _ = try await client.start()
    do {
        let request = Task { try await client.status() }
        if cancel {
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: identities.path) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            request.cancel()
        }
        let expected: IMessageRPCError = cancel ? .cancelled : .deadlineExceeded
        await #expect(throws: expected) { try await request.value }
        let text = try String(contentsOf: identities, encoding: .utf8)
        let ids = text.split(separator: "\n").compactMap { Int32($0) }
        #expect(ids.count == 2)
        if ids.count == 2 {
            let parentWasReaped = kill(ids[0], 0) == -1 && errno == ESRCH
            #expect(parentWasReaped)
            let descendant = try await awaitStoppedProcess(ids[1])
            #expect(descendant == .gone || descendant == .zombie,
                    "Owned descendant PID \(ids[1]) remained \(descendant.rawValue) after the bounded SIGKILL exit wait.")
        }
        await client.stop()
    } catch {
        await client.stop()
        throw error
    }
}

@Test func iMessageSubprocessTransportRejectsExecutableOutsideItsBundle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-bundle-\(UUID().uuidString)")
    let transport = IMessageSubprocessTransport(testExecutableURL: URL(fileURLWithPath: "/bin/imsg"), testBundleURL: root)
    await #expect(throws: IMessageRPCError.dependencyInvalid) { try await transport.launch() }
    await #expect(throws: IMessageRPCError.notStarted) { try await transport.read(maximumBytes: 128) }
}

private func shellLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

private enum FixtureProcessState: String { case gone, zombie, runnable, unknown }

private func awaitStoppedProcess(_ pid: pid_t) async throws -> FixtureProcessState {
    // Group SIGKILL is asynchronous. Reaping its direct parent does not wait for
    // an orphan's kernel exit or init's collection of the resulting zombie.
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    var state = fixtureProcessState(pid)
    while state != .gone && state != .zombie && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
        state = fixtureProcessState(pid)
    }
    return state
}

private func fixtureProcessState(_ pid: pid_t) -> FixtureProcessState {
    if kill(pid, 0) == -1 && errno == ESRCH { return .gone }
    #if canImport(Darwin)
    // The BSD kernel status distinguishes non-executable zombies from a live
    // descendant. kill(pid, 0) alone succeeds for both states on macOS.
    var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let queryCount = UInt32(query.count)
    var process = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&query, queryCount, &process, &size, nil, 0)
    guard result == 0, size == MemoryLayout<kinfo_proc>.stride, process.kp_proc.p_pid == pid else { return .unknown }
    return Int32(process.kp_proc.p_stat) == SZOMB ? .zombie : .runnable
    #elseif os(Linux)
    // Container PID1 may leave a killed orphan as a zombie. It cannot execute
    // AppleScript or hold provider work. Only our direct child is ours to reap.
    guard let value = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
          let end = value.lastIndex(of: ")") else { return .unknown }
    return value[value.index(after: end)...].split(separator: " ").first == "Z" ? .zombie : .runnable
    #else
    return .unknown
    #endif
}
