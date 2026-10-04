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
    func cuaDaemonLaunchIsEmbeddedAndUsesOnlyItsPrivateEndpointAndLifetimePipe() {
        let socket = URL(fileURLWithPath: "/tmp/private-cua/control.sock")
        let pid = URL(fileURLWithPath: "/tmp/private-cua/daemon.pid")
        #expect(CuaEmbeddedService.arguments(socketURL: socket, pidFileURL: pid) == [
            "serve", "--embedded", "--parent-liveness-stdio", "--socket", socket.path, "--pid-file", pid.path,
        ])
        #expect(CuaDriverCompatibility.processEnvironment(from: [
            "HOME": "/tmp/profile", "PERSONASTACK_MACHINE_TOKEN": "do-not-forward",
            "CUA_DRIVER_EMBEDDED": "0", "CUA_DRIVER_HOST_BUNDLE_ID": "attacker.bundle",
        ]) == [
            "HOME": "/tmp/profile", "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0", "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_HOST_BUNDLE_ID": "ai.personastack.desktop",
        ])
    }

    @Test
    func leaseIsExclusiveAcrossPersonaOwnersAndCanBeReleased() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
    func configRevocationClosesOnlyItsHandlesAndFencesOlderCommands() async throws {
        let fixture = try DesktopParityFixture.load()
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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

        let searchFirst = await executor.handle(command("desktop_control_file", ownerA, requestID: "search-first-a",
                                                        arguments: .object(["action": .string("search"), "root": .string(directory.path),
                                                                            "name_glob": .string("*.txt"), "limit": .number(1),
                                                                            "control_token": .string(tokenA)])), proxy: nil)
        guard case .object(let searchFirstResult)? = searchFirst.result,
              case .bool(false)? = searchFirstResult["complete"],
              case .string(let searchContinuation)? = searchFirstResult["continuation"],
              case .array(let firstMatches)? = searchFirstResult["matches"], firstMatches.count == 1,
              case .object(let firstMatch) = firstMatches[0],
              case .string(let firstPath)? = firstMatch["path"] else {
            Issue.record("bounded filesystem search did not return a continuation")
            await executor.close()
            return
        }
        #expect(firstPath.hasSuffix("a.txt"))
        let searchNext = await executor.handle(command("desktop_control_file", ownerA, requestID: "search-next-a",
                                                       arguments: .object(["action": .string("search"), "root": .string(directory.path),
                                                                           "name_glob": .string("*.txt"), "limit": .number(1),
                                                                           "continuation": .string(searchContinuation),
                                                                           "control_token": .string(tokenA)])), proxy: nil)
        guard case .object(let searchNextResult)? = searchNext.result,
              case .bool(true)? = searchNextResult["complete"],
              case .array(let nextMatches)? = searchNextResult["matches"], nextMatches.count == 1,
              case .object(let nextMatch) = nextMatches[0],
              case .string(let nextPath)? = nextMatch["path"] else {
            Issue.record("filesystem search continuation did not complete")
            await executor.close()
            return
        }
        #expect(nextPath.hasSuffix("b.txt"))

        let openA = command("desktop_control_file", ownerA, requestID: "open-a",
                            arguments: .object(["action": .string("open"), "path": .string(fileA.path), "control_token": .string(tokenA)]))
        let openAResult = await executor.handle(openA, proxy: nil)
        guard case .object(let openedA)? = openAResult.result,
              case .string(let handleA)? = openedA["handle"],
              case .string(let contentText)? = openedA["content_text"],
              case .string("utf-8")? = openedA["encoding"],
              case .number(1)? = openedA["byte_length"],
              case .string(let revision)? = openedA["revision"],
              case .string(let modifiedAt)? = openedA["modified_at"],
              case .bool(false)? = openedA["changed_since_open"] else {
            Issue.record("config A file handle missing")
            await executor.close()
            return
        }
        #expect(!revision.isEmpty)
        #expect(!modifiedAt.isEmpty)
        #expect(contentText == "A")

        let binaryFile = directory.appendingPathComponent("blob.bin")
        let binaryBytes = try Data(hexString: fixture.files.binary.bytesHex)
        try binaryBytes.write(to: binaryFile)
        let binaryOpen = command("desktop_control_file", ownerA, requestID: "open-binary-a",
                                 arguments: .object(["action": .string("open"), "path": .string(binaryFile.path),
                                                     "control_token": .string(tokenA)]))
        let binaryResult = await executor.handle(binaryOpen, proxy: nil)
        guard case .object(let binaryContent)? = binaryResult.result,
              case .string("base64")? = binaryContent["encoding"],
              case .string(let encodedBinary)? = binaryContent["content_base64"],
              encodedBinary == fixture.files.binary.base64 else {
            Issue.record("binary file content was not returned with base64 metadata")
            await executor.close()
            return
        }
        #expect(binaryContent["content_text"] == nil)

        let imageFile = directory.appendingPathComponent(fixture.files.image.name)
        var imageBytes = try Data(hexString: fixture.files.image.bytesHex)
        imageBytes.append(Data(repeating: 7, count: DesktopFileSystem.maxReadBytes + 13))
        try imageBytes.write(to: imageFile)
        let imageOpen = await executor.handle(command("desktop_control_file", ownerA, requestID: "open-image-a",
                                                      arguments: .object(["action": .string("open"), "path": .string(imageFile.path),
                                                                          "control_token": .string(tokenA)])), proxy: nil)
        guard case .object(let imageResult)? = imageOpen.result,
              case .array(let imageBlocks)? = imageResult["content"], imageBlocks.count == 1,
              case .object(let imageBlock) = imageBlocks[0],
              case .string("image")? = imageBlock["type"],
              case .string(let imageMIMEType)? = imageBlock["mimeType"],
              case .string(let imageBase64)? = imageBlock["data"] else {
            Issue.record("bounded multi-chunk image file was not returned as MCP image content")
            await executor.close()
            return
        }
        #expect(imageMIMEType == fixture.files.image.mimeType)
        #expect(Data(base64Encoded: imageBase64) == imageBytes)
        #expect(imageResult["content_base64"] == nil)
        if case .number(let byteLength)? = imageResult["byte_length"] {
            #expect(byteLength == Double(imageBytes.count))
        } else {
            Issue.record("image file open did not return full byte metadata")
        }

        let missingWritePath = directory.appendingPathComponent("missing/uncertain.txt")
        let knownWriteFailure = await executor.handle(command("desktop_control_file", ownerA, requestID: "known-write-failure-a",
                                                               arguments: .object(["action": .string("write"), "path": .string(missingWritePath.path),
                                                                                   "mode": .string("append"), "content_base64": .string(""),
                                                                                   "control_token": .string(tokenA)])), proxy: nil)
        #expect(knownWriteFailure.type == "failure")
        #expect(knownWriteFailure.errorCode == fixture.files.uncertainWrite.knownFailureCode)
        #expect(DesktopControlCommandExecutor.mayHavePartialWrite(.object(["action": .string("write"), "mode": .string("append")])))
        #expect(fixture.files.uncertainWrite.code == "desktop_file_write_outcome_unknown")
        #expect(!fixture.files.uncertainWrite.message.isEmpty)

        let linesFile = directory.appendingPathComponent("lines.txt")
        try Data("first\nsecond\n".utf8).write(to: linesFile)
        let linesOpen = await executor.handle(command("desktop_control_file", ownerA, requestID: "open-lines-a",
                                                      arguments: .object(["action": .string("open"), "path": .string(linesFile.path),
                                                                          "control_token": .string(tokenA)])), proxy: nil)
        guard case .object(let linesHandleResult)? = linesOpen.result,
              case .string(let linesHandle)? = linesHandleResult["handle"] else {
            Issue.record("text line-range file handle missing")
            await executor.close()
            return
        }
        let lineRead = await executor.handle(command("desktop_control_file", ownerA, requestID: "read-lines-a",
                                                     arguments: .object(["action": .string("read"), "handle": .string(linesHandle),
                                                                         "start_line": .number(2), "line_count": .number(1),
                                                                         "control_token": .string(tokenA)])), proxy: nil)
        guard case .object(let lineResult)? = lineRead.result,
              case .string("second\n")? = lineResult["content_text"],
              case .number(2)? = lineResult["line_start"],
              case .number(3)? = lineResult["next_line"] else {
            Issue.record("text line-range read did not return line metadata")
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
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let cleanupGate = DesktopControlCallbackGate()
        executor.pauseCleanupBeforeResourceCloseForTesting { await cleanupGate.suspend() }
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
        let collector = DesktopControlFrameCollector()
        let runningCommand = Task {
            await executor.handle(command("desktop_control_execute", owner, requestID: "stream-command",
                                          arguments: .object(["control_token": .string(token),
                                                              "command": .string("printf 'stream-ready'; sleep 2; touch '\(afterRevoke.path)'"),
                                                              "working_directory": .string(directory.path),
                                                              "timeout_seconds": .number(10)])), proxy: nil) { frame in
                await collector.append(frame)
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
        let revokeCompletion = DesktopControlCompletionFlag()
        let revocation = Task {
            let response = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "stream-revoke"), proxy: nil)
            await revokeCompletion.markCompleted()
            return response
        }
        let bindingTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-a", configID: "config-a",
                                                 personaID: "persona-1", runID: "", generation: 1, configVersion: 1)
        let overlappingRevokeCompletion = DesktopControlCompletionFlag()
        let overlappingRevocation = Task {
            let response = await executor.handle(command("desktop_control_revoke_binding", bindingTarget, requestID: "stream-binding-revoke"), proxy: nil)
            await overlappingRevokeCompletion.markCompleted()
            return response
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await revokeCompletion.isCompleted()), "revocation acknowledged while a result callback was still suspended")
        #expect(!(await overlappingRevokeCompletion.isCompleted()), "overlapping binding revoke acknowledged while the config cleanup was in progress")
        #expect((await collector.frames()).count == 1)
        await gate.release()
        for _ in 0..<30 {
            if await cleanupGate.isEntered() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cleanupGate.isEntered(), "config cleanup did not reach the resource-close barrier")
        #expect(!(await revokeCompletion.isCompleted()), "config revocation acknowledged before resource cleanup completed")
        #expect(!(await overlappingRevokeCompletion.isCompleted()), "binding revocation acknowledged before the shared cleanup completed")
        await cleanupGate.release()
        let revoked = await revocation.value
        let bindingRevoked = await overlappingRevocation.value
        #expect(await revokeCompletion.isCompleted())
        #expect(revoked.type == "result", "\(revoked.errorCode ?? "no code"): \(revoked.errorMessage ?? "no message")")
        #expect(bindingRevoked.type == "result", "\(bindingRevoked.errorCode ?? "no code"): \(bindingRevoked.errorMessage ?? "no message")")
        let streamResult = await runningCommand.value
        #expect(streamResult.type == "failure")
        #expect(streamResult.errorCode == "desktop_control_config_revoked")
        #expect((await collector.frames()).count == 1, "no stream callback may arrive after revocation acknowledgement")
        #expect(!FileManager.default.fileExists(atPath: afterRevoke.path))
        await executor.close()
    }

    @Test
    func configRevocationDuringLeaseCleanupWaitsForStreamCallback() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let cleanupGate = DesktopControlCallbackGate()
        executor.pauseCleanupBeforeResourceCloseForTesting { await cleanupGate.suspend() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-stream-cleanup-revoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = target(persona: "persona-1", workspace: "workspace-a", config: "config-a", configVersion: 1)
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "cleanup-stream-acquire"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            await executor.close()
            return
        }

        let gate = DesktopControlCallbackGate()
        let collector = DesktopControlFrameCollector()
        let runningCommand = Task {
            await executor.handle(command("desktop_control_execute", owner, requestID: "cleanup-stream-command",
                                          arguments: .object(["control_token": .string(token),
                                                              "command": .string("printf 'stream-ready'"),
                                                              "working_directory": .string(directory.path),
                                                              "timeout_seconds": .number(10)])), proxy: nil) { frame in
                await collector.append(frame)
                await gate.suspend()
            }
        }
        await executor.waitForActiveOperationsForTesting(1)
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

        let release = Task {
            await executor.handle(command("desktop_control_release", owner, requestID: "cleanup-stream-release",
                                          arguments: .object(["control_token": .string(token)])), proxy: nil)
        }
        var leaseCleared = false
        for _ in 0..<30 {
            let status = await executor.handle(command("desktop_control_status", owner, requestID: "cleanup-stream-status"), proxy: nil)
            if case .object(let values)? = status.result, case .bool(false)? = values["busy"] {
                leaseCleared = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard leaseCleared else {
            Issue.record("release did not enter lease cleanup")
            await gate.release()
            _ = await release.value
            _ = await runningCommand.value
            await executor.close()
            return
        }

        let revokeTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-a", configID: "config-a",
                                                personaID: "", runID: "", generation: 0, configVersion: 2)
        let revokeCompletion = DesktopControlCompletionFlag()
        let revocation = Task {
            let response = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "cleanup-stream-revoke"), proxy: nil)
            await revokeCompletion.markCompleted()
            return response
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!(await revokeCompletion.isCompleted()), "revocation acknowledged while release cleanup was draining a stream callback")
        #expect((await collector.frames()).count == 1)
        await gate.release()
        for _ in 0..<30 {
            if await cleanupGate.isEntered() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cleanupGate.isEntered(), "lease cleanup did not reach the resource-close barrier")
        #expect(!(await revokeCompletion.isCompleted()), "revocation acknowledged before release cleanup closed resources")
        await cleanupGate.release()
        let released = await release.value
        let revoked = await revocation.value
        #expect(released.type == "failure")
        #expect(released.errorCode == "desktop_control_config_revoked")
        #expect(revoked.type == "result")
        #expect(await revokeCompletion.isCompleted())
        let streamResult = await runningCommand.value
        #expect(streamResult.type == "failure")
        #expect((await collector.frames()).count == 1, "no stream callback may arrive after revocation acknowledgement")
        await executor.close()
    }

    @Test
    func failedCleanupRequiresSameScopeRetryBeforeAcknowledgement() async {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
    func fileOperationsRequireTheCurrentControlToken() async {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let read = command("desktop_control_file", target(persona: "persona-1"), requestID: "read-1",
                           arguments: .object(["action": .string("list"), "path": .string("/")]))
        let response = await executor.handle(read, proxy: nil)
        #expect(response.type == "failure")
        #expect(response.errorCode == "desktop_control_required")
        await executor.close()
    }

    @Test
    func expiredFileHandlesReturnAnActionableFailure() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
    func configRevocationStopsProcessBeforeDrainingBlockedStdinWrites() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let owner = target(persona: "persona-1", configVersion: 1)
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-blocked-stdin"), proxy: nil)
        guard case .object(let lease)? = acquired.result,
              case .string(let token)? = lease["control_token"] else {
            Issue.record("control token missing")
            return
        }
        let started = await executor.handle(command("desktop_control_execute", owner, requestID: "start-blocked-stdin",
                                                     arguments: .object(["control_token": .string(token),
                                                                         "command": .string("sleep 20"),
                                                                         "working_directory": .string("/tmp")])), proxy: nil)
        guard case .object(let process)? = started.result,
              case .string(let executionID)? = process["execution_id"] else {
            Issue.record("process handle missing")
            return
        }
        let data = Data(repeating: 97, count: DesktopShellExecutor.maximumInputBytes).base64EncodedString()
        let writers = (0..<4).map { index in
            Task {
                await executor.handle(command("desktop_control_exec_write", owner, requestID: "blocked-stdin-\(index)",
                                               arguments: .object(["control_token": .string(token),
                                                                   "execution_id": .string(executionID),
                                                                   "data_base64": .string(data)])), proxy: nil)
            }
        }
        await executor.waitForActiveOperationsForTesting(writers.count)

        let revokeTarget = DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-1", configID: "config-1",
                                                personaID: "", runID: "", generation: 0, configVersion: 1)
        let revoked = await executor.handle(command("desktop_control_revoke_config", revokeTarget, requestID: "revoke-blocked-stdin"), proxy: nil)
        #expect(revoked.type == "result")
        for writer in writers { _ = await writer.value }
        #expect(await executor.close())
    }

    @Test
    func nativeCapabilityProbeVerifiesFileReadbackAndIncrementalShellOutput() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        var lifecycleChecks = 0
        try await executor.probeNativeCapabilities {
            lifecycleChecks += 1
        }
        #expect(lifecycleChecks == 3)
        let diagnostics = await executor.diagnostics()
        #expect(diagnostics.activeProcesses == 0)
        #expect(diagnostics.openFileHandles == 0)
        #expect(await executor.close())
    }

    @Test
    func nativeCapabilityProbeRequiresSuccessfulShellExit() {
        #expect(DesktopControlCommandExecutor.nativeProbeSucceeded(
            state: .exited, exitCode: 0, output: "personastack-stream-end"
        ))
        #expect(!DesktopControlCommandExecutor.nativeProbeSucceeded(
            state: .exited, exitCode: 7, output: "personastack-stream-end"
        ))
        #expect(!DesktopControlCommandExecutor.nativeProbeSucceeded(
            state: .running, exitCode: nil, output: "personastack-stream-end"
        ))
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
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
    func shellOutputIsForwardedAndRetainedForNonStreamingCallers() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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

    @Test
    func runningCommandRenewsIdleLeaseButHardLifetimeStillClosesIt() async throws {
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: .testFixture())
        let owner = target(persona: "persona-1")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire"), proxy: nil)
        guard case .object(let value)? = acquired.result, case .string(let token)? = value["control_token"] else {
            Issue.record("missing token"); return
        }
        let started = await executor.handle(command("desktop_control_execute", owner, requestID: "start",
            arguments: .object(["control_token": .string(token), "command": .string("sleep 30"),
                                "working_directory": .string("/tmp")])), proxy: nil)
        #expect(started.type == "result")
        clock += .seconds(100)
        await executor.expireLeaseIfNeeded()
        let rival = await executor.handle(command("desktop_control_acquire", target(persona: "persona-2"), requestID: "rival"), proxy: nil)
        #expect(rival.errorCode == "desktop_busy")
        clock += .seconds(1701)
        await executor.expireLeaseIfNeeded()
        #expect(await executor.diagnostics().activeProcesses == 0)
        let replacement = await executor.handle(command("desktop_control_acquire", target(persona: "persona-2"), requestID: "replacement"), proxy: nil)
        #expect(replacement.type == "result")
        await executor.close()
    }

    @Test
    func closedConnectionExecutorCannotGrantAReplacementLease() async {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
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
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: .testFixture())
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

    @Test
    func sessionLockRequiresObservedUnlockAndImmediatelyRejectsRelock() {
        let monitor = DesktopControlSessionLock(observeSystem: false)
        #expect(monitor.state != .unlocked)
        var states: [DesktopControlSessionLock.State] = []
        monitor.onChange = { states.append($0) }
        monitor.receive(.unlocked)
        #expect(monitor.state == .unlocked)
        monitor.receive(.locked)
        #expect(monitor.state != .unlocked)
        monitor.receive(.locked)
        #expect(states == [.unlocked, .locked])
    }

    @Test @MainActor
    func sleepRecoversWithoutUnlockConfirmation() async {
        let workspaceCenter = NotificationCenter()
        let monitor = DesktopControlSessionLock(workspaceCenter: workspaceCenter, snapshotReader: { .unknown })
        monitor.receive(.unlocked)

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<20 where monitor.state == .unlocked { await Task.yield() }
        #expect(monitor.state == .locked)

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await Task.yield()
        #expect(monitor.state == .unknown)
        #expect(monitor.isAwakeAndActive)
    }

    @Test
    func fileOffsetsDefaultOnlyWhenAbsentAndRejectInvalidWrites() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let owner = target(persona: "offset-owner")
        let acquired = await executor.handle(command("desktop_control_acquire", owner, requestID: "acquire-offset"), proxy: nil)
        guard case .object(let lease)? = acquired.result, let token = lease["control_token"] else {
            Issue.record("missing lease token")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: path)
        let opened = await executor.handle(command("desktop_control_file", owner, requestID: "open-offset",
            arguments: .object(["action": .string("open"), "control_token": token, "path": .string(path.path)])), proxy: nil)
        guard case .object(let file)? = opened.result, let handle = file["handle"] else {
            Issue.record("missing file handle")
            await executor.close()
            return
        }
        let read = await executor.handle(command("desktop_control_file", owner, requestID: "read-offset",
            arguments: .object(["action": .string("read"), "control_token": token, "handle": handle])), proxy: nil)
        #expect(read.type == "result")
        let invalid: [DesktopControlJSONValue] = [.number(-1), .number(1.5), .bool(true), .string("1"), .null, .number(1e30)]
        for (index, offset) in invalid.enumerated() {
            try Data("original".utf8).write(to: path)
            let write = await executor.handle(command("desktop_control_file", owner, requestID: "write-offset-\(index)",
                arguments: .object(["action": .string("write"), "control_token": token, "path": .string(path.path),
                    "mode": .string("replace"), "content_base64": .string(Data("X".utf8).base64EncodedString()), "offset": offset])), proxy: nil)
            #expect(write.type == "failure")
            #expect(try Data(contentsOf: path) == Data("original".utf8))
        }
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
