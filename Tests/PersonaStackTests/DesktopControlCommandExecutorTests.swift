import Foundation
import AppKit
import Testing
import PersonaStackCore
@testable import PersonaStack

private actor DesktopControlFrameCollector {
    private var stored: [DesktopControlFrame] = []

    func append(_ frame: DesktopControlFrame) {
        stored.append(frame)
    }

    func frames() -> [DesktopControlFrame] { stored }
}

private actor DesktopControlCallbackGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func isEntered() -> Bool { entered }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor DesktopControlCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

@Suite(.serialized)
@MainActor
struct DesktopControlCommandExecutorTests {
    @Test
    func leaseIsExclusiveAcrossPersonaOwnersAndCanBeReleased() async throws {
        let executor = DesktopControlCommandExecutor()
        let first = command("desktop_control_acquire", target(persona: "persona-1"), requestID: "acquire-1")
        let acquired = await executor.handle(first, proxy: nil)
        #expect(acquired.type == "result")
        guard case .object(let result)? = acquired.result,
              case .string(let token)? = result["control_token"] else {
            Issue.record("control token missing from acquire result")
            return
        }

        let second = command("desktop_control_acquire", target(persona: "persona-2"), requestID: "acquire-2")
        let busy = await executor.handle(second, proxy: nil)
        #expect(busy.type == "failure")
        #expect(busy.errorCode == "desktop_busy")

        let release = command("desktop_control_release", target(persona: "persona-1"), requestID: "release-1",
                              arguments: .object(["control_token": .string(token)]))
        let released = await executor.handle(release, proxy: nil)
        #expect(released.type == "result", "\(released.errorCode ?? "no code"): \(released.errorMessage ?? "no message")")

        let secondAcquire = await executor.handle(second, proxy: nil)
        #expect(secondAcquire.type == "result")
        await executor.close()
    }

    @Test
    func failedCleanupRequiresSameScopeRetryBeforeAcknowledgement() async {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1", workspace: "workspace-a", config: "config-a", configVersion: 1)
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "failed-cleanup-acquire"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            await executor.close()
            return
        }
        #expect(!token.isEmpty)

