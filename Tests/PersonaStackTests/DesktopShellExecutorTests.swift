import Foundation
import Testing
@testable import PersonaStackCore

@Suite struct DesktopShellExecutorTests {
    private enum FixtureError: Error { case timeout }
    private func python(_ source: String) -> String {
        "exec python3 -u -c '" + source.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private func drain(_ shell: DesktopShellExecutor, _ id: UUID, after: UInt64 = 0) async throws -> DesktopProcessRead {
        let end = ContinuousClock.now + .seconds(8)
        var cursor = after
        var chunks: [DesktopOutputChunk] = []
        while ContinuousClock.now < end {
            let page = try await shell.read(id: id, after: cursor, wait: .milliseconds(200))
            chunks += page.chunks; cursor = page.nextCursor
            if page.outputComplete && page.state != .running {
                return DesktopProcessRead(executionID: id, chunks: chunks, nextCursor: cursor,
                    earliestCursor: page.earliestCursor, outputGap: page.outputGap, state: page.state,
                    exitCode: page.exitCode, signal: page.signal, terminalMode: page.terminalMode, outputComplete: true)
            }
        }
        throw FixtureError.timeout
    }
    @Test func cwdShellSyntaxIsAPathAndLaunchFailureHasNoSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-cli-\(UUID().uuidString)'$()", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = DesktopShellExecutor()
        do {
            let started = try await shell.start(command: "printf '%s' \"$PWD\"", workingDirectory: directory.path)
            let final = try await drain(shell, started.executionID)
            #expect(String(decoding: final.chunks.flatMap { $0.data }, as: UTF8.self).contains(directory.lastPathComponent))
            await #expect(throws: DesktopShellError.invalidWorkingDirectory) {
                try await shell.start(command: "printf should-not-start", workingDirectory: directory.appendingPathComponent("absent").path)
            }
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }

