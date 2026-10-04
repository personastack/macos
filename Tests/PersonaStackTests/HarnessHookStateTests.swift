import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

private func hookSignalArrived(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

struct HarnessHookStateTests {
    @Test func inputRetainsOnlyBoundedSessionAndTurnIdentity() throws {
        let input = try HarnessHookInput.decode(Data("{\"session_id\":\"session-a\",\"turn_id\":\"turn-a\",\"prompt\":\"private\",\"transcript_path\":\"/private\"}".utf8))
        #expect(input.sessionID == "session-a")
        #expect(input.turnID == "turn-a")
        for session in ["", "../bad", String(repeating: "a", count: 129), "with space"] {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": session])
            #expect(throws: LocalSessionError.invalidRequest) { try HarnessHookInput.decode(data) }
        }
    }

    @Test func stateKeepsConnectionsSessionsAndTurnGenerationsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root)
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let turn = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: "turn", ownerPID: 123)
        do { let state = try store.lock(connectionID: first, sessionID: "one"); defer { state.unlock() }; try state.write(turn) }
        do { let state = try store.lock(connectionID: first, sessionID: "two"); defer { state.unlock() }; #expect(try state.read() == nil) }
        do { let state = try store.lock(connectionID: second, sessionID: "one"); defer { state.unlock() }; #expect(try state.read() == nil) }
        do { let state = try store.lock(connectionID: first, sessionID: "one"); defer { state.unlock() }; #expect(try state.read() == turn); try state.clear() }
        do { let state = try store.lock(connectionID: first, sessionID: "one"); defer { state.unlock() }; #expect(try state.read() == nil) }
    }

    @Test func blockedSessionDoesNotHoldOtherSessionsOnSameConnection() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-concurrency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased()
        let held = try store.lock(connectionID: connection, sessionID: "blocked")
        defer { held.unlock() }
        let sameAcquired = DispatchSemaphore(value: 0), otherAcquired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { let state = try store.lock(connectionID: connection, sessionID: "blocked"); state.unlock() }
            catch { Issue.record("Waiting session failed: \(error)") }
            sameAcquired.signal()
        }
        DispatchQueue.global().async {
            do { let state = try store.lock(connectionID: connection, sessionID: "independent"); state.unlock() }
            catch { Issue.record("Independent session failed: \(error)") }
            otherAcquired.signal()
        }
        let independent = await Task.detached { hookSignalArrived(otherAcquired, timeout: 1) }.value
        #expect(independent)
        #expect(!hookSignalArrived(sameAcquired, timeout: 0))
        held.unlock()
        #expect(await Task.detached { hookSignalArrived(sameAcquired, timeout: 1) }.value)
    }

    @Test func finishedSessionsDoNotConsumeActiveSessionCapacity() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-capacity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessHookState(root: root), connection = UUID().uuidString.lowercased()
        let turn = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: nil, ownerPID: getpid())
        for index in 0..<130 {
            let state = try store.lock(connectionID: connection, sessionID: "finished-\(index)")
            defer { state.unlock() }
            try state.write(turn); try state.clear()
        }
        let active = try store.lock(connectionID: connection, sessionID: "new-session"); defer { active.unlock() }
        try active.write(turn)
        #expect(try active.read() == turn)
    }
    @Test func commandExecKeepsTheDispatcherAsHelperParent() throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec /bin/ps -o ppid= -p $$"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        output.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parent = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(process.terminationStatus == 0)
        #expect(parent == String(getpid()))
    }

    @Test func hardLinkedStateCannotOverwriteAnotherFile() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("hook-hardlink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = UUID().uuidString.lowercased(), store = HarnessHookState(root: root)
        let turn = HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: nil, ownerPID: 123)
        let state = try store.lock(connectionID: connection, sessionID: "one")
        defer { state.unlock() }
        try state.write(turn)
        let directory = root.appendingPathComponent(connection)
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let path = try #require(paths.first { $0.pathExtension == "json" })
        let other = root.appendingPathComponent("unrelated.json")
        try FileManager.default.linkItem(at: path, to: other)
        let before = try Data(contentsOf: other)
        #expect(throws: LocalSessionError.unsafeFiles) { try state.write(HarnessHookTurn(runID: UUID().uuidString.lowercased(), turnID: "new", ownerPID: 124)) }
        #expect(try Data(contentsOf: other) == before)
    }

}