        executor.failNextCleanupForTesting()
        let revokeTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-a", configID: "config-a",
                                                personaID: "", runID: "", generation: 0, configVersion: 2)
        let failed = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "failed-cleanup-first"), proxy: nil)
        #expect(failed.type == "failure")
        #expect(failed.errorCode == "desktop_control_revoke_incomplete")

        let retried = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "failed-cleanup-retry"), proxy: nil)
        #expect(retried.type == "result")
        let otherWorkspace = target(persona: "persona-2", workspace: "workspace-b", config: "config-b", configVersion: 1)
        let otherAcquire = await executor.handle(command("desktop_control_acquire", otherWorkspace, requestID: "failed-cleanup-other-workspace"), proxy: nil)
        #expect(otherAcquire.type == "result")
        await executor.close()
    }

    @Test
    func cuaToolLevelErrorBecomesACommandFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-cua-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let toolCalls = directory.appendingPathComponent("tool-calls")
        let executable = directory.appendingPathComponent("fake-cua")
        try #"""
        #!/usr/bin/python3
        import json,sys
        from pathlib import Path
        for line in sys.stdin:
            request=json.loads(line)
            if request.get("method")=="notifications/initialized": continue
            if request.get("method")=="tools/call":
                with Path(r"\#(toolCalls.path)").open("a") as output: output.write(request["params"]["name"] + "\n")
                if request["params"]["name"] == "end_session":
                    arguments = request["params"]["arguments"]
                    assert set(arguments) == {"session"} and arguments["session"]
                    result={"structuredContent":{"session":arguments["session"],"active":False}}
                else:
                    assert request["params"]["name"] == "launch_app"
                    result={"isError":True,"content":[{"type":"text","text":"private launch diagnostic"}],"structuredContent":{"error":"LAUNCH_CALLBACK_TIMEOUT","message":"private /Users/example path","launch_state":{"process_running":False,"window_ready":False}}}
            else: result={}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}),flush=True)
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let proxy = CuaMCPProxy(executableURL: executable)
        let executor = DesktopControlCommandExecutor()
        _ = try await proxy.start()
        let owner = target(persona: "persona-cua-error")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-cua-error"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            await proxy.stop()
            await executor.close()
            return
        }
        let launch = command("desktop_control_application", owner, requestID: "launch-cua-error",
                             arguments: .object(["control_token": .string(token), "tool": .string("launch_app"),
                                                 "arguments": .object(["bundle_id": .string("com.apple.Safari")])]))
        let response = await executor.handle(launch, proxy: proxy)
        #expect(response.type == "failure")
        #expect(response.errorCode == "LAUNCH_CALLBACK_TIMEOUT")
        #expect(response.errorMessage?.contains("app or URL may already have opened") == true)
        #expect(response.errorMessage?.contains("If the intended target is Safari and it is absent") == true)
        #expect(response.errorMessage?.contains("private") == false)
        #expect(response.errorMessage?.contains("/Users") == false)
        #expect(response.errorMessage?.contains("process_running") == false)
        #expect(response.errorMessage?.contains("window_ready") == false)
        #expect(try String(contentsOf: toolCalls, encoding: .utf8) == "launch_app\n")
        #expect(await executor.close())
        #expect(try String(contentsOf: toolCalls, encoding: .utf8) == "launch_app\nend_session\n")
        await proxy.stop()
    }

    @Test
    func closedConnectionExecutorCannotGrantAReplacementLease() async {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1")
        #expect(await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire"), proxy: nil).type == "result")
        #expect(await executor.close())
        let denied = await executor.handle(command("desktop_control_acquire", owner, requestID: "retry"), proxy: nil)
        #expect(denied.errorCode == "desktop_executor_unavailable")
        #expect(await executor.diagnostics().openFileHandles == 0)
        let status = await executor.handle(command("desktop_control_status", owner, requestID: "status"), proxy: nil)
        #expect(status.type == "result")
        guard case .object(let values)? = status.result else {
            Issue.record("closed executor status is missing")
            return
        }
        #expect(values["available"] == .bool(false))
        #expect(values["native_executor_ready"] == .bool(false))
    }

    @Test
    func concurrentAcquisitionAfterExpiryHasOnlyOneWinner() async {
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock })
        _ = await executor.handle(command("desktop_control_acquire", target(persona: "old"), requestID: "old"), proxy: nil)
        clock += .seconds(91)
        let tasks = (0..<20).map { index in
            Task { @MainActor in
                await executor.handle(command("desktop_control_acquire", target(persona: "persona-\(index)"),
                                              requestID: "acquire-\(index)"), proxy: nil)
            }
        }
        var winners = 0
        for task in tasks {
            if await task.value.type == "result" { winners += 1 }
        }
        #expect(winners == 1)
        await executor.close()
    }

    @Test(arguments: ["desktop_control_file", "desktop_control_execute", "desktop_control_exec_read", "desktop_control_exec_write", "desktop_control_exec_status", "desktop_control_exec_cancel"])
    func nativeOperationsAreRejectedWithoutSideEffects(operation: String) async throws {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire"), proxy: nil)
        guard case .object(let fields)? = acquired.result, case .string(let token)? = fields["control_token"] else {
            Issue.record("Missing lease"); return
        }
        let response = await executor.handle(command(operation, owner, requestID: "unsupported",
            arguments: .object(["control_token": .string(token), "command": .string("should never execute"), "path": .string("/never/open") ])), proxy: nil)
        #expect(response.errorCode == "invalid_arguments")
        let diagnostics = await executor.diagnostics()
        #expect(diagnostics.activeProcesses == 0)
        #expect(diagnostics.openFileHandles == 0)
        #expect(await executor.close())
    }

    @Test(arguments: [false, true])
    func uncertainCUACallKeepsOwnedCleanupAuthorityWithoutReplaying(crash: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("proxy")
        let calls = directory.appendingPathComponent("calls")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
            elif method == "tools/call":
                name = request["params"]["name"]
                with open("\#(calls.path)", "a") as out:
                    out.write(name + "\n")
                if name == "click":
                    if \#(crash ? "True" : "False"): os._exit(1)
                    time.sleep(0.4)
                    result = {"content":[]}
                elif name == "end_session":
                    result = {"structuredContent":{"session":request["params"]["arguments"]["session"],"active":False}}
                else:
                    os._exit(2)
            else:
                continue
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let proxy = CuaMCPProxy(executableURL: executable)
        _ = try await proxy.start()
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "timeout-owner")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire"), proxy: proxy)
        guard case .object(let fields)? = acquired.result, case .string(let token)? = fields["control_token"] else {
            Issue.record("Missing lease"); await proxy.stop(); return
        }
        let click = DesktopControlFrame(type: "command", requestID: "click", target: owner,
            operation: "desktop_control_cua", arguments: .object(["control_token": .string(token),
                "tool": .string("click"), "arguments": .object(["x": .number(1), "y": .number(1)])]),
            deadlineAt: Date().addingTimeInterval(0.15))
        let outcome = await executor.handle(click, proxy: proxy)
        #expect(outcome.errorCode == "outcome_unknown")
        #expect(executor.needsSessionCleanup)
        #expect(await executor.handle(command("desktop_control_acquire", owner, requestID: "blocked"), proxy: proxy).type == "failure")
        #expect(await proxy.isProcessRunning() == !crash)
        let released = await executor.handle(command("desktop_control_release", owner, requestID: "release",
            arguments: .object(["control_token": .string(token)])), proxy: proxy)
        if crash {
            #expect(released.type == "failure")
            #expect(executor.needsSessionCleanup)
            #expect(await executor.handle(command("desktop_control_acquire", owner, requestID: "still-blocked"), proxy: proxy).type == "failure")
            #expect(try String(contentsOf: calls, encoding: .utf8) == "click\n")
        } else {
            #expect(released.type == "result")
            #expect(!executor.needsSessionCleanup)
            #expect(await executor.handle(command("desktop_control_acquire", owner, requestID: "next"), proxy: proxy).type == "result")
            #expect(try String(contentsOf: calls, encoding: .utf8) == "click\nend_session\n")
        }
        _ = await executor.close()
        await proxy.stop()
    }

    private func target(persona: String, workspace: String = "workspace-1", config: String = "config-1", configVersion: Int64? = nil,
                        installation: String = "install-1") -> DesktopControlTarget {
        DesktopControlTarget(installationID: installation, workspaceID: workspace, configID: config,
                             personaID: persona, runID: "run-1", generation: 1, configVersion: configVersion)
    }

    private func command(_ operation: String, _ target: DesktopControlTarget, requestID: String,
                         arguments: DesktopControlJSONValue? = .object([:])) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: requestID, target: target, operation: operation,
                            arguments: arguments, deadlineAt: Date().addingTimeInterval(30))
    }
}
