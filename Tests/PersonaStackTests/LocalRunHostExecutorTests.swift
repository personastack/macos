import Foundation
import Testing
@testable import PersonaStackCore

struct LocalRunHostExecutorTests {
    private func request(_ command: [String], stdin: String? = nil) throws -> LocalRunHostRequest {
        var json: [String: Any] = ["operation": "exec", "command": command]
        if let stdin { json["stdin"] = stdin }
        return try JSONDecoder().decode(LocalRunHostRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func completedCommandKeepsItsActualExitStatus() async throws {
        let executor = LocalRunHostExecutor(workspace: URL(fileURLWithPath: "/tmp"))
        let reply = await executor.execute(try request(["/bin/sh", "-c", "exit 7"]), requestID: "quick-exit")
        #expect(reply.exit_code == 7)
        #expect(reply.stderr == "")
        #expect(await executor.close())
    }

    @Test func forwardsTheWorkerSupportedStdinInBoundedChunks() async throws {
        let shell = DesktopShellExecutor()
        let executor = LocalRunHostExecutor(workspace: URL(fileURLWithPath: "/tmp"), shell: shell)
        let input = String(repeating: "data\n", count: 15_000)
        let reply = await executor.execute(try request(["/bin/cat"], stdin: input), requestID: "stdin")
        #expect(reply.exit_code == 0)
        #expect(reply.stdout == input)
        #expect(await shell.diagnostics().activeProcesses == 0)
        #expect(await executor.close())
    }

    @Test func cancellingDuringProcessStartupStopsTheOwnedProcess() async throws {
        let shell = DesktopShellExecutor()
        let executor = LocalRunHostExecutor(workspace: URL(fileURLWithPath: "/tmp"), shell: shell)
        let command = try request(["/bin/sleep", "30"])
        let run = Task { await executor.execute(command, requestID: "cancelled-start") }
        let deadline = ContinuousClock.now + .seconds(2)
        while await shell.diagnostics().activeProcesses == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await shell.diagnostics().activeProcesses == 1)
        run.cancel()
        _ = await run.value
        #expect(await shell.diagnostics().activeProcesses == 0)
        #expect(await executor.close())
    }
}
