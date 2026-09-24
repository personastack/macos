import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopShellExecutorTests {
    @Test func commandReturnsOutputBeforeExitAndPreservesStream() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "printf 'first'; sleep 1.5; printf 'second'; printf 'problem' >&2", workingDirectory: "/tmp")
        #expect(started.state == .running)
        var completed = try await executor.read(id: started.executionID, after: started.nextCursor, wait: .seconds(3))
        var chunks = started.chunks + completed.chunks
        while completed.state == .running {
            completed = try await executor.read(id: started.executionID, after: completed.nextCursor, wait: .seconds(3))
            chunks.append(contentsOf: completed.chunks)
        }
        #expect(completed.state == .exited)
        let stdout = chunks.filter { $0.stream == .stdout }.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        let stderr = chunks.filter { $0.stream == .stderr }.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        #expect(stdout.contains("first"))
        #expect(stdout.contains("second"))
        #expect(stderr.contains("problem"))
        #expect(completed.exitCode == 0)
        await executor.closeAll()
    }

    @Test func commandAcceptsInputWhileRunning() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "read answer; printf 'received:%s' \"$answer\"", workingDirectory: "/tmp")
        #expect(started.state == .running)
        try await executor.write(id: started.executionID, input: .data(Data("hello\n".utf8)))
        var completed = try await executor.read(id: started.executionID, after: 0, wait: .seconds(3))
        var chunks = completed.chunks
        while completed.state == .running {
            completed = try await executor.read(id: started.executionID, after: completed.nextCursor, wait: .seconds(3))
            chunks.append(contentsOf: completed.chunks)
        }
        let output = chunks.map { String(decoding: $0.data, as: UTF8.self) }.joined()
        #expect(completed.state == .exited)
        #expect(output.contains("received:hello"))
        await executor.closeAll()
    }

    @Test func commandPreservesNoNewlineOutputAcrossSplitUTF8Writes() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "printf '\\342'; sleep 0.2; printf '\\202\\254'", workingDirectory: "/tmp")
        var result = started
        var chunks = started.chunks
        while result.state == .running {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .seconds(2))
            chunks.append(contentsOf: result.chunks)
        }
        let output = Data(chunks.filter { $0.stream == .stdout }.flatMap(\.data))
        #expect(output == Data([0xE2, 0x82, 0xAC]))
        await executor.closeAll()
    }

    @Test func closingStdinDeliversEOFToTheRunningProcess() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "cat >/dev/null; printf 'stdin-closed'", workingDirectory: "/tmp")
        #expect(started.state == .running)
        try await executor.write(id: started.executionID, input: .close)
        var result = try await executor.read(id: started.executionID, after: 0, wait: .seconds(3))
        var chunks = result.chunks
        while result.state == .running {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .seconds(3))
            chunks.append(contentsOf: result.chunks)
        }
        #expect(result.state == .exited)
        #expect(chunks.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains("stdin-closed"))
        await executor.closeAll()
    }

    @Test func cancellingManagedProcessStopsIt() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "sleep 20", workingDirectory: "/tmp")
        try await executor.cancel(id: started.executionID)
        var ended = try await executor.status(id: started.executionID)
        let deadline = ContinuousClock.now + .seconds(5)
        while ended.state == .running && ContinuousClock.now < deadline {
            ended = try await executor.read(id: started.executionID, after: 0, wait: .milliseconds(250))
        }
        #expect(ended.state == .cancelled)
        await executor.closeAll()
    }

    @Test func commandValidatesWorkingDirectoryAndInputBounds() async throws {
        let executor = DesktopShellExecutor()
        #expect(DesktopShellExecutor.maximumTimeout == 30 * 60)
        #expect(DesktopShellExecutor.directoryError(errno: EACCES) == .permissionDenied)
        #expect(DesktopShellExecutor.directoryError(errno: EPERM) == .permissionDenied)
        #expect(DesktopShellExecutor.directoryError(errno: ENOENT) == .invalidWorkingDirectory)
        await #expect(throws: DesktopShellError.invalidWorkingDirectory) {
            try await executor.start(command: "true", workingDirectory: "relative")
        }
        await #expect(throws: DesktopShellError.invalidInput) {
            try await executor.write(id: UUID(), input: .data(Data(repeating: 1, count: 32 * 1024 + 1)))
        }
    }

    @Test func outputRingReportsWhenTheReaderFallsBehind() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "head -c 5000000 /dev/zero", workingDirectory: "/tmp", timeout: 10)
        var final = try await executor.read(id: started.executionID, after: 0, wait: .seconds(1))
        let deadline = ContinuousClock.now + .seconds(10)
        var observedGap = final.outputGap
        while final.state == .running && ContinuousClock.now < deadline {
            final = try await executor.read(id: started.executionID, after: final.nextCursor, wait: .milliseconds(500))
            observedGap = observedGap || final.outputGap
        }
        #expect(final.state == .exited)
        #expect(observedGap)
        #expect(final.earliestCursor > 1)
        #expect(final.chunks.reduce(0) { $0 + $1.data.count } <= DesktopShellExecutor.maximumReadBytes)
        await executor.closeAll()
    }

    @Test func shortCommandOutputIsAvailableBeforeTerminalState() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "printf 'complete-output'", workingDirectory: "/tmp")
        var result = started
        var output = started.chunks
        while result.state == .running {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .seconds(2))
            output.append(contentsOf: result.chunks)
        }
        #expect(result.state == .exited)
        #expect(output.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains("complete-output"))
        #expect(try await executor.status(id: started.executionID).nextCursor == 0)
        await executor.closeAll()
    }

    @Test func blockedInputDoesNotPreventCancellation() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "sleep 20", workingDirectory: "/tmp")
        let writer = Task { try await executor.write(id: started.executionID, input: .data(Data(repeating: 97, count: 32 * 1024))) }
        try await Task.sleep(for: .milliseconds(100))
        try await executor.cancel(id: started.executionID)
        _ = try? await writer.value
        var result = try await executor.read(id: started.executionID, after: 0, wait: .seconds(2))
        let deadline = ContinuousClock.now + .seconds(5)
        while result.state == .running && ContinuousClock.now < deadline {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .milliseconds(250))
        }
        #expect(result.state == .cancelled)
        await executor.closeAll()
    }

    @Test func foregroundShellTracksAndCancelsOrdinaryBackgroundJobs() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "sleep 20 & printf 'job-started'", workingDirectory: "/tmp")
        var result = started
        let outputDeadline = ContinuousClock.now + .seconds(3)
        while !result.chunks.contains(where: { String(decoding: $0.data, as: UTF8.self).contains("job-started") })
            && result.state == .running && ContinuousClock.now < outputDeadline {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .milliseconds(250))
        }
        #expect(result.chunks.contains { String(decoding: $0.data, as: UTF8.self).contains("job-started") })
        try await executor.cancel(id: started.executionID)
        result = try await executor.read(id: started.executionID, after: 0, wait: .seconds(2))
        let deadline = ContinuousClock.now + .seconds(5)
        while result.state == .running && ContinuousClock.now < deadline {
            result = try await executor.read(id: started.executionID, after: result.nextCursor, wait: .milliseconds(250))
        }
        #expect(result.state == .cancelled)
        await executor.closeAll()
    }
}
