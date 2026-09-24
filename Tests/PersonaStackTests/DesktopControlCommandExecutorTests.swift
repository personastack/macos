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
        #expect(result.type == "result")
        #expect(!streamed.isEmpty)
        #expect(streamed.allSatisfy { $0.type == "result_chunk" && $0.requestID == "exec-stream" && $0.streamID == "exec-stream" })
        #expect(streamed.compactMap(\.sequence) == Array(1...UInt64(streamed.count)))
        guard case .object(let payload)? = result.result,
              case .array(let chunks)? = payload["chunks"] else {
            Issue.record("terminal shell payload missing chunks")
            return
        }
        #expect(!chunks.isEmpty)
        await executor.close()
    }

    private func target(persona: String) -> DesktopControlTarget {
        DesktopControlTarget(installationID: "install-1", workspaceID: "workspace-1", configID: "config-1",
                             personaID: persona, runID: "run-1", generation: 1)
    }

    private func command(_ operation: String, _ target: DesktopControlTarget, requestID: String,
                         arguments: DesktopControlJSONValue? = .object([:])) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: requestID, target: target, operation: operation,
                            arguments: arguments, deadlineAt: Date().addingTimeInterval(30))
    }
}
