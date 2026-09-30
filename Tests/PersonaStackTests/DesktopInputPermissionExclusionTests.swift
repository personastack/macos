import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private actor InputLeaseGrantGate {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Suite @MainActor
struct DesktopInputPermissionExclusionTests {
    private func owner(persona: String = "persona", version: Int64 = 1) -> DesktopControlTarget {
        .init(installationID: "install", workspaceID: "workspace", configID: "config",
              personaID: persona, runID: "run", generation: 1, configVersion: version)
    }
    private func frame(_ operation: String, target: DesktopControlTarget? = nil) -> DesktopControlFrame {
        .init(type: "command", requestID: UUID().uuidString, target: target ?? owner(), operation: operation,
              arguments: .object([:]))
    }

    @Test func nativeCheckExcludesAcquireAndInputButStatusStaysReadable() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let id = try await executor.beginNativeVerification()
        await #expect(throws: (any Error).self) { _ = try await executor.beginNativeVerification() }
        for operation in ["desktop_control_acquire", "desktop_control_input", "desktop_control_file", "desktop_control_release"] {
            #expect(await executor.handle(frame(operation), proxy: nil).errorCode == "desktop_executor_unavailable")
        }
        let status = await executor.handle(frame("desktop_control_status"), proxy: nil)
        guard case .object(let value)? = status.result else { Issue.record("status missing"); return }
        #expect(value["available"] == .bool(false))
        #expect(value["native_executor_ready"] == .bool(false))
        #expect(value["busy"] == .bool(true))
        try executor.requireNativeVerification(id)
        executor.endNativeVerification(UUID())
        #expect(await executor.handle(frame("desktop_control_acquire"), proxy: nil).errorCode == "desktop_executor_unavailable")
        executor.endNativeVerification(id)
        #expect(await executor.handle(frame("desktop_control_acquire"), proxy: nil).type == "result")
        #expect(await executor.close())
    }

    @Test(arguments: [false, true])
    func anExistingLeasePreventsLocalCheckEvenAfterExpiry(expired: Bool) async {
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: .testFixture())
        #expect(await executor.handle(frame("desktop_control_acquire"), proxy: nil).type == "result")
        if expired { clock += .seconds(91) }
        await #expect(throws: (any Error).self) { _ = try await executor.beginNativeVerification() }
        if !expired {
            #expect(await executor.handle(frame("desktop_control_acquire", target: owner(persona: "rival")), proxy: nil).errorCode == "desktop_busy")
        }
        #expect(await executor.close())
    }

    @Test func suspendedAcquireCannotGrantDuringNativeVerification() async throws {
        var clock = ContinuousClock.now
        let executor = DesktopControlCommandExecutor(now: { clock }, powerAssertion: .testFixture())
        #expect(await executor.handle(frame("desktop_control_acquire", target: owner(persona: "old")), proxy: nil).type == "result")
        clock += .seconds(91)
        let gate = InputLeaseGrantGate()
        executor.pauseLeaseGrantAfterCleanupForTesting { await gate.suspend() }
        let pending = Task { @MainActor in
            await executor.handle(frame("desktop_control_acquire", target: owner(persona: "pending")), proxy: nil)
        }
        await gate.waitForEntry()
        let id = try await executor.beginNativeVerification()
        await gate.release()
        #expect(await pending.value.errorCode == "desktop_executor_unavailable")
        try executor.requireNativeVerification(id)
        executor.endNativeVerification(id)
        #expect(await executor.handle(frame("desktop_control_acquire", target: owner(persona: "later")), proxy: nil).type == "result")
        #expect(await executor.close())
    }

    @Test(arguments: ["close", "config", "binding"])
    func terminalAndSecurityEventsInvalidateLocalProof(event: String) async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        var targetInert = false
        let id = try await executor.beginNativeVerification(onInvalidation: { targetInert = true })
        var closing: Task<Bool, Never>?
        switch event {
        case "close":
            closing = Task { @MainActor in await executor.close() }
            await Task.yield()
        case "config":
            let target = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
                                              personaID: "", runID: "", generation: 0, configVersion: 1)
            #expect(await executor.handle(frame("desktop_control_revoke_config", target: target), proxy: nil).type == "result")
        default:
            let target = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
                                              personaID: "persona", runID: "", generation: 1, configVersion: 1)
            #expect(await executor.handle(frame("desktop_control_revoke_binding", target: target), proxy: nil).type == "result")
        }
        #expect(throws: CancellationError.self) { try executor.requireNativeVerification(id) }
        #expect(targetInert)
        #expect(executor.nativeVerificationInProgress)
        let denied = await executor.handle(frame("desktop_control_acquire", target: owner(persona: "fresh", version: 2)), proxy: nil)
        #expect(denied.type == "failure")
        #expect(denied.errorCode == (event == "close" ? "desktop_control_revocation_in_progress" : "desktop_executor_unavailable"))
        executor.endNativeVerification(id)
        if let closing { #expect(await closing.value) }
        else {
            #expect(await executor.handle(frame("desktop_control_acquire", target: owner(persona: "fresh", version: 2)), proxy: nil).type == "result")
        }
        #expect(await executor.close())
    }

    @Test func staleCompletionCannotClearNewNativeCheck() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let old = try await executor.beginNativeVerification()
        executor.endNativeVerification(old)
        let current = try await executor.beginNativeVerification()
        executor.endNativeVerification(old)
        try executor.requireNativeVerification(current)
        #expect(await executor.handle(frame("desktop_control_acquire"), proxy: nil).errorCode == "desktop_executor_unavailable")
        executor.endNativeVerification(current)
        #expect(await executor.close())
    }
}
