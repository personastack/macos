import Foundation
import Testing
@testable import PersonaStackCore

struct DesktopShellCommandBoundaryTests {
    @Test(arguments: ["printf marker;", "printf marker &", "printf marker # trailing comment", "printf marker\n"])
    func preservesValidCommandTerminators(command: String) async throws {
        let executor = DesktopShellExecutor()
        var result = try await executor.start(command: command, workingDirectory: "/tmp", timeout: 5)
        var chunks = result.chunks
        while result.state == .running {
            result = try await executor.read(id: result.executionID, after: result.nextCursor, wait: .seconds(1))
            chunks.append(contentsOf: result.chunks)
        }
        #expect(result.exitCode == 0)
        #expect(Data(chunks.filter { $0.stream == .stdout }.flatMap(\.data)) == Data("marker".utf8))
        #expect(await executor.closeAll())
    }

    @Test func rejectsNullBytesBeforeStartingAProcess() async throws {
        let executor = DesktopShellExecutor()
        await #expect(throws: DesktopShellError.invalidCommand) {
            try await executor.start(command: "true\0ignored", workingDirectory: "/tmp")
        }
        await #expect(throws: DesktopShellError.invalidWorkingDirectory) {
            try await executor.start(command: "true", workingDirectory: "/tmp\0ignored")
        }
        #expect(await executor.diagnostics().activeProcesses == 0)
        #expect(await executor.closeAll())
    }
}
