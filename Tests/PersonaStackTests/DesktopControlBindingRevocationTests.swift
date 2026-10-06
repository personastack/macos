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
        let executor = DesktopControlCommandExecutor()
        let owner = target(3)
        _ = try await acquire(executor, owner)
        let revoke = frame("desktop_control_revoke_binding", target(3, run: ""))
        #expect(DesktopControlGatewayConnection.validCommand(revoke, installationID: "install"))
        #expect(await executor.handle(revoke, proxy: nil).type == "result")
        #expect(executor.currentLease == nil)
        for generation: Int64 in [1, 3] {
            #expect(await executor.handle(frame("desktop_control_acquire", target(generation)), proxy: nil).errorCode == "desktop_control_binding_revoked")
        }
        _ = try await acquire(executor, target(1, persona: "other-persona"))
        await executor.close()
    }

    @Test
    func staleRevocationDoesNotTouchNewerBindingLeaseOrLowerRememberedCutoff() async throws {
        let executor = DesktopControlCommandExecutor()
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
        let proxy = RevocationCuaFixture()

        let executor = DesktopControlCommandExecutor()
        let activeOwner = target(1)
        let token = try await acquire(executor, activeOwner)
        let observe = frame("desktop_control_observe", activeOwner,
            ["control_token": .string(token), "tool": .string("get_desktop_state"), "arguments": .object([:])])
        let observeTask = Task { await executor.handle(observe, proxy: proxy) }
        await proxy.waitUntilObserved()

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
            await Task.yield()
        }
        #expect(cleanupObserved)
        let secondBinding = target(7, persona: "second-persona")
        let bindingRevoke = frame("desktop_control_revoke_binding", target(7, persona: "second-persona", run: ""))
        #expect(DesktopControlGatewayConnection.validCommand(bindingRevoke, installationID: "install"))
        #expect(await executor.handle(bindingRevoke, proxy: nil).type == "result")
        let acquireDuringFirstCleanup = await executor.handle(frame("desktop_control_acquire", unaffectedOwner), proxy: nil)
        #expect(acquireDuringFirstCleanup.errorCode == "desktop_control_revocation_in_progress")

        await proxy.completeObservation()
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
    }

    @Test
    func malformedBindingRevocationsAreRejectedAndReservedCapacityIsAvailable() async {
        let executor = DesktopControlCommandExecutor()
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


private actor RevocationCuaFixture: CuaToolCalling {
    private var observed = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func waitUntilObserved() async {
        if observed { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func completeObservation() { completion?.resume(); completion = nil }
    func callTool(name: String, argumentsJSON: Data, timeout: Int32) async throws -> Data {
        if name == "end_session" {
            let arguments = try JSONDecoder().decode(SessionArguments.self, from: argumentsJSON)
            #expect(!arguments.session.isEmpty)
            return try JSONEncoder().encode(SessionEnvelope(result: .init(structuredContent: .init(session: arguments.session, active: false))))
        }
        #expect(name == "get_desktop_state")
        observed = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { completion = $0 }
        return Data(#"{"result":{"content":[{"type":"text","text":"observed"}]}}"#.utf8)
    }
    private struct SessionArguments: Decodable { let session: String }
    private struct SessionEnvelope: Encodable { let result: SessionResult }
    private struct SessionResult: Encodable {
        let structuredContent: State
        struct State: Encodable { let session: String; let active: Bool }
    }
}
