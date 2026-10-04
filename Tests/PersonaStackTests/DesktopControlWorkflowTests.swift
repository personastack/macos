import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

private actor SuspendedReadiness {
    private var result: CheckedContinuation<String?, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func read() async -> String? {
        calls += 1
        return await withCheckedContinuation { continuation in
            result = continuation
            entered?.resume()
            entered = nil
        }
    }
    func waitUntilEntered() async {
        if result != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func finish() { result?.resume(returning: "ready"); result = nil }
}

@Test func desktopHeartbeatsDoNotWaitForBusyHealthChecksOrOverwritePause() async throws {
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"install-1","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://agent-gateway.personastack.ai/v1/desktop-control/ws"}"#.utf8))
    let blocked = SuspendedReadiness()
    let connection = DesktopControlGatewayConnection(installation: installation,
        readinessProvider: { await blocked.read() }, handler: { frame, _ in frame })
    await connection.setReadiness("ready")
    let first = await connection.heartbeatFrame()
    #expect(first.readiness == "ready")
    await blocked.waitUntilEntered()
    let second = await connection.heartbeatFrame()
    #expect(second.type == "heartbeat")
    #expect(await blocked.calls == 1)
    await connection.setReadiness("paused")
    await blocked.finish()
    await connection.waitForSnapshotForTesting()
    #expect(await connection.cachedReadinessForTesting() == "paused")
    await connection.stop()
    // Release any final provider task that started with the last heartbeat.
    await blocked.finish()
}

@Test @MainActor func desktopSessionSnapshotRequiresExplicitCurrentUnlock() {
    let uid = getuid()
    let valid: [String: Any] = [kCGSessionUserIDKey as String: NSNumber(value: uid),
        kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true,
        "CGSSessionScreenIsLocked": false]
    #expect(DesktopControlSessionLock.classify(valid, userID: uid) == .unlocked)
    #expect(DesktopControlSessionLock.classify(valid, userID: uid + 1) == .inactive)
    #expect(DesktopControlSessionLock.classify(nil, userID: uid) == .unknown)
    var missing = valid
    missing.removeValue(forKey: "CGSSessionScreenIsLocked")
    #expect(DesktopControlSessionLock.classify(missing, userID: uid) == .unknown)
    for malformed in ["false", 0, 2] as [Any] {
        var invalid = valid
        invalid["CGSSessionScreenIsLocked"] = malformed
        #expect(DesktopControlSessionLock.classify(invalid, userID: uid) == .unknown)
    }
    var locked = valid
    locked["CGSSessionScreenIsLocked"] = true
    #expect(DesktopControlSessionLock.classify(locked, userID: uid) == .locked)
    var inactive = valid
    inactive[kCGSessionOnConsoleKey as String] = false
    #expect(DesktopControlSessionLock.classify(inactive, userID: uid) == .inactive)
}

@Test @MainActor func desktopSessionSleepAndObservedLockHaveDifferentRecovery() {
    let workspace = NotificationCenter()
    let activation = NotificationCenter()
    var snapshot = DesktopControlSessionLock.Snapshot.unlocked
    let monitor = DesktopControlSessionLock(workspaceCenter: workspace, activationCenter: activation,
                                           snapshotReader: { snapshot })
    #expect(monitor.state == .unlocked)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(monitor.state != .unlocked)
    snapshot = .unknown
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(monitor.state == .unknown)
    activation.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.state == .unknown && monitor.isAwakeAndActive)
    monitor.receive(.locked)
    activation.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(monitor.state == .locked)
    monitor.receive(.unlocked)
    #expect(monitor.state == .unlocked)
    workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    #expect(monitor.state != .unlocked)
    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    #expect(monitor.state == .unknown)
}

@Test func expiredNativeFileCommandHasNoSideEffects() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let files = DesktopFileSystem()
    await #expect(throws: DesktopControlExecution.Expired.self) {
        try await DesktopControlExecution.$deadline.withValue(.distantPast) {
            try await files.makeDirectory(path: path)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func expiredNativeShellCommandDoesNotStartAProcess() async throws {
    let shell = DesktopShellExecutor()
    await #expect(throws: DesktopControlExecution.Expired.self) {
        try await DesktopControlExecution.$deadline.withValue(.distantPast) {
            _ = try await shell.start(command: "exit 0", workingDirectory: "/tmp")
        }
    }
    #expect(await shell.diagnostics().activeProcesses == 0)
}

