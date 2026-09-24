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

@Suite(.serialized)
@MainActor
struct DesktopControlCommandExecutorTests {
    @Test
    func cuaServiceLaunchUsesTheSignedAppBundleServeModeWithoutFrontingIt() {
        let configuration = DesktopControlRuntime.cuaServiceLaunchConfiguration(
            inheritedEnvironment: ["HOME": "/tmp/profile", "PERSONASTACK_MACHINE_TOKEN": "do-not-forward"]
        )
        #expect(configuration.arguments == ["serve"])
        #expect(configuration.activates == false)
        #expect(configuration.addsToRecentItems == false)
        #expect(configuration.environment == [
            "HOME": "/tmp/profile",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
        ])
    }

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
        #expect(released.type == "result")

        let secondAcquire = await executor.handle(second, proxy: nil)
        #expect(secondAcquire.type == "result")
        await executor.close()
    }

    @Test
    func configRevocationClosesOnlyItsHandlesAndFencesOlderCommands() async throws {
        let executor = DesktopControlCommandExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-revoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileA = directory.appendingPathComponent("a.txt")
        let fileB = directory.appendingPathComponent("b.txt")
        try Data("A".utf8).write(to: fileA)
        try Data("B".utf8).write(to: fileB)

        let ownerA = target(persona: "persona-a", workspace: "workspace-a", config: "config-a", configVersion: 1)
        let acquiredA = await executor.handle(command("desktop_control_acquire", ownerA, requestID: "acquire-a"), proxy: nil)
        guard case .object(let leaseA)? = acquiredA.result,
              case .string(let tokenA)? = leaseA["control_token"] else {
            Issue.record("config A control token missing")
            await executor.close()
            return
        }

        let openA = command("desktop_control_file", ownerA, requestID: "open-a",
                            arguments: .object(["action": .string("open"), "path": .string(fileA.path), "control_token": .string(tokenA)]))
        let openAResult = await executor.handle(openA, proxy: nil)
        guard case .object(let openedA)? = openAResult.result,
              case .string(let handleA)? = openedA["handle"] else {
            Issue.record("config A file handle missing")
            await executor.close()
            return
        }

        let executeA = command("desktop_control_execute", ownerA, requestID: "execute-a",
                               arguments: .object(["control_token": .string(tokenA), "command": .string("sleep 30"),
                                                   "working_directory": .string("/tmp"), "timeout_seconds": .number(60)]))
        let executeAResult = await executor.handle(executeA, proxy: nil)
        guard case .object(let processA)? = executeAResult.result,
              case .string(let executionID)? = processA["execution_id"] else {
            Issue.record("config A process handle missing: \(executeAResult.errorCode ?? "no error code")")
            await executor.close()
            return
        }

        let revokeA = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-a", configID: "config-a",
                                           personaID: "", runID: "", generation: 0, configVersion: 2)
        let ownerB = target(persona: "persona-b", workspace: "workspace-b", config: "config-b", configVersion: 1)
        let revocationTask = Task {
            await executor.handle(command("desktop_control_revoke_config", revokeA, requestID: "revoke-a"), proxy: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        let acquireDuringCleanup = await executor.handle(command("desktop_control_acquire", ownerB, requestID: "acquire-b-during-cleanup"), proxy: nil)
        #expect(acquireDuringCleanup.errorCode == "desktop_control_revocation_in_progress")

        let revoked = await revocationTask.value
        #expect(revoked.type == "result", "\(revoked.errorCode ?? "no error code"): \(revoked.errorMessage ?? "")")

        let staleAcquire = await executor.handle(command("desktop_control_acquire", ownerA, requestID: "stale-acquire-a"), proxy: nil)
        #expect(staleAcquire.type == "failure")
        #expect(staleAcquire.errorCode == "desktop_control_config_revoked")

        let acquiredB = await executor.handle(command("desktop_control_acquire", ownerB, requestID: "acquire-b"), proxy: nil)
        guard case .object(let leaseB)? = acquiredB.result,
              case .string(let tokenB)? = leaseB["control_token"] else {
            Issue.record("config B control token missing")
            await executor.close()
            return
        }
        let openB = command("desktop_control_file", ownerB, requestID: "open-b",
                            arguments: .object(["action": .string("open"), "path": .string(fileB.path), "control_token": .string(tokenB)]))
        let openBResult = await executor.handle(openB, proxy: nil)
        guard case .object(let openedB)? = openBResult.result,
              case .string(let handleB)? = openedB["handle"] else {
            Issue.record("config B file handle missing")
            await executor.close()
            return
        }

        let repeatedRevocation = await executor.handle(command("desktop_control_revoke_config", revokeA, requestID: "revoke-a-again"), proxy: nil)
        #expect(repeatedRevocation.type == "result")
        let readB = command("desktop_control_file", ownerB, requestID: "read-b",
                            arguments: .object(["action": .string("read"), "control_token": .string(tokenB),
                                                "handle": .string(handleB), "offset": .number(0)]))
        #expect((await executor.handle(readB, proxy: nil)).type == "result")

        let releaseB = command("desktop_control_release", ownerB, requestID: "release-b",
                               arguments: .object(["control_token": .string(tokenB)]))
        #expect((await executor.handle(releaseB, proxy: nil)).type == "result")
        let reenabledA = target(persona: "persona-a", workspace: "workspace-a", config: "config-a", configVersion: 3)
        let acquiredReenabledA = await executor.handle(command("desktop_control_acquire", reenabledA, requestID: "acquire-a-v3"), proxy: nil)
        guard case .object(let leaseA3)? = acquiredReenabledA.result,
              case .string(let tokenA3)? = leaseA3["control_token"] else {
            Issue.record("new config version could not acquire after re-enable")
            await executor.close()
            return
        }
        let closedFileA = command("desktop_control_file", reenabledA, requestID: "read-closed-file-a",
                                 arguments: .object(["action": .string("read"), "control_token": .string(tokenA3),
                                                     "handle": .string(handleA), "offset": .number(0)]))
        #expect((await executor.handle(closedFileA, proxy: nil)).errorCode == "desktop_file_handle_expired")
        let closedProcessA = command("desktop_control_exec_status", reenabledA, requestID: "status-closed-process-a",
                                     arguments: .object(["control_token": .string(tokenA3), "execution_id": .string(executionID)]))
        #expect((await executor.handle(closedProcessA, proxy: nil)).errorCode == "desktop_process_handle_expired")
        await executor.close()
    }

    @Test
    func foreignInstallationCannotUseAnotherInstallationFileHandle() async throws {
        let executor = DesktopControlCommandExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-foreign-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let protectedFile = directory.appendingPathComponent("private.txt")
        let forbiddenWrite = directory.appendingPathComponent("foreign.txt")
        try Data("authorized contents".utf8).write(to: protectedFile)

        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "foreign-acquire"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            await executor.close()
            return
        }
        let opened = await executor.handle(command("desktop_control_file", owner, requestID: "foreign-open",
                                                   arguments: .object(["action": .string("open"), "path": .string(protectedFile.path), "control_token": .string(token)])), proxy: nil)
        guard case .object(let openedFile)? = opened.result,
              case .string(let handle)? = openedFile["handle"] else {
            Issue.record("file handle missing")
            await executor.close()
            return
        }

        let foreignOwner = target(persona: "persona-1", installation: "install-foreign")
        let foreignRead = await executor.handle(command("desktop_control_file", foreignOwner, requestID: "foreign-read",
                                                         arguments: .object(["action": .string("read"), "control_token": .string(token),
                                                                             "handle": .string(handle), "offset": .number(0)])), proxy: nil)
        #expect(foreignRead.type == "failure")
        #expect(foreignRead.errorCode == "desktop_control_required")
        #expect(try Data(contentsOf: protectedFile) == Data("authorized contents".utf8))

        let foreignWrite = await executor.handle(command("desktop_control_file", foreignOwner, requestID: "foreign-file-write",
                                                          arguments: .object(["action": .string("write"), "control_token": .string(token),
                                                                              "path": .string(forbiddenWrite.path), "content_base64": .string("Zm9yZWlnbg=="),
                                                                              "mode": .string("create")])), proxy: nil)
        #expect(foreignWrite.type == "failure")
        #expect(foreignWrite.errorCode == "desktop_control_required")
        #expect(!FileManager.default.fileExists(atPath: forbiddenWrite.path))

        let foreignExecute = await executor.handle(command("desktop_control_execute", foreignOwner, requestID: "foreign-write",
                                                           arguments: .object(["control_token": .string(token),
                                                                              "command": .string("touch '\(forbiddenWrite.path)'"),
                                                                              "working_directory": .string(directory.path)])), proxy: nil)
        #expect(foreignExecute.type == "failure")
        #expect(foreignExecute.errorCode == "desktop_control_required")
        #expect(!FileManager.default.fileExists(atPath: forbiddenWrite.path))
        await executor.close()
    }

    @Test
    func configRevocationStopsAnActiveOutputStreamBeforeItCanContinue() async throws {
        let executor = DesktopControlCommandExecutor()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-stream-revoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let afterRevoke = directory.appendingPathComponent("continued.txt")
        let owner = target(persona: "persona-1", workspace: "workspace-a", config: "config-a", configVersion: 1)
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "stream-acquire"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            await executor.close()
            return
        }

        let gate = DesktopControlCallbackGate()
        let runningCommand = Task {
            await executor.handle(command("desktop_control_execute", owner, requestID: "stream-command",
                                          arguments: .object(["control_token": .string(token),
                                                              "command": .string("printf 'stream-ready'; sleep 2; touch '\(afterRevoke.path)'"),
                                                              "working_directory": .string(directory.path),
                                                              "timeout_seconds": .number(10)])), proxy: nil) { _ in
                await gate.suspend()
            }
        }

        for _ in 0..<30 {
            if await gate.isEntered() { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard await gate.isEntered() else {
            Issue.record("command output did not reach the suspended stream callback")
            await gate.release()
            _ = await runningCommand.value
            await executor.close()
            return
        }

        let revokeTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-a", configID: "config-a",
                                                personaID: "", runID: "", generation: 0, configVersion: 2)
        let revoked = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "stream-revoke"), proxy: nil)
        #expect(revoked.type == "result", "\(revoked.errorCode ?? "no code"): \(revoked.errorMessage ?? "no message")")
        await gate.release()
        let streamResult = await runningCommand.value
        #expect(streamResult.type == "failure")
        #expect(streamResult.errorCode == "desktop_control_config_revoked")
        #expect(!FileManager.default.fileExists(atPath: afterRevoke.path))
        await executor.close()
    }

    @Test
    func fileOperationsRequireTheCurrentControlToken() async {
        let executor = DesktopControlCommandExecutor()
        let read = command("desktop_control_file", target(persona: "persona-1"), requestID: "read-1",
                           arguments: .object(["action": .string("list"), "path": .string("/")]))
        let response = await executor.handle(read, proxy: nil)
        #expect(response.type == "failure")
        #expect(response.errorCode == "desktop_control_required")
        await executor.close()
    }

    @Test
    func expiredFileHandlesReturnAnActionableFailure() async throws {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-file"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            return
        }

        let read = command("desktop_control_file", owner, requestID: "read-expired",
                           arguments: .object(["action": .string("read"), "control_token": .string(token),
                                               "handle": .string("00000000-0000-0000-0000-000000000000"), "offset": .number(0)]))
        let response = await executor.handle(read, proxy: nil)

        #expect(response.type == "failure")
        #expect(response.errorCode == "desktop_file_handle_expired")
        #expect(response.errorMessage?.contains("Open the file again") == true)
        await executor.close()
    }

    @Test
    func filesystemPermissionAndPartialWriteClassifiersAreSpecific() {
        #expect(DesktopControlCommandExecutor.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        #expect(DesktopControlCommandExecutor.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(!DesktopControlCommandExecutor.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))

        #expect(DesktopControlCommandExecutor.mayHavePartialWrite(.object(["action": .string("write"), "mode": .string("append")])))
        #expect(DesktopControlCommandExecutor.mayHavePartialWrite(.object(["action": .string("write"), "mode": .string("replace"), "offset": .number(12)])))
        #expect(!DesktopControlCommandExecutor.mayHavePartialWrite(.object(["action": .string("write"), "mode": .string("replace")])))
        #expect(!DesktopControlCommandExecutor.mayHavePartialWrite(.object(["action": .string("patch")])))
    }

    @Test
    func shellStartAndExpiredHandleFailuresAreActionable() async throws {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-shell-error"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            return
        }

        let start = command("desktop_control_execute", owner, requestID: "invalid-shell-cwd",
                            arguments: .object(["control_token": .string(token), "command": .string("true"),
                                                "working_directory": .string("/path/that/does/not/exist")]))
        let startResponse = await executor.handle(start, proxy: nil)
        #expect(startResponse.type == "failure")
        #expect(startResponse.errorCode == "desktop_process_working_directory_invalid")
        #expect(startResponse.errorMessage?.contains("existing directory") == true)

        let status = command("desktop_control_exec_status", owner, requestID: "expired-process-handle",
                             arguments: .object(["control_token": .string(token),
                                                 "execution_id": .string("00000000-0000-0000-0000-000000000000")]))
        let statusResponse = await executor.handle(status, proxy: nil)
        #expect(statusResponse.type == "failure")
        #expect(statusResponse.errorCode == "desktop_process_handle_expired")
        #expect(statusResponse.errorMessage?.contains("Start a new command") == true)
        await executor.close()
    }

    @Test
    func shellOutputIsForwardedAndRetainedForNonStreamingCallers() async throws {
        let executor = DesktopControlCommandExecutor()
        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-stream"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            return
        }
        let execution = command("desktop_control_execute", owner, requestID: "exec-stream",
                                arguments: .object(["control_token": .string(token), "command": .string("printf 'streamed-output'"),
                                                    "working_directory": .string("/tmp")]))
        let collector = DesktopControlFrameCollector()
        let result = await executor.handle(execution, proxy: nil) { frame in await collector.append(frame) }
        let streamed = await collector.frames()
        #expect(result.type == "result", "\(result.errorCode ?? "no code"): \(result.errorMessage ?? "no message")")
        #expect(!streamed.isEmpty, "The command completed without forwarding any stdout or stderr chunks.")
        #expect(streamed.allSatisfy { $0.type == "result_chunk" && $0.requestID == "exec-stream" && $0.streamID == "exec-stream" })
        #expect(streamed.enumerated().allSatisfy { $0.element.sequence == UInt64($0.offset + 1) })
        guard case .object(let payload)? = result.result,
              case .array(let chunks)? = payload["chunks"] else {
            Issue.record("terminal shell payload missing chunks")
            return
        }
        #expect(!chunks.isEmpty)
        await executor.close()
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
