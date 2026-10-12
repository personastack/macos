import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

/// CUA keeps a public name bound to its first transport after end_session.
private actor WorkflowCuaLifecycle {
    private var owners: [String: UUID] = [:]
    private var active: Set<String> = []

    func result(tool: String, session: String, owner: UUID) -> DesktopControlJSONValue {
        if tool == "start_session" {
            guard owners[session] == nil || owners[session] == owner else {
                return .object(["isError": .bool(true), "structuredContent": .object([
                    "code": .string("session_unavailable"), "detail": .string("private transport identity"),
                ])])
            }
            owners[session] = owner
            active.insert(session)
        } else if tool == "end_session" {
            if owners[session] == owner { active.remove(session) }
        } else {
            guard owners[session] == owner, active.contains(session) else {
                Issue.record("Observation reached an unavailable CUA session")
                return .object(["isError": .bool(true)])
            }
            return .object(["content": .array([])])
        }
        return .object(["structuredContent": .object([
            "session": .string(session), "active": .bool(tool == "start_session"),
        ])])
    }
}

private actor WorkflowCua: CuaToolCalling {
    struct Expected: Sendable {
        let name: String
        var fields: [String: DesktopControlJSONValue] = [:]
        var result: DesktopControlJSONValue? = nil
        var timeout: Int32 = 60
    }
    private var expected: [Expected]
    private var session: String?
    private var sessionEnded = false
    private var calls = 0
    private var endGate: CheckedContinuation<Void, Never>?
    private let suspendEnd: Bool
    private let lifecycle: WorkflowCuaLifecycle?
    private let transportOwner = UUID()
    init(_ expected: [Expected], suspendEnd: Bool = false, lifecycle: WorkflowCuaLifecycle? = nil) {
        self.expected = expected
        self.suspendEnd = suspendEnd
        self.lifecycle = lifecycle
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
        if sessionEnded {
            session = nil
            sessionEnded = false
        }
        if let session { #expect(owned == session) } else { session = owned }
        #expect(name == next.name)
        #expect(fields == next.fields)
        #expect(timeout == next.timeout)
        calls += 1
        guard name == next.name, fields == next.fields, timeout == next.timeout else {
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        if name == "end_session", suspendEnd { await withCheckedContinuation { endGate = $0 } }
        var lifecycleResult: DesktopControlJSONValue?
        if let lifecycle { lifecycleResult = await lifecycle.result(tool: name, session: owned, owner: transportOwner) }
        var result = next.result ?? lifecycleResult ?? (["start_session", "end_session"].contains(name)
            ? .object(["structuredContent": .object(["session": .string(owned), "active": .bool(name == "start_session")])])
            : .object(["content": .array([])]))
        if case .object(var fields) = result,
           case .object(var confirmation)? = fields["structuredContent"], confirmation["session"] == .null {
            confirmation["session"] = .string(owned)
            fields["structuredContent"] = .object(confirmation)
            result = .object(fields)
        }
        if name == "end_session" { sessionEnded = true }
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

    private func frame(_ operation: String, _ fields: [String: DesktopControlJSONValue] = [:],
                       target: DesktopControlTarget? = nil) -> DesktopControlFrame {
        DesktopControlFrame(type: "command", requestID: UUID().uuidString, target: target ?? self.target, operation: operation,
            arguments: .object(fields), deadlineAt: Date().addingTimeInterval(30))
    }
    private func acquire(_ executor: DesktopControlCommandExecutor, target: DesktopControlTarget? = nil) async throws -> String {
        let response = await executor.handle(frame("desktop_control_acquire", target: target), proxy: nil)
        #expect(response.type == "result")
        guard case .object(let fields)? = response.result, case .string(let token)? = fields["control_token"] else {
            throw CuaToolCatalog.ValidationError.invalidArguments
        }
        return token
    }
    private func call(_ executor: DesktopControlCommandExecutor, _ proxy: WorkflowCua, _ token: String,
                      _ tool: String, _ arguments: [String: DesktopControlJSONValue] = [:],
                      target: DesktopControlTarget? = nil) async -> DesktopControlFrame {
        await executor.handle(frame("desktop_control_cua", ["control_token": .string(token),
            "tool": .string(tool), "arguments": .object(arguments)], target: target), proxy: proxy)
    }

    private func namedTarget(_ name: String, run: String = "fixture-run") -> DesktopControlTarget {
        DesktopControlTarget(installationID: target.installationID, workspaceID: target.workspaceID,
            configID: target.configID, personaID: target.personaID, runID: run, generation: target.generation,
            ownerDisplay: .init(personaName: name, workspaceName: "Fixture workspace"))
    }

    @Test(arguments: ["Lumina", "  Lumina  ", "default", "__cua_runtime_persona", "研究者 🌟"])
    func personaCursorLabelKeepsItsNameWithAFreshIdentityForEachLease(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedLabel = trimmed == "default" || trimmed.hasPrefix("__cua_runtime_") ? "Persona: \(trimmed)" : trimmed
        let steps: [WorkflowCua.Expected] = [.init(name: "start_session"), .init(name: "get_config"),
            .init(name: "get_config"), .init(name: "end_session", timeout: 5)]
        let proxy = WorkflowCua(steps + steps)
        let executor = DesktopControlCommandExecutor()
        var previousToken: String?
        var previousSession: String?
        for run in ["first-run", "second-run"] {
            let owner = namedTarget(name, run: run)
            let token = try await acquire(executor, target: owner)
            #expect(token != previousToken)
            previousToken = token
            #expect(await call(executor, proxy, token, "get_config", target: owner).type == "result")
            let session = try #require(await proxy.observedSession())
            #expect(session.hasPrefix(expectedLabel + " · "))
            #expect(UUID(uuidString: String(session.dropFirst(expectedLabel.count + 3))) != nil)
            #expect(session != previousSession)
            #expect(!session.lowercased().contains(token.lowercased()))
            previousSession = session
            // Refreshing display metadata cannot switch an active CUA session.
            let renamed = namedTarget("Renamed persona", run: run)
            #expect(try await acquire(executor, target: renamed) == token)
            #expect(await call(executor, proxy, token, "get_config", target: renamed).type == "result")
            #expect(await proxy.observedSession() == session)
            #expect(await executor.handle(frame("desktop_control_release", ["control_token": .string(token)], target: owner),
                proxy: proxy).type == "result")
        }
        #expect(await proxy.callCount() == 8)
        await proxy.assertDrained()
        #expect(await executor.close())
    }

    @Test(arguments: ["foreign", "inactive", "missing", "numeric"])
    func unconfirmedNamedSessionNeverDispatchesTheRequestedTool(mode: String) async throws {
        let owner = namedTarget("Lumina")
        let result: DesktopControlJSONValue = mode == "missing" ? .object([:]) : .object([
            "structuredContent": .object(["session": mode == "foreign" ? .string("Another persona") : .null,
                                          "active": mode == "numeric" ? .number(1) : .bool(mode != "inactive")]),
        ])
        let proxy = WorkflowCua([.init(name: "start_session", result: result), .init(name: "end_session", timeout: 5)])
        let executor = DesktopControlCommandExecutor()
        let token = try await acquire(executor, target: owner)
        #expect(await call(executor, proxy, token, "get_config", target: owner).type == "failure")
        #expect(await proxy.callCount() == 1)
        #expect(await executor.close())
        await proxy.assertDrained()
    }

    @Test(arguments: [false, true])
    func reconnectAndAppRestartUseFreshSessionsForTheSamePersona(restart: Bool) async throws {
        let lifecycle = WorkflowCuaLifecycle()
        let steps: [WorkflowCua.Expected] = [
            .init(name: "start_session"), .init(name: "get_desktop_state"),
            .init(name: "list_windows"), .init(name: "end_session", timeout: 5),
        ]
        let firstProxy = WorkflowCua(steps, lifecycle: lifecycle)
        let firstExecutor = DesktopControlCommandExecutor()
        let firstOwner = namedTarget("Lumina", run: "before-reconnect")
        let firstToken = try await acquire(firstExecutor, target: firstOwner)
        for tool in ["get_desktop_state", "list_windows"] {
            #expect(await call(firstExecutor, firstProxy, firstToken, tool, target: firstOwner).type == "result")
        }
        let firstSession = try #require(await firstProxy.observedSession())
        #expect(await firstExecutor.handle(frame("desktop_control_release", ["control_token": .string(firstToken)],
            target: firstOwner), proxy: firstProxy).type == "result")
        if restart { #expect(await firstExecutor.close()) }

        let nextProxy = WorkflowCua(steps, lifecycle: lifecycle)
        let nextExecutor = restart ? DesktopControlCommandExecutor() : firstExecutor
        let nextOwner = namedTarget("Lumina", run: "after-reconnect")
        let nextToken = try await acquire(nextExecutor, target: nextOwner)
        for tool in ["get_desktop_state", "list_windows"] {
            #expect(await call(nextExecutor, nextProxy, nextToken, tool, target: nextOwner).type == "result")
        }
        let nextSession = try #require(await nextProxy.observedSession())
        #expect(nextSession != firstSession)
        #expect(await nextExecutor.handle(frame("desktop_control_release", ["control_token": .string(nextToken)],
            target: nextOwner), proxy: nextProxy).type == "result")
        #expect(await nextExecutor.close())
        await firstProxy.assertDrained()
        await nextProxy.assertDrained()
    }

    @Test func unavailableSessionReturnsSafeRecoveryWithoutObserving() async throws {
        let owner = namedTarget("Lumina")
        let proxy = WorkflowCua([
            .init(name: "start_session", result: .object(["isError": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("private transport identity")])]),
                "structuredContent": .object(["code": .string("session_unavailable")])])),
            .init(name: "end_session", timeout: 5),
        ])
        let executor = DesktopControlCommandExecutor()
        let token = try await acquire(executor, target: owner)
        let response = await call(executor, proxy, token, "get_desktop_state", target: owner)
        #expect(response.type == "failure")
        #expect(response.errorCode == "session_unavailable")
        #expect(response.errorMessage?.contains("Release Desktop Control, acquire it again") == true)
        #expect(response.errorMessage?.contains("private transport identity") == false)
        #expect(await proxy.callCount() == 1)
        #expect(await executor.handle(frame("desktop_control_release", ["control_token": .string(token)],
            target: owner), proxy: proxy).type == "result")
        #expect(await executor.close())
        await proxy.assertDrained()
    }

    @Test func upstreamBrowserAndRecordingCallsRemainDirectAndSessionScoped() async throws {
        let operations: [(String, [String: DesktopControlJSONValue])] = [
            ("health_report", [:]), ("get_config", [:]),
            ("browser_prepare", ["allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_new")])]),
            ("page", ["action": .string("get_text"), "pid": .number(123), "window_id": .number(45)]),
            ("start_recording", ["output_dir": .string("/cua/owns/this/path"), "record_video": .bool(false)]),
            ("stop_recording", [:]), ("get_recording_state", [:]),
        ]
        let proxy = WorkflowCua(operations.map { .init(name: $0.0, fields: $0.1) } + [.init(name: "end_session", timeout: 5)])
        let executor = DesktopControlCommandExecutor()
        let token = try await acquire(executor)
        for (name, arguments) in operations {
            let response = await call(executor, proxy, token, name, arguments)
            #expect(response.type == "result", "\(name): \(response.errorCode ?? "")")
        }
        #expect(await proxy.observedSession() != token)
        let fallbackSession = try #require(await proxy.observedSession())
        #expect(UUID(uuidString: fallbackSession) != nil)
        let released = await executor.handle(frame("desktop_control_release", ["control_token": .string(token)]), proxy: proxy)
        #expect(released.type == "result")
        #expect(await call(executor, proxy, token, "get_config").type == "failure")
        await proxy.assertDrained()
        await executor.close()
    }

    @Test func remoteExtensionInstallRequiresNativeSetupWithoutDispatch() async throws {
        let executor = DesktopControlCommandExecutor()
        let proxy = WorkflowCua([])
        let token = try await acquire(executor)
        let rejected = await call(executor, proxy, token, "install_extension", ["name": .string("perception"), "confirm": .bool(true)])
        #expect(rejected.type == "failure")
        #expect(rejected.errorCode == "invalid_arguments")
        #expect(await proxy.callCount() == 0)
        await executor.close()
    }

    @Test func invalidAndPromptingArgumentsNeverReachDriver() async throws {
        let executor = DesktopControlCommandExecutor()
        let proxy = WorkflowCua([])
        let token = try await acquire(executor)
        let invalid: [(String, [String: DesktopControlJSONValue])] = [
            ("unknown_tool", [:]), ("get_config", ["unknown": .bool(true)]),
            ("install_extension", ["name": .string("perception"), "confirm": .bool(true)]),
            ("get_config", ["_session_id": .string("foreign")]),
            ("get_config", ["_public_session_label": .string("Another persona")]),
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
        let executor = DesktopControlCommandExecutor()
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
        let executor = DesktopControlCommandExecutor()
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
