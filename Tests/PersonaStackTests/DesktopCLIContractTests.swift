import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

private actor DesktopCLIFake: DesktopShellControlling {
    private let id = UUID()
    private var active = false
    private var calls: [String] = []
    private var input: Data?
    private var cursor: UInt64 = 0
    func history() -> [String] { calls }
    func diagnostics() -> DesktopShellDiagnostics {
        DesktopShellDiagnostics(activeProcesses: active ? 1 : 0, openFileHandles: active ? 3 : 0, bufferedOutputBytes: 0, outputGapsTotal: 0)
    }
    func retainedExecutionIDs() -> Set<UUID> { active ? [id] : [] }
    func start(command: String, workingDirectory: String, timeout: TimeInterval, terminalMode: DesktopTerminalMode,
               rows: UInt16, columns: UInt16) throws -> DesktopProcessRead {
        #expect(command == "command with ' shell syntax; $(code)")
        #expect(workingDirectory == "/tmp")
        #expect(timeout == 300)
        calls.append("start"); active = true
        return result(chunks: [])
    }
    func read(id: UUID, after: UInt64, wait: Duration) throws -> DesktopProcessRead {
        #expect(id == self.id); #expect(after == cursor)
        calls.append("read")
        cursor += 1
        return result(chunks: [DesktopOutputChunk(sequence: cursor, stream: input == nil ? .stdout : .stderr,
                                                data: input ?? Data("prompt:".utf8))])
    }
    func write(id: UUID, input: DesktopProcessInput) throws {
        #expect(id == self.id)
        calls.append("write")
        if case .data(let data) = input { self.input = data }
    }
    func status(id: UUID) throws -> DesktopProcessRead { calls.append("status"); return result(chunks: []) }
    func cancel(id: UUID) throws { calls.append("cancel"); active = false }
    func requestStopAll() { calls.append("stop"); active = false }
    func closeAll() -> Bool { calls.append("close"); active = false; return true }
    private func result(chunks: [DesktopOutputChunk]) -> DesktopProcessRead {
        DesktopProcessRead(executionID: id, chunks: chunks, nextCursor: cursor, earliestCursor: 1,
                           outputGap: false, state: input == nil ? .running : .exited, exitCode: input == nil ? nil : 7,
                           signal: nil, terminalMode: .pipe, outputComplete: input != nil)
    }
}

@Suite struct DesktopCLIArgumentsTests {
    private let token = DesktopControlJSONValue.string(UUID().uuidString)
    @Test func strictInputsAndCommandBytes() throws {
        let values: [String: DesktopControlJSONValue] = ["control_token": token, "command": .string("echo '$HOME'; printf '\\xff'"), "working_directory": .string("/tmp")]
        let parsed = try DesktopCLIArguments(operation: "desktop_control_execute", arguments: .object(values))
        #expect(parsed.mode == .pipe)
        #expect(parsed.timeout == 300)
        #expect(parsed.command == "echo '$HOME'; printf '\\xff'")
        for (key, value) in [("unknown", .bool(true)), ("terminal_mode", .string("bad")), ("timeout_seconds", .number(0)),
                             ("terminal_rows", .number(20)), ("command", .string("a\0b")), ("working_directory", .string("relative"))] as [(String, DesktopControlJSONValue)] {
            var invalid = values; invalid[key] = value
            #expect(throws: DesktopShellError.self) { try DesktopCLIArguments(operation: "desktop_control_execute", arguments: .object(invalid)) }
        }
    }
    @Test func writeSupportsFinalDataAndEOFButsRejectsInterruptConflict() throws {
        let values: [String: DesktopControlJSONValue] = ["control_token": token, "execution_id": .string(UUID().uuidString),
            "data_base64": .string(Data([0, 255, 195]).base64EncodedString()), "close_stdin": .bool(true)]
        let parsed = try DesktopCLIArguments(operation: "desktop_control_exec_write", arguments: .object(values))
        #expect(parsed.inputs.count == 2)
        guard case .data(let bytes) = parsed.inputs[0] else { Issue.record("missing bytes"); return }
        #expect(bytes == Data([0, 255, 195]))
        var invalid = values; invalid["interrupt"] = .bool(true)
        #expect(throws: DesktopShellError.self) { try DesktopCLIArguments(operation: "desktop_control_exec_write", arguments: .object(invalid)) }
    }
    @Test func resultIsByteSafeAndPinsOutputCompletion() throws {
        let value = DesktopProcessRead(executionID: UUID(), chunks: [.init(sequence: 1, stream: .stdout, data: Data([0, 255, 195]))],
            nextCursor: 1, earliestCursor: 1, outputGap: true, state: .exited, exitCode: 7, signal: nil, terminalMode: .pty, outputComplete: false)
        let json = try JSONSerialization.data(withJSONObject: value.resultObject)
        let result = try JSONDecoder().decode(DesktopControlJSONValue.self, from: json)
        guard case .object(let fields) = result else { Issue.record("not object"); return }
        #expect(fields["merged_output"] == .bool(true))
        #expect(fields["output_complete"] == .bool(false))
        #expect(fields["exit_code"] == .number(7))
        #expect(fields["signal"] == nil)
        #expect(fields["chunks"] == .array([.object(["sequence": .number(1), "stream": .string("stdout"), "data_base64": .string("AP/D")])]))
    }
}

