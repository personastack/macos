import Foundation
import Testing
@testable import PersonaStackCore

private struct BlockedInputFixture {
    let root: URL
    let executor: DesktopShellExecutor
    let id: UUID

    static func start() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stdin-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = root.appendingPathComponent("reader.py")
        try #"""
        import os, pathlib, time
        root = pathlib.Path(__file__).parent
        (root / "ready").touch()
        while not (root / "release").exists():
            time.sleep(0.01)
        total = 0
        while True:
            chunk = os.read(0, 65536)
            if not chunk:
                break
            total += len(chunk)
        (root / "eof").write_text(str(total))
        """#.write(to: script, atomically: true, encoding: .utf8)
        let executor = DesktopShellExecutor()
        let process = try await executor.start(command: "/usr/bin/python3 '\(script.path)'", workingDirectory: root.path)
        let until = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        return Self(root: root, executor: executor, id: process.executionID)
    }

    func release() throws { try Data().write(to: root.appendingPathComponent("release")) }
    func cleanup() async {
        try? release()
        _ = await executor.closeAll()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test(arguments: [false, true])
func queuedInputCloseCannotActAfterExpiryOrCancellation(cancelled: Bool) async throws {
    let fixture = try await BlockedInputFixture.start()
    let bytes = Data(repeating: 97, count: DesktopShellExecutor.maximumInputBytes - 1)
    let writers = (0..<4).map { _ in Task { try await fixture.executor.write(id: fixture.id, input: .data(bytes)) } }
    // Each queued writer either fills the pipe or waits behind the earlier writer.
    for _ in 0..<20 { await Task.yield() }
    let deadline = Date().addingTimeInterval(cancelled ? 3 : 0.3)
    let close = Task {
        try await DesktopControlExecution.$deadline.withValue(deadline) {
            try await fixture.executor.write(id: fixture.id, input: .close)
        }
    }
    do {
        while !(await fixture.executor.inputClosePendingForTesting(fixture.id)), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await fixture.executor.inputClosePendingForTesting(fixture.id))
        if cancelled { close.cancel() }
        else { while Date() <= deadline { try await Task.sleep(for: .milliseconds(10)) } }
        try fixture.release()
        for writer in writers { try await writer.value }
        if cancelled {
            await #expect(throws: CancellationError.self) { try await close.value }
        } else {
            await #expect(throws: DesktopControlExecution.Expired.self) { try await close.value }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("eof").path))
        #expect(!(await fixture.executor.inputClosePendingForTesting(fixture.id)))
        try await fixture.executor.write(id: fixture.id, input: .data(Data("more".utf8)))
        try await fixture.executor.write(id: fixture.id, input: .close)
        let until = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("eof").path), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = try String(contentsOf: fixture.root.appendingPathComponent("eof"), encoding: .utf8)
        #expect(Int(count) == bytes.count * 4 + 4)
        await fixture.cleanup()
    } catch {
        try? fixture.release()
        for writer in writers { _ = try? await writer.value }
        _ = try? await close.value
        await fixture.cleanup()
        throw error
    }
}

@Test func expiredPartialInputReportsUncertainDelivery() async throws {
    let fixture = try await BlockedInputFixture.start()
    let bytes = Data(repeating: 97, count: DesktopShellExecutor.maximumInputBytes - 1)
    let writers = (0..<4).map { _ in Task {
        try await DesktopControlExecution.$deadline.withValue(Date().addingTimeInterval(0.2)) {
            try await fixture.executor.write(id: fixture.id, input: .data(bytes))
        }
    } }
    var uncertain = 0
    for writer in writers {
        do { try await writer.value }
        catch DesktopShellError.inputOutcomeUnknown { uncertain += 1 }
        catch is DesktopControlExecution.Expired { }
        catch { Issue.record("Unexpected input error: \(error)") }
    }
    #expect(uncertain > 0)
    do {
        try fixture.release()
        try await fixture.executor.write(id: fixture.id, input: .close)
        let until = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("eof").path), ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = try #require(Int(String(contentsOf: fixture.root.appendingPathComponent("eof"), encoding: .utf8)))
        #expect(count > 0 && count < bytes.count * 4)
        await fixture.cleanup()
    } catch { await fixture.cleanup(); throw error }
}