    @Test func closedOutputStreamsCanBeCompleteWhileProcessStillRuns() async throws {
        let shell = DesktopShellExecutor()
        do {
            let started = try await shell.start(command: python("import os,time; os.close(1); os.close(2); time.sleep(30)"), workingDirectory: "/tmp")
            let observed = try await shell.read(id: started.executionID, after: 0, wait: .seconds(3))
            #expect(observed.state == .running)
            #expect(observed.outputComplete)
            let status = try await shell.status(id: started.executionID)
            #expect(status.state == .running)
            #expect(status.outputComplete)
            #expect(status.exitCode == nil)
            try await shell.cancel(id: started.executionID)
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }

    @Test func pipePartialPromptBinaryStreamsInputAndTrailingOutput() async throws {
        let shell = DesktopShellExecutor()
        do {
            let started = try await shell.start(command: python("import sys; sys.stdout.buffer.write(b'prompt:\\x00\\xff'); sys.stdout.flush(); line=sys.stdin.buffer.readline(); sys.stdout.buffer.write(b'answer:'+line); sys.stderr.write('stderr-marker'); sys.exit(7)"), workingDirectory: "/tmp")
            #expect(started.state == .running)
            let prompt = try await shell.read(id: started.executionID, after: 0, wait: .seconds(3))
            #expect(prompt.chunks.contains { $0.data.contains(255) })
            #expect(prompt.state == .running)
            try await shell.write(id: started.executionID, input: .data(Data("ok\n".utf8)))
            let final = try await drain(shell, started.executionID, after: prompt.nextCursor)
            #expect(final.exitCode == 7)
            #expect(final.signal == nil)
            #expect(final.outputComplete)
            #expect(final.chunks.contains { $0.stream == .stderr && String(decoding: $0.data, as: UTF8.self).contains("stderr-marker") })
            #expect(final.chunks.contains { $0.stream == .stdout && String(decoding: $0.data, as: UTF8.self).contains("answer:ok") })
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }
    @Test func controllingPTYInitialSizeResizeInputAndEOF() async throws {
        let shell = DesktopShellExecutor()
        do {
            let source = "import os,sys; print('TTY',os.isatty(0),os.tcgetpgrp(0)==os.getpgrp(),os.get_terminal_size(0),flush=True); line=sys.stdin.readline(); print('SIZE',os.get_terminal_size(0),'INPUT',line.strip(),flush=True); print('EOF',repr(sys.stdin.readline()),flush=True)"
            let started = try await shell.start(command: python(source), workingDirectory: "/tmp", terminalMode: .pty, rows: 31, columns: 97)
            let first = try await shell.read(id: started.executionID, after: 0, wait: .seconds(3))
            let output = String(decoding: first.chunks.flatMap { $0.data }, as: UTF8.self)
            #expect(output.contains("TTY True True"))
            #expect(output.contains("columns=97, lines=31"))
            try await shell.write(id: started.executionID, input: .resize(rows: 42, columns: 101))
            try await shell.write(id: started.executionID, input: .data(Data("reply\n".utf8)))
            let next = try await shell.read(id: started.executionID, after: first.nextCursor, wait: .seconds(3))
            try await shell.write(id: started.executionID, input: .close)
            let final = try await drain(shell, started.executionID, after: next.nextCursor)
            let remaining = String(decoding: (next.chunks + final.chunks).flatMap { $0.data }, as: UTF8.self)
            #expect(remaining.contains("columns=101, lines=42"))
            #expect(remaining.contains("INPUT reply"))
            #expect(remaining.contains("EOF ''"))
            #expect(final.exitCode == 0)
            #expect(final.chunks.allSatisfy { $0.stream == .stdout })
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }
    @Test func ptyInterruptTargetsForegroundGroup() async throws {
        let shell = DesktopShellExecutor()
        do {
            let started = try await shell.start(command: python("import signal,time; signal.signal(signal.SIGINT,signal.SIG_DFL); print('ready',flush=True); time.sleep(30)"), workingDirectory: "/tmp", terminalMode: .pty)
            _ = try await shell.read(id: started.executionID, after: 0, wait: .seconds(3))
            try await shell.write(id: started.executionID, input: .interrupt)
            let final = try await drain(shell, started.executionID)
            #expect(final.signal == 2)
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }
    @Test func processLifetimeIsIndependentOfStartRPCDeadlineAndCancellationIsRepeatable() async throws {
        let shell = DesktopShellExecutor()
        do {
            let started = try await DesktopControlExecution.$deadline.withValue(Date().addingTimeInterval(0.5)) {
                try await shell.start(command: "sleep 30", workingDirectory: "/tmp", timeout: 10)
            }
            try await Task.sleep(for: .milliseconds(600))
            #expect(try await shell.status(id: started.executionID).state == .running)
            try await shell.cancel(id: started.executionID)
            try await shell.cancel(id: started.executionID)
            let final = try await drain(shell, started.executionID)
            #expect(final.state == .cancelled)
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }
    @Test func processQuotaTimeoutAndCleanupAreFinite() async throws {
        let shell = DesktopShellExecutor()
        do {
            for _ in 0..<4 { _ = try await shell.start(command: "sleep 30", workingDirectory: "/tmp", timeout: 1) }
            await #expect(throws: DesktopShellError.tooManyProcesses) {
                try await shell.start(command: "printf should-not-start", workingDirectory: "/tmp")
            }
            try await Task.sleep(for: .milliseconds(1600))
            for id in await shell.retainedExecutionIDs() {
                #expect(try await drain(shell, id).state == .timedOut)
            }
            #expect(await shell.closeAll())
            #expect(await shell.diagnostics().activeProcesses == 0)
            #expect(await shell.diagnostics().openFileHandles == 0)
        } catch { _ = await shell.closeAll(); throw error }
    }
    @Test func overflowReportsCursorGapAndBoundedPages() async throws {
        let shell = DesktopShellExecutor()
        do {
            let started = try await shell.start(command: python("import sys; sys.stdout.buffer.write(b'x'*(5*1024*1024)); sys.stdout.flush()"), workingDirectory: "/tmp")
            let end = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < end {
                let state = try await shell.status(id: started.executionID)
                if state.state != .running && state.outputComplete { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let page = try await shell.read(id: started.executionID, after: 0)
            #expect(page.outputGap)
            #expect(page.earliestCursor > 1)
            #expect(page.chunks.reduce(0) { $0 + $1.data.count } <= DesktopShellExecutor.maximumReadBytes)
            #expect(await shell.diagnostics().bufferedOutputBytes <= DesktopShellExecutor.maximumBufferedBytesPerProcess)
            #expect(await shell.closeAll())
        } catch { _ = await shell.closeAll(); throw error }
    }
}
