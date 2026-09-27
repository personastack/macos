import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

private actor DesktopShellCloseSignal {
    private var signalled = false

    func signal() { signalled = true }
    func isSignalled() -> Bool { signalled }
}

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
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: fixture.blockedInputCommand, workingDirectory: "/tmp")
        #expect(started.state == .running)
        try await executor.write(id: started.executionID, input: .data(Data(fixture.stdinText.utf8)))
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

    @Test func managedProcessLimitIsEnforced() async throws {
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        do {
            #expect(fixture.maxProcesses == DesktopShellExecutor.maximumProcesses)
            #expect(fixture.limitCode == "desktop_process_limit")
            for _ in 0..<fixture.maxProcesses {
                _ = try await executor.start(command: "read answer", workingDirectory: "/tmp")
            }
            await #expect(throws: DesktopShellError.tooManyProcesses) {
                try await executor.start(command: "true", workingDirectory: "/tmp")
            }
            #expect(await executor.closeAll())
        } catch {
            _ = await executor.closeAll()
            throw error
        }
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

    @Test func closingStdinRejectsLaterWrites() async throws {
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "cat >/dev/null; sleep 0.2", workingDirectory: "/tmp")
        try await executor.write(id: started.executionID, input: .close)
        await #expect(throws: DesktopShellError.invalidInput) {
            try await executor.write(id: started.executionID, input: .data(Data("too late".utf8)))
        }
        await executor.closeAll()
    }

    @Test func cancellingManagedProcessStopsIt() async throws {
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: fixture.cancellationCommand, workingDirectory: "/tmp")
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
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: "head -c \(fixture.outputGapBytes) /dev/zero", workingDirectory: "/tmp", timeout: 10)
        var status = try await executor.status(id: started.executionID)
        let deadline = ContinuousClock.now + .seconds(10)
        // Deliberately leave cursor zero behind while the producer fills the ring.
        // Advancing the cursor during production can keep up and legitimately
        // report no gap, which does not exercise this behavior.
        while status.state == .running && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            status = try await executor.status(id: started.executionID)
        }
        #expect(status.state == .exited)
        let final = try await executor.read(id: started.executionID, after: 0)
        #expect(final.outputGap)
        #expect(final.earliestCursor > 1)
        #expect(final.chunks.reduce(0) { $0 + $1.data.count } <= DesktopShellExecutor.maximumReadBytes)
        let diagnostics = await executor.diagnostics()
        #expect(diagnostics.outputGapsTotal > 0)
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
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        let started = try await executor.start(command: fixture.cancellationCommand, workingDirectory: "/tmp")
        let writer = Task {
            for _ in 0..<fixture.blockedStdinWrites {
                let data = Data(repeating: 97, count: fixture.blockedStdinWriteBytes)
                try await executor.write(id: started.executionID, input: .data(data))
            }
        }
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

    @Test func closeAllStopsDisownedChildAfterItsShellLeaderExits() async throws {
        let fixture = try DesktopParityFixture.load().process
        let executor = DesktopShellExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-shell-disowned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childMarker = directory.appendingPathComponent(fixture.leaderChildMarker)
        let leaderPIDFile = directory.appendingPathComponent("leader.pid")
        _ = try await executor.start(
            command: "printf '%s' $PPID > '\(leaderPIDFile.path)'; (sleep \(fixture.leaderChildDelaySeconds); touch '\(childMarker.path)') & disown; printf 'leader-exited'",
            workingDirectory: directory.path,
            timeout: 10
        )
        let leaderPIDText = try String(contentsOf: leaderPIDFile, encoding: .utf8)
        guard let leaderPIDValue = Int32(leaderPIDText) else {
            Issue.record("shell leader PID was not recorded: \(leaderPIDText)")
            await executor.closeAll()
            return
        }
        let leaderPID = pid_t(leaderPIDValue)
        let leaderExitDeadline = ContinuousClock.now + .seconds(2)
        while Darwin.kill(leaderPID, 0) == 0 && ContinuousClock.now < leaderExitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Darwin.kill(leaderPID, 0) == -1 && errno == ESRCH, "shell leader was still running before group cleanup")
        #expect(await executor.closeAll())
        try await Task.sleep(for: .seconds(Double(fixture.leaderChildDelaySeconds) + 0.2))
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
    }

    @Test func closeAllDoesNotWaitBehindWritesHeldByDetachedChild() async throws {
        let executor = DesktopShellExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-shell-held-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hold-stdin.py")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let releaseFile = directory.appendingPathComponent("release")
        let scriptContents = """
        import os, time
        child = os.fork()
        if child:
            os._exit(0)
        os.setsid()
        with open(\(String(reflecting: childPIDFile.path)), "w") as handle:
            handle.write(str(os.getpid()))
        while not os.path.exists(\(String(reflecting: releaseFile.path))):
            time.sleep(0.02)
        """
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        let started = try await executor.start(command: "/usr/bin/python3 '\(script.path)'", workingDirectory: directory.path)
        let childDeadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: childPIDFile.path), ContinuousClock.now < childDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: childPIDFile.path))

        let writers = (0..<4).map { _ in
            Task { try await executor.write(id: started.executionID,
                                            input: .data(Data(repeating: 97, count: DesktopShellExecutor.maximumInputBytes))) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let completed = DesktopShellCloseSignal()
        let closeTask = Task {
            let result = await executor.closeAll()
            await completed.signal()
            return result
        }
        let closeDeadline = ContinuousClock.now + .seconds(3)
        while !(await completed.isSignalled()), ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let returnedBeforeRelease = await completed.isSignalled()
        try Data().write(to: releaseFile)
        #expect(returnedBeforeRelease)
        #expect(await closeTask.value)
        for writer in writers { _ = try? await writer.value }
    }

    @Test func shellExitCancelsWritesHeldByDetachedChild() async throws {
        let executor = DesktopShellExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-shell-exit-held-stdin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("hold-stdin.py")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let scriptContents = """
        import os, time
        child = os.fork()
        if child:
            os._exit(0)
        os.setsid()
        with open(\(String(reflecting: childPIDFile.path)), "w") as handle:
            handle.write(str(os.getpid()))
        while True:
            time.sleep(0.02)
        """
        try scriptContents.write(to: script, atomically: true, encoding: .utf8)
        let started = try await executor.start(command: "/usr/bin/python3 '\(script.path)'", workingDirectory: directory.path)
        let childDeadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: childPIDFile.path), ContinuousClock.now < childDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: childPIDFile.path))
        guard let childPIDText = try? String(contentsOf: childPIDFile, encoding: .utf8),
              let childPID = Int32(childPIDText) else {
            Issue.record("detached child PID was not readable")
            await executor.closeAll()
            return
        }
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        let writers = (0..<4).map { _ in
            Task { try await executor.write(id: started.executionID,
                                            input: .data(Data(repeating: 97, count: DesktopShellExecutor.maximumInputBytes))) }
        }
        var result = try await executor.status(id: started.executionID)
        let terminalDeadline = ContinuousClock.now + .seconds(3)
        while result.state == .running && ContinuousClock.now < terminalDeadline {
            result = try await executor.read(id: started.executionID, after: 0, wait: .milliseconds(100))
        }
        #expect(result.state != .running)
        var cancelledWrites = 0
        for writer in writers {
            do {
                try await writer.value
            } catch {
                cancelledWrites += 1
            }
        }
        // The pipe can accept early writes before the shell exits. At least one
        // queued write must be cancelled once the detached child holds stdin.
        #expect(cancelledWrites > 0)
        do {
            try await executor.write(id: started.executionID, input: .data(Data([97])))
            Issue.record("stdin write succeeded after terminal state was observed")
        } catch {}
        #expect(await executor.closeAll())
    }
}