@Suite @MainActor struct DesktopCLILeaseTests {
    private func target(_ persona: String = "persona") -> DesktopControlTarget {
        DesktopControlTarget(installationID: "installation", workspaceID: "workspace", configID: "config",
                             personaID: persona, runID: "run", generation: 1, configVersion: 1)
    }
    private func frame(_ operation: String, target: DesktopControlTarget, args: [String: DesktopControlJSONValue] = [:]) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target, operation: operation,
                            arguments: .object(args), deadlineAt: Date().addingTimeInterval(45))
    }
    @Test func sharedLeaseWorkflowAndForeignScopeDenials() async throws {
        let fake = DesktopCLIFake()
        let executor = DesktopControlCommandExecutor(shell: fake)
        let owner = target()
        let acquired = await executor.handle(frame("desktop_control_acquire", target: owner), proxy: nil)
        guard case .object(let lease)? = acquired.result, let token = lease["control_token"] else { Issue.record("missing token"); return }
        let started = await executor.handle(frame("desktop_control_execute", target: owner, args: ["control_token": token,
            "command": .string("command with ' shell syntax; $(code)"), "working_directory": .string("/tmp")]), proxy: nil)
        guard case .object(let start)? = started.result, let id = start["execution_id"] else { Issue.record("missing ID \(started.errorCode ?? "")"); return }
        let args = ["control_token": token, "execution_id": id]
        let before = await fake.history()
        for operation in ["desktop_control_exec_read", "desktop_control_exec_write", "desktop_control_exec_status", "desktop_control_exec_cancel"] {
            let denied = await executor.handle(frame(operation, target: target("foreign"), args: args), proxy: nil)
            #expect(denied.errorCode == "desktop_control_required")
        }
        #expect(await fake.history() == before)
        var foreignID = args; foreignID["execution_id"] = .string(UUID().uuidString)
        let missing = await executor.handle(frame("desktop_control_exec_read", target: owner, args: foreignID), proxy: nil)
        #expect(missing.errorCode == "desktop_execution_not_found")
        #expect(await fake.history() == before)
        let prompt = await executor.handle(frame("desktop_control_exec_read", target: owner, args: args), proxy: nil)
        guard case .object(let promptFields)? = prompt.result else { Issue.record("no prompt"); return }
        #expect(promptFields["state"] == .string("running"))
        var write = args; write["data_base64"] = .string(Data("answer".utf8).base64EncodedString())
        #expect(await executor.handle(frame("desktop_control_exec_write", target: owner, args: write), proxy: nil).type == "result")
        var read = args; read["cursor"] = .number(1)
        let final = await executor.handle(frame("desktop_control_exec_read", target: owner, args: read), proxy: nil)
        guard case .object(let fields)? = final.result else { Issue.record("no final"); return }
        #expect(fields["exit_code"] == .number(7))
        #expect(fields["output_complete"] == .bool(true))
        #expect(await executor.handle(frame("desktop_control_release", target: owner, args: ["control_token": token]), proxy: nil).type == "result")
        #expect(await fake.history().suffix(2) == ["stop", "close"])
        #expect(await executor.handle(frame("desktop_control_exec_status", target: owner, args: args), proxy: nil).errorCode == "desktop_control_required")
        #expect(await executor.close())
    }
    @Test func expiryAndCloseStopCommandsBeforeAnotherOwnerAcquires() async {
        let fake = DesktopCLIFake()
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, shell: fake)
        _ = await executor.handle(frame("desktop_control_acquire", target: target()), proxy: nil)
        clock += .seconds(91)
        _ = await executor.handle(frame("desktop_control_acquire", target: target("next")), proxy: nil)
        #expect(await fake.history() == ["stop", "close"])
        #expect(await executor.close())
        #expect(await fake.history() == ["stop", "close", "stop", "close"])
    }
}
