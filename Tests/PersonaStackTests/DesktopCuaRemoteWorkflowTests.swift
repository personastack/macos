import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private actor WorkflowCua: CuaToolCalling {
    struct Expected: Sendable {
        let name: String
        var fields: [String: DesktopControlJSONValue] = [:]
        var result: DesktopControlJSONValue? = nil
        var timeout: Int32 = 60
    }
    private var expected: [Expected]
    private var session: String?
    private var calls = 0
    private var endGate: CheckedContinuation<Void, Never>?
    private let suspendEnd: Bool
    init(_ expected: [Expected], suspendEnd: Bool = false) {
        self.expected = expected
        self.suspendEnd = suspendEnd
    }
    func callTool(name: String, argumentsJSON: Data, timeout: Int32) async throws -> Data {
        guard !expected.isEmpty else {
            Issue.record("Unexpected CUA call: \(name)")
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        let next = expected.removeFirst()
        let body = try JSONDecoder().decode(DesktopControlJSONValue.self, from: argumentsJSON)
        guard case .object(var fields) = body, case .string(let owned)? = fields.removeValue(forKey: "session") else {
            Issue.record("CUA request has no owned session")
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        #expect(!owned.isEmpty)
        if let session { #expect(owned == session) } else { session = owned }
        #expect(name == next.name)
        #expect(fields == next.fields)
        #expect(timeout == next.timeout)
        calls += 1
        guard name == next.name, fields == next.fields, timeout == next.timeout else {
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        if name == "end_session", suspendEnd { await withCheckedContinuation { endGate = $0 } }
        let result = next.result ?? (name == "end_session"
            ? .object(["structuredContent": .object(["session": .string(owned), "active": .bool(false)])])
            : .object(["content": .array([])]))
        return try JSONEncoder().encode(DesktopControlJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "result": result,
        ]))
    }
    func append(_ steps: [Expected]) { expected.append(contentsOf: steps) }
    func finishEnd() { endGate?.resume(); endGate = nil }
    func ending() -> Bool { endGate != nil }
    func observedSession() -> String? { session }
    func callCount() -> Int { calls }
    func assertDrained() { #expect(expected.isEmpty) }
}

@MainActor
struct DesktopCuaRemoteWorkflowTests {
    private let target = DesktopControlTarget(installationID: "fixture-install", workspaceID: "fixture-workspace",
        configID: "fixture-config", personaID: "fixture-persona", runID: "fixture-run", generation: 1, configVersion: nil)

    private func frame(_ operation: String, _ fields: [String: DesktopControlJSONValue] = [:]) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target, operation: operation,
            arguments: .object(fields), deadlineAt: Date().addingTimeInterval(30))
    }
    private func acquire(_ executor: DesktopControlCommandExecutor) async throws -> String {
        let response = await executor.handle(frame("desktop_control_acquire"), proxy: nil)
        #expect(response.type == "result")
        guard case .object(let fields)? = response.result, case .string(let token)? = fields["control_token"] else {
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        return token
    }
    private func call(_ executor: DesktopControlCommandExecutor, _ proxy: WorkflowCua, _ token: String,
                      _ tool: String, _ arguments: [String: DesktopControlJSONValue] = [:]) async -> DesktopControlFrame {
        await executor.handle(frame("desktop_control_cua", ["control_token": .string(token),
            "tool": .string(tool), "arguments": .object(arguments)]), proxy: proxy)
    }

    @Test func ownedSessionSpansGenericBrowserAndRecordingWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.resolvingSymlinksInPath().appendingPathComponent("recording").path
        let ownSummary: DesktopControlJSONValue = .object(["label": .string("owned-fixture")])
        let proxy = WorkflowCua([
            .init(name: "health_report"), .init(name: "get_config"),
            .init(name: "set_config", fields: ["max_image_dimension": .number(1024)]),
            .init(name: "check_permissions", fields: ["prompt": .bool(false), "probe_direct_capture": .bool(false)]),
            .init(name: "browser_prepare", fields: ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")])]),
            .init(name: "start_recording", fields: ["output_dir": .string(output), "record_video": .bool(false)]),
            .init(name: "stop_recording"), .init(name: "get_recording_state"),
            .init(name: "get_session", result: .object(["structuredContent": ownSummary])),
            .init(name: "end_session", timeout: 5),
        ])
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let token = try await acquire(executor)
        let operations: [(String, [String: DesktopControlJSONValue])] = [
            ("health_report", [:]), ("get_config", [:]),
            ("set_config", ["key": .string("max_image_dimension"), "value": .number(1024)]),
            ("check_permissions", [:]), ("browser_prepare", ["confirm": .bool(true)]),
            ("start_recording", ["output_dir": .string(output), "record_video": .bool(false)]),
            ("stop_recording", [:]), ("get_recording_state", [:]),
        ]
        for (name, arguments) in operations {
            let response = await call(executor, proxy, token, name, arguments)
            #expect(response.type == "result", "\(name): \(response.errorCode ?? "")")
        }
        let listed = await call(executor, proxy, token, "list_sessions", ["limit": .number(100)])
        guard case .object(let result)? = listed.result, case .object(let content)? = result["structuredContent"] else {
            Issue.record("Missing scoped session result"); await executor.close(); return
        }
        #expect(content["sessions"] == .array([ownSummary]))
        #expect(content["next_cursor"] == .null)
        #expect(await proxy.observedSession() != token)
        let released = await executor.handle(frame("desktop_control_release", ["control_token": .string(token)]), proxy: proxy)
        #expect(released.type == "result")
        let denied = await call(executor, proxy, token, "get_config")
        #expect(denied.type == "failure")
        #expect(await proxy.callCount() == 10)
        await proxy.assertDrained()
        await executor.close()
    }

    @Test func safariPageReadsRefuseUnqualifiedDriverEvenWhenLocallyApproved() async throws {
        let proxy = WorkflowCua([])
        var checks = 0
        let executor = DesktopControlCommandExecutor(browserConsent: { _, _ in false }, browserPageAccess: { _, _ in
            Issue.record("Safari must not fall back to Chromium approval")
            return false
        }, safariPageReadAccess: { pid, window in
            checks += 1
            return pid == 123 && window == 45
        }, powerAssertion: .testFixture())
        let token = try await acquire(executor)
        for action in ["get_text", "query_dom"] {
            let response = await call(executor, proxy, token, "page", ["action": .string(action), "pid": .number(123), "window_id": .number(45)])
            #expect(response.type == "failure")
            #expect(response.errorCode == "browser_route_unavailable")
        }
        #expect(checks == 2)
        #expect(await proxy.callCount() == 0)
        _ = await executor.handle(frame("desktop_control_release", ["control_token": .string(token)]), proxy: proxy)
        await proxy.assertDrained()
        await executor.close()
    }

    @Test(arguments: ["denied", "leaseExpired", "mutation"])
    func safariPageReadDenialsDoNotReachDriver(mode: String) async throws {
        let proxy = WorkflowCua([])
        var instant = ContinuousClock.now
        var checks = 0
        let executor = DesktopControlCommandExecutor(now: { instant }, browserConsent: { _, _ in false },
            browserPageAccess: { _, _ in false }, safariPageReadAccess: { _, _ in
                checks += 1
                if mode == "leaseExpired" { instant += .seconds(91) }
                return mode != "denied"
            }, powerAssertion: .testFixture())
        let token = try await acquire(executor)
        let response = await call(executor, proxy, token, "page", ["action": .string(mode == "mutation" ? "execute_javascript" : "get_text"),
            "pid": .number(123), "window_id": .number(45), "javascript": .string("1")])
        #expect(response.type == "failure")
        #expect(checks == (mode == "mutation" ? 0 : 1))
        #expect(await proxy.callCount() == 0)
        await executor.close()
    }

    @Test func pageTypingReusesApprovedLeaseAndTypedBrowserTransport() async throws {
        func result(_ text: String) throws -> DesktopControlJSONValue {
            try JSONDecoder().decode(DesktopControlJSONValue.self, from: Data(text.utf8))
        }
        let proxy = WorkflowCua([
            .init(name: "browser_prepare", fields: ["pid": .number(123), "window_id": .number(45), "strategy": .object(["kind": .string("existing_profile")])]),
            .init(name: "get_browser_state", fields: ["pid": .number(123), "window_id": .number(45)], result: try result(#"{"structuredContent":{"status":"ok","mode":"bind","target_id":"target-1","binding_quality":"exact","binding_route":"native_cdp_window","mutation_allowed":true,"tabs":[{"tab_id":"tab-1","active":true}]}}"#)),
            .init(name: "get_browser_state", fields: ["target_id": .string("target-1"), "tab_id": .string("tab-1"), "snapshot_format": .string("semantic_v2"), "include_screenshot": .bool(false)], result: try result(#"{"structuredContent":{"status":"ok","mode":"snapshot","target_id":"target-1","tab_id":"tab-1","snapshot":{"id":"p1","format":"semantic_v2","complete":true},"refs":[{"ref":"p1:1","states":{"focused":true},"actions":["type"],"visibility":"in_viewport"}]}}"#)),
            .init(name: "browser_type", fields: ["target_id": .string("target-1"), "tab_id": .string("tab-1"), "ref": .string("p1:1"), "text": .string("sample"), "replace": .bool(false), "mode": .string("insert_text")]),
            .init(name: "end_session", timeout: 5),
        ])
        let executor = DesktopControlCommandExecutor(browserConsent: { $0 == 123 && $1 == 45 }, browserPageAccess: { _, _ in
            Issue.record("Typed page adapter must not invoke Apple Events permission checks")
            return false
        }, powerAssertion: .testFixture())
        let token = try await acquire(executor)
        #expect(await call(executor, proxy, token, "browser_prepare", ["confirm": .bool(true), "pid": .number(123), "window_id": .number(45), "strategy": .object(["kind": .string("existing_profile")])]).type == "result")
        #expect(await call(executor, proxy, token, "page", ["action": .string("insert_text"), "pid": .number(123), "window_id": .number(45), "text": .string("sample")]).type == "result")
        _ = await executor.handle(frame("desktop_control_release", ["control_token": .string(token)]), proxy: proxy)
        #expect(await proxy.callCount() == 5)
        await proxy.assertDrained()
        await executor.close()
    }

    @Test func remoteExtensionInstallRequiresNativeSetupWithoutDispatch() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let proxy = WorkflowCua([])
        let token = try await acquire(executor)
        let rejected = await call(executor, proxy, token, "install_extension", ["name": .string("perception"), "confirm": .bool(true)])
        #expect(rejected.type == "failure")
        #expect(rejected.errorCode == "native_setup_required")
        #expect(await proxy.callCount() == 0)
        await executor.close()
    }

    @Test func invalidAndPromptingArgumentsNeverReachDriver() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let proxy = WorkflowCua([])
        let token = try await acquire(executor)
        let invalid: [(String, [String: DesktopControlJSONValue])] = [
            ("unknown_tool", [:]), ("get_config", ["unknown": .bool(true)]),
            ("install_extension", ["name": .string("perception"), "confirm": .bool(true)]),
            ("get_config", ["_session_id": .string("foreign")]),
            ("get_config", ["session": .string("foreign")]),
            ("check_permissions", ["prompt": .bool(true)]),
            ("check_permissions", ["probe_direct_capture": .bool(true)]),
            ("set_config", ["key": .string("telemetry_enabled"), "value": .bool(true)]),
            ("browser_prepare", ["confirm": .bool(false)]),
        ]
        for (name, fields) in invalid {
            #expect(await call(executor, proxy, token, name, fields).type == "failure")
        }
        #expect(await proxy.callCount() == 0)
        await executor.close()
    }

    @Test func cleanupMustFinishBeforeAnotherLeaseCanAcquire() async throws {
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let proxy = WorkflowCua([.init(name: "get_config"), .init(name: "end_session", timeout: 5)], suspendEnd: true)
        let token = try await acquire(executor)
        #expect(await call(executor, proxy, token, "get_config").type == "result")
        let releaseFrame = frame("desktop_control_release", ["control_token": .string(token)])
        let release = Task { await executor.handle(releaseFrame, proxy: proxy) }
        for _ in 0..<10_000 {
            if await proxy.ending() { break }
            await Task.yield()
        }
        #expect(await proxy.ending())
        let blocked = await executor.handle(frame("desktop_control_acquire"), proxy: nil)
        #expect(blocked.type == "failure")
        await proxy.finishEnd()
        #expect(await release.value.type == "result")
        let nextToken = try await acquire(executor)
        #expect(nextToken != token)
        await proxy.assertDrained()
        await executor.close()
    }
    @Test(arguments: ["missing", "foreign", "active", "numeric", "error"])
    func cleanupRequiresExactOwnedInactiveSessionProof(mode: String) async throws {
        // Use the observed host session in malformed confirmations where the
        // active flag, rather than the owner label, is the negative control.
        let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
        let proxy = WorkflowCua([.init(name: "get_config")])
        let token = try await acquire(executor)
        #expect(await call(executor, proxy, token, "get_config").type == "result")
        let owned = try #require(await proxy.observedSession())
        var confirmation: [String: DesktopControlJSONValue] = ["session": .string(owned), "active": .bool(false)]
        if mode == "foreign" { confirmation["session"] = .string("another-session") }
        if mode == "active" { confirmation["active"] = .bool(true) }
        if mode == "numeric" { confirmation["active"] = .number(0) }
        let malformed: DesktopControlJSONValue = mode == "missing" ? .object([:]) : .object([
            "structuredContent": .object(confirmation), "isError": .bool(mode == "error"),
        ])
        await proxy.append([.init(name: "end_session", result: malformed, timeout: 5), .init(name: "end_session", timeout: 5)])
        let released = await executor.handle(frame("desktop_control_release", ["control_token": .string(token)]), proxy: proxy)
        #expect(released.type == "failure")
        #expect(await executor.handle(frame("desktop_control_acquire"), proxy: nil).type == "failure")
        #expect(await executor.close())
        await proxy.assertDrained()
    }

}