@Test @MainActor func browserPreparationUsesOnlyAnIsolatedHostOwnedProfile() throws {
    let prepared = try DesktopControlCommandExecutor.cuaArguments(name: "browser_prepare",
        arguments: .object(["confirm": .bool(true)]), controlToken: "owned-session")
    #expect(prepared == .object(["session": .string("owned-session"), "allow_launch": .bool(true),
                                "profile": .object(["mode": .string("isolated_new")])]))
    for input in [.object([:]), .object(["confirm": .bool(false)]),
        .object(["confirm": .bool(true), "pid": .number(123)]),
        .object(["confirm": .bool(true), "strategy": .object(["kind": .string("existing_profile")])]),
        .object(["confirm": .bool(true), "session": .string("foreign")])] as [DesktopControlJSONValue] {
        #expect(throws: (any Error).self) {
            try DesktopControlCommandExecutor.cuaArguments(name: "browser_prepare", arguments: input, controlToken: "owned-session")
        }
    }
    let observed = try DesktopControlCommandExecutor.cuaArguments(name: "get_browser_state",
        arguments: .object(["pid": .number(123)]), controlToken: "owned-session")
    #expect(observed == .object(["pid": .number(123), "session": .string("owned-session")]))
    #expect(throws: (any Error).self) {
        try DesktopControlCommandExecutor.cuaArguments(name: "browser_navigate",
            arguments: .object(["session": .string("foreign")]), controlToken: "owned-session")
    }
}

@Test func cuaRefusalsKeepRecoveryCodesWithoutReturningPrivateContent() {
    let result: [String: Any] = ["isError": true, "content": [["type": "text", "text": "private-content"]],
        "structuredContent": ["refusal": ["code": "browser_requires_setup", "message": "private-content"]]]
    let failure = DesktopCuaFailure.from(result, tool: "get_browser_state")
    #expect(failure.code == "browser_requires_setup")
    #expect(failure.message.contains("browser_prepare"))
    #expect(!failure.message.contains("private-content"))
    let unknown = DesktopCuaFailure.from(["structuredContent": ["refusal": ["code": "private-content"]]], tool: "click")
    #expect(unknown.code == "desktop_cua_failure_unknown")
    #expect(unknown.message.contains("partly completed"))
    #expect(!unknown.message.contains("private-content"))
}

@Test func cuaFailuresMapReviewedStructuredReasonLocationsToFixedMessages() {
    let cases: [(result: [String: Any], tool: String, code: String, message: String)] = [
        (["structuredContent": ["code": "invalid_arguments", "detail": "/private/input"]],
         "click", "invalid_arguments", "required fields and valid ranges"),
        (["structuredContent": ["code": "window_target_not_found", "pid": 451]],
         "click", "window_target_not_found", "Discover the current applications and windows"),
        (["structuredContent": ["code": "permission_denied", "message": "private policy detail"]],
         "click", "permission_denied", "current authorization or policy"),
        (["structuredContent": ["error": "LAUNCH_CALLBACK_TIMEOUT", "path": "/private/app",
                                "launch_state": ["process_running": false, "window_ready": false]]],
         "launch_app", "LAUNCH_CALLBACK_TIMEOUT", "app or URL may already have opened"),
        (["structuredContent": ["error": "APP_NOT_INSTALLED", "bundle_id": "private.bundle"]],
         "launch_app", "APP_NOT_INSTALLED", "could not find an installed macOS app"),
        (["structuredContent": ["refusal": ["code": "browser_input_incomplete", "message": "private text"]]],
         "click", "browser_input_incomplete", "Do not repeat the entire input blindly."),
    ]

    for item in cases {
        let failure = DesktopCuaFailure.from(item.result, tool: item.tool)
        #expect(failure.code == item.code)
        #expect(failure.message.contains(item.message))
        #expect(!failure.message.contains("/private"))
        #expect(!failure.message.contains("private text"))
        #expect(!failure.message.contains("private policy detail"))
        #expect(!failure.message.contains("window_ready"))
    }

    let unknown = DesktopCuaFailure.from(
        ["structuredContent": ["code": "private_unknown_code", "detail": "private detail"]], tool: "click"
    )
    #expect(unknown.code == "desktop_cua_failure_unknown")
    #expect(unknown.message.contains("unrecognized failure"))
    #expect(unknown.message.contains("may have partly completed"))
    #expect(!unknown.message.contains("private_unknown_code"))
    #expect(!unknown.message.contains("private detail"))

    let unrelatedLaunchError = DesktopCuaFailure.from(
        ["structuredContent": ["error": "NSWORKSPACE_LAUNCH_FAILED", "message": "private launch detail"]],
        tool: "get_desktop_state"
    )
    #expect(unrelatedLaunchError.code == "desktop_cua_failure_unknown")
    #expect(unrelatedLaunchError.message.contains("unrecognized failure"))
    #expect(!unrelatedLaunchError.message.contains("launch"))
    #expect(!unrelatedLaunchError.message.contains("private launch detail"))
}

@Test @MainActor func expiredCommandCannotAcquireControl() async {
    let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    let target = DesktopControlTarget(installationID: "i", workspaceID: "w", configID: "c", personaID: "p", runID: "r", generation: 1)
    let response = await executor.handle(DesktopControlFrame(type: "command", requestID: "expired", target: target,
        operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: .distantPast), proxy: nil)
    #expect(response.errorCode == "desktop_command_expired")
    let acquired = await executor.handle(DesktopControlFrame(type: "command", requestID: "fresh", target: target,
        operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: .distantFuture), proxy: nil)
    #expect(acquired.type == "result")
    _ = await executor.close()
}
