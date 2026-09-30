import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopControlBindingRevocationTests {
    private func target(_ generation: Int64, persona: String = "persona", run: String = "run", version: Int64 = 1) -> DesktopControlTarget {
        DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
            personaID: persona, runID: run, generation: generation, configVersion: version)
    }

    private func frame(_ operation: String, _ target: DesktopControlTarget,
                       _ arguments: [String: DesktopControlJSONValue] = [:]) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target,
            operation: operation, arguments: .object(arguments), deadlineAt: Date().addingTimeInterval(30))
    }

    private func acquire(_ executor: DesktopControlCommandExecutor, _ owner: DesktopControlTarget) async throws -> String {
        let response = await executor.handle(frame("desktop_control_acquire", owner), proxy: nil)
        guard case .object(let value)? = response.result, case .string(let token)? = value["control_token"] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return token
    }

    @Test
    func revokedBindingClosesOwnedResourcesAndPreservesSharedConfigForOtherPersonas() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let owner = target(3)
        let token = try await acquire(executor, owner)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("binding fixture".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let opened = await executor.handle(frame("desktop_control_file", owner,
            ["control_token": .string(token), "action": .string("open"), "path": .string(path.path)]), proxy: nil)
        #expect(opened.type == "result")
        let started = await executor.handle(frame("desktop_control_execute", owner,
            ["control_token": .string(token), "command": .string("sleep 30"), "working_directory": .string("/tmp")]), proxy: nil)
        #expect(started.type == "result")
        let revoke = frame("desktop_control_revoke_binding", target(3, run: ""))
        #expect(DesktopControlGatewayConnection.validCommand(revoke, installationID: "install"))
        #expect(await executor.handle(revoke, proxy: nil).type == "result")
        #expect(await executor.diagnostics().openFileHandles == 0)
        #expect(await executor.diagnostics().activeProcesses == 0)
        for generation: Int64 in [1, 3] {
            #expect(await executor.handle(frame("desktop_control_acquire", target(generation)), proxy: nil).errorCode == "desktop_control_binding_revoked")
        }
        _ = try await acquire(executor, target(1, persona: "other-persona"))
        await executor.close()
    }

    @Test
    func staleRevocationDoesNotTouchNewerBindingLeaseOrLowerRememberedCutoff() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        #expect(await executor.handle(frame("desktop_control_revoke_binding", target(4, run: "")), proxy: nil).type == "result")
        let newer = target(5)
        let token = try await acquire(executor, newer)
        for cutoff: Int64 in [4, 2] {
            #expect(await executor.handle(frame("desktop_control_revoke_binding", target(cutoff, run: "")), proxy: nil).type == "result")
        }
        // A different persona on the same config must not release this owner.
        #expect(await executor.handle(frame("desktop_control_revoke_binding", target(9, persona: "other-persona", run: "")), proxy: nil).type == "result")
        let released = await executor.handle(frame("desktop_control_release", newer,
            ["control_token": .string(token)]), proxy: nil)
        #expect(released.type == "result")
        #expect(await executor.handle(frame("desktop_control_acquire", target(3)), proxy: nil).errorCode == "desktop_control_binding_revoked")
        _ = try await acquire(executor, newer)
        await executor.close()
    }

    @Test
    func overlappingRevocationRecordsEveryBindingCutoffDuringCleanup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-control-revocation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let releaseMarker = marker.appendingPathExtension("release")
        let directory = marker.deletingLastPathComponent().appendingPathComponent("proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { try? Data().write(to: releaseMarker) }
        let executable = directory.appendingPathComponent("fake-cua")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys, time
        marker = pathlib.Path("\#(marker.path)")
        release_marker = pathlib.Path("\#(releaseMarker.path)")
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "notifications/initialized":
                continue
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"test-cua","version":"0.29.1"}}
            elif method == "tools/call":
                marker.write_text("entered")
                while not release_marker.exists():
                    time.sleep(0.01)
                result = {"content":[{"type":"text","text":"observed"}]}
            else:
                result = {}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let proxy = CuaMCPProxy(executableURL: executable)
        _ = try await proxy.start()
        defer { Task { await proxy.stop() } }

        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let activeOwner = target(1)
        let token = try await acquire(executor, activeOwner)
        let observe = frame("desktop_control_observe", activeOwner,
            ["control_token": .string(token), "tool": .string("get_desktop_state"), "arguments": .object([:])])
        let observeTask = Task { await executor.handle(observe, proxy: proxy) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let firstBindingRevoke = frame("desktop_control_revoke_binding", target(1, run: ""))
        let firstBindingRevokeTask = Task { await executor.handle(firstBindingRevoke, proxy: nil) }
        let unaffectedOwner = target(3, persona: "unaffected-persona")
        var cleanupObserved = false
        for _ in 0..<100 {
            let attempt = await executor.handle(frame("desktop_control_acquire", unaffectedOwner), proxy: nil)
            if attempt.errorCode == "desktop_control_revocation_in_progress" {
                cleanupObserved = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cleanupObserved)
        let secondBinding = target(7, persona: "second-persona")
        let bindingRevoke = frame("desktop_control_revoke_binding", target(7, persona: "second-persona", run: ""))
        #expect(DesktopControlGatewayConnection.validCommand(bindingRevoke, installationID: "install"))
        #expect(await executor.handle(bindingRevoke, proxy: nil).type == "result")
        let acquireDuringFirstCleanup = await executor.handle(frame("desktop_control_acquire", unaffectedOwner), proxy: nil)
        #expect(acquireDuringFirstCleanup.errorCode == "desktop_control_revocation_in_progress")

        try Data().write(to: releaseMarker)
        #expect((await observeTask.value).errorCode == "desktop_control_binding_revoked")
        #expect((await firstBindingRevokeTask.value).type == "result")
        let staleAcquire = await executor.handle(frame("desktop_control_acquire", secondBinding), proxy: nil)
        #expect(staleAcquire.errorCode == "desktop_control_binding_revoked")
        let acquiredUnaffected = await executor.handle(frame("desktop_control_acquire", unaffectedOwner), proxy: nil)
        guard case .object(let lease)? = acquiredUnaffected.result,
              case .string(let controlToken)? = lease["control_token"] else {
            Issue.record("unaffected persona could not acquire after cleanup")
            await executor.close()
            return
        }
        #expect(await executor.handle(frame("desktop_control_release", unaffectedOwner,
            ["control_token": .string(controlToken)]), proxy: nil).type == "result")
        await executor.close()
        await proxy.stop()
    }

    @Test
    func malformedBindingRevocationsAreRejectedAndReservedCapacityIsAvailable() async {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        for invalid in [target(0, run: ""), target(1, persona: "", run: ""), target(1), target(1, run: "", version: 0)] {
            let revoke = frame("desktop_control_revoke_binding", invalid)
            #expect(!DesktopControlGatewayConnection.validCommand(revoke, installationID: "install"))
            #expect(await executor.handle(revoke, proxy: nil).errorCode == "invalid_arguments")
        }
        #expect(DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_revoke_binding", activeCount: 31))
        #expect(!DesktopControlGatewayConnection.hasCapacity(for: "desktop_control_revoke_binding", activeCount: 32))
        await executor.close()
    }
}
