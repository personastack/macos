import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private final class IMessageRuntimeSocket: DesktopControlSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
    private var sent: [DesktopControlFrame] = []
    private var waiters: [(String, CheckedContinuation<DesktopControlFrame, Never>)] = []
    private var closed = false
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let pending = lock.withLock { closed = true; let value = receiver; receiver = nil; return value }
        pending?.resume(throwing: CancellationError())
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            if !queued.isEmpty { let value = queued.removeFirst(); lock.unlock(); continuation.resume(returning: value); return }
            #expect(receiver == nil)
            receiver = continuation
            lock.unlock()
        }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw CancellationError() }
        let frame = try DesktopControlFrameCodec.decode(data)
        let ready = lock.withLock {
            sent.append(frame)
            let values = waiters.filter { $0.0 == frame.requestID }
            waiters.removeAll { $0.0 == frame.requestID }
            return values
        }
        for (_, waiter) in ready { waiter.resume(returning: frame) }
    }
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) { pongReceiveHandler(nil) }
    func push(_ frame: DesktopControlFrame) throws {
        let message = URLSessionWebSocketTask.Message.data(try DesktopControlFrameCodec.encode(frame))
        let pending = lock.withLock {
            let pending = receiver; receiver = nil
            if pending == nil { queued.append(message) }
            return pending
        }
        pending?.resume(returning: message)
    }
    func response(_ id: String) async -> DesktopControlFrame {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value = sent.first(where: { $0.requestID == id }) { lock.unlock(); continuation.resume(returning: value); return }
            waiters.append((id, continuation))
            lock.unlock()
        }
    }
}

private actor IMessageGatewayProviderFixture: IMessageSetupProviding {
    private var pending: CheckedContinuation<Void, any Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var held = true
    private(set) var calls = 0
    private(set) var stops = 0
    private(set) var completed = false
    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult {
        calls += 1
        defer { completed = true }
        if held { try await withCheckedThrowingContinuation { pending = $0; entered?.resume(); entered = nil } }
        try Task.checkCancellation()
        return .init(databaseReady: true)
    }
    func waitUntilHeld() async { if pending == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { held = false; pending?.resume(); pending = nil }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int, deadline: Date) async throws -> IMessageSetupProviderPage {
        Issue.record("Unexpected native gateway inventory operation"); throw IMessageSetupProviderError.dependencyInvalid
    }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date) async throws -> IMessageSetupProviderVerification {
        Issue.record("Unexpected native gateway verify operation"); throw IMessageSetupProviderError.dependencyInvalid
    }
    func stop() { stops += 1; pending?.resume(throwing: CancellationError()); pending = nil }
}

private func gatewayRuntimeInstallation() throws -> DesktopControlInstallation {
    try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"gateway-mac","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8))
}

private func gatewayRuntimeScope() -> IMessageGatewaySetupScope {
    .init(setupReferenceSHA256: IMessageSetupProvider.setupReferenceDigest(String(repeating: "A", count: 43)),
        generation: 1, workspaceID: "w", userID: "u", expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), enabled: true)
}

private func gatewayRuntimeCommand(_ id: String, revision: Int64 = 1) -> IMessageGatewayCommand {
    .init(requestID: id, authorizationID: "auth-\(id)", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
        target: .init(installationID: "gateway-mac", workspaceID: "w", snapshotRevision: revision),
        caller: .init(setupSession: .init(userID: "u", setupReference: String(repeating: "A", count: 43), setupGeneration: 1)), input: .prerequisites)
}

@Test func iMessageGatewayRuntimeInstallsAndAdmitsInWireOrderWithoutBlockingSnapshotOrHeartbeat() async throws {
    let socket = IMessageRuntimeSocket()
    let provider = IMessageGatewayProviderFixture()
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider,
        referenceDigest: { IMessageSetupProvider.setupReferenceDigest($0) })
    let scope = gatewayRuntimeScope()
    let receipt = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: scope)
    try await runtime.activateLocalSetup(receipt)
    try await runtime.setMetadataConsent(true, for: receipt)
    try socket.push(.init(type: "ready", imessageProtocolVersion: 1))
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        iMessageRuntime: runtime) { _, _ in Issue.record("iMessage must not use the Desktop Control handler"); return .init(type: "failure") }
    try await connection.connect()
    #expect(await connection.heartbeatFrame().imessageProtocolVersion == 1)
    try socket.push(.init(type: "imessage", requestID: "snapshot-1", imessage: .snapshot(.init(installationID: "gateway-mac", revision: 1, setupScope: scope))))
    #expect(await socket.response("snapshot-1").imessage == .snapshotAck(.init(revision: 1)))
    try socket.push(.init(type: "imessage", requestID: "first", imessage: .command(gatewayRuntimeCommand("first"))))
    await provider.waitUntilHeld()
    try socket.push(.init(type: "heartbeat", lastHeartbeat: Date(), imessageProtocolVersion: 1))
    try socket.push(.init(type: "imessage", requestID: "snapshot-2", imessage: .snapshot(.init(installationID: "gateway-mac", revision: 2, setupScope: scope))))
    #expect(await socket.response("snapshot-2").imessage == .snapshotAck(.init(revision: 2)))
    try socket.push(.init(type: "imessage", requestID: "second", imessage: .command(gatewayRuntimeCommand("second", revision: 2))))
    await provider.release()
    for id in ["first", "second"] {
        guard case .result(.prerequisites(let result))? = await socket.response(id).imessage else { Issue.record("Missing typed metadata result"); continue }
        #expect(result.databaseReady && result.adapterRevision == 2)
    }
    #expect(await provider.calls == 2)
    #expect(await connection.isConnected())
    await connection.stop()
}

@Test(arguments: [false, true])
func iMessageGatewayRuntimeUnsupportedOrUninjectedFamilyKeepsDesktopControlSocket(injected: Bool) async throws {
    let socket = IMessageRuntimeSocket()
    let provider = IMessageGatewayProviderFixture()
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider,
        referenceDigest: { IMessageSetupProvider.setupReferenceDigest($0) })
    try socket.push(.init(type: "ready", imessageProtocolVersion: injected ? 2 : 1))
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        iMessageRuntime: injected ? runtime : nil) { frame, _ in .init(type: "result", requestID: frame.requestID, result: .object(["available": .bool(true)])) }
    try await connection.connect()
    #expect(await connection.heartbeatFrame().imessageProtocolVersion == nil)
    try socket.push(.init(type: "imessage", requestID: "im-denied", imessage: .command(gatewayRuntimeCommand("im-denied"))))
    guard case .failure(let denied)? = await socket.response("im-denied").imessage else { Issue.record("Unsupported family did not fail safely"); return }
    #expect(denied.code == .capabilityDisabled)
    let target = DesktopControlTarget(installationID: "gateway-mac", workspaceID: "w", configID: "c", personaID: "p", runID: "r", generation: 1)
    try socket.push(.init(type: "command", requestID: "desktop", target: target, operation: "desktop_control_status",
        arguments: .object([:]), deadlineAt: Date().addingTimeInterval(10)))
    #expect(await socket.response("desktop").type == "result")
    #expect(await connection.isConnected())
    #expect(await provider.calls == 0)
    await connection.stop()
}


@Test func iMessageGatewayStopAndDrainJoinsHeldProviderWithoutDesktopExecution() async throws {
    let socket = IMessageRuntimeSocket()
    let provider = IMessageGatewayProviderFixture()
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider,
        referenceDigest: { IMessageSetupProvider.setupReferenceDigest($0) })
    let scope = gatewayRuntimeScope()
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: scope)
    try await runtime.activateLocalSetup(intent)
    try socket.push(.init(type: "ready", imessageProtocolVersion: 1))
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        iMessageRuntime: runtime) { _, _ in Issue.record("No Desktop Control execution during iMessage cleanup"); return .init(type: "failure") }
    try await connection.connect()
    try socket.push(.init(type: "imessage", requestID: "snapshot", imessage: .snapshot(.init(installationID: "gateway-mac", revision: 1, setupScope: scope))))
    #expect(await socket.response("snapshot").imessage == .snapshotAck(.init(revision: 1)))
    try socket.push(.init(type: "imessage", requestID: "held", imessage: .command(gatewayRuntimeCommand("held"))))
    await provider.waitUntilHeld()
    await connection.stopAndDrainIMessage()
    #expect(await provider.completed)
    #expect(await provider.stops > 0)
    #expect(!(await connection.isConnected()))
    await runtime.drain()
}


private struct IMessageSessionCredentials: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation
    func load() -> DesktopControlInstallation? { installation }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Unexpected credential write") }
    func delete() throws { Issue.record("Unexpected credential removal") }
}
private struct IMessageSessionInstaller: DesktopControlDriverInstalling {
    func discoverExisting() async throws -> CuaDriverInstallation? { Issue.record("iMessage setup must not start CUA"); throw CancellationError() }
    func install() async throws -> CuaDriverInstallation { Issue.record("iMessage setup must not install CUA"); throw CancellationError() }
}
private struct IMessageSessionAccounts: IMessageSetupAccountReading {
    func prepareProviderConnection(_ client: IMessageRPCClient) async { await client.stop() }
    func clearProviderBinding() {}
    func validateProviderConnection() {}
    func observeCurrentAccount() -> IMessageCurrentAccountObservation {
        .init(accountID: "account", sourceGeneration: "source", accountLabel: "Messages")
    }
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) -> IMessageLiveAccountObservation {
        Issue.record("Unplanned selected-account observation")
        return .init(accountID: "account", sourceGeneration: "source", chatGUIDs: chatGUIDs)
    }
}
private actor IMessageSessionProviderTransport: IMessageRPCTransport {
    private var bytes = Data()
    private var closed = false
    private var receiver: CheckedContinuation<Data, any Error>?
    private(set) var launches = 0
    func launch() { launches += 1; closed = false }
    func terminate() { closed = true; bytes.removeAll(); receiver?.resume(returning: Data()); receiver = nil }
    func read(maximumBytes: Int) async throws -> Data {
        if closed { return Data() }
        if !bytes.isEmpty { let value = Data(bytes.prefix(maximumBytes)); bytes.removeFirst(value.count); return value }
        #expect(receiver == nil)
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func write(_ data: Data) throws {
        let decoded = try JSONSerialization.jsonObject(with: data)
        let request = try #require(decoded as? [String: Any])
        let method = try #require(request["method"] as? String)
        let id = try #require(request["id"] as? String)
        let result: [String: Any]
        switch method {
        case "personastack.initialize", "personastack.status":
            result = ["protocol_version": 1, "personastack_adapter_revision": 2, "database": ["ready": true],
                "methods": ["personastack.initialize", "personastack.status", "personastack.send", "personastack.chats.page",
                    "personastack.chatMetadata", "personastack.source_checkpoint", "personastack.receive_page", "personastack.recent_messages"]]
        case "personastack.chats.page":
            result = ["chats": [["id": "1", "guid": "selected-guid", "name": "Selected", "service": "iMessage",
                "is_group": false, "available": true, "participants": ["participant"]]],
                "next_chat_rowid": "1", "upper_chat_rowid": "1", "has_more": false, "stop_reason": "caught_up"]
        default: Issue.record("Unplanned provider RPC \(method)"); throw IMessageRPCError.invalidArguments
        }
        var frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]); frame.append(0x0a)
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) } else { bytes.append(frame) }
    }
}

@MainActor private final class IMessageSessionFactoryState {
    var sockets: [IMessageRuntimeSocket] = []
    var providers: [IMessageSessionProviderTransport] = []
    func socket() -> any DesktopControlSocket {
        let socket = IMessageRuntimeSocket()
        do { try socket.push(.init(type: "ready", imessageProtocolVersion: 1)) } catch { Issue.record("Cannot encode fixture ready") }
        sockets.append(socket)
        return socket
    }
    func provider() -> IMessageSetupProvider {
        let transport = IMessageSessionProviderTransport()
        providers.append(transport)
        return IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: IMessageSessionAccounts())
    }
}

private func sessionReplacementIntent(_ generation: Int64) -> IMessageRuntimeSetupIntent {
    .init(localGeneration: UUID(), scope: .init(setupReferenceSHA256: IMessageSetupProvider.setupReferenceDigest(String(repeating: "A", count: 43)),
        generation: generation, workspaceID: "w", userID: "u", expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)), enabled: true))
}

private func sessionReplacementSnapshot(_ intent: IMessageRuntimeSetupIntent, revision: Int64, id: String, socket: IMessageRuntimeSocket) async throws -> DesktopControlFrame {
    try socket.push(.init(type: "imessage", requestID: id,
        imessage: .snapshot(.init(installationID: "gateway-mac", revision: revision, setupScope: intent.scope))))
    return await socket.response(id)
}

private func sessionReplacementMetadata(_ intent: IMessageRuntimeSetupIntent, revision: Int64, id: String, socket: IMessageRuntimeSocket) async throws -> DesktopControlFrame {
    let command = IMessageGatewayCommand(requestID: id, authorizationID: "grant-\(id)", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
        target: .init(installationID: "gateway-mac", workspaceID: "w", snapshotRevision: revision),
        caller: .init(setupSession: .init(userID: "u", setupReference: String(repeating: "A", count: 43), setupGeneration: intent.scope.generation)),
        input: .setupConversations(.init(limit: 10)))
    try socket.push(.init(type: "imessage", requestID: id, imessage: .command(command)))
    return await socket.response(id)
}

@Test(arguments: [false, true]) @MainActor
func iMessageSessionReplacementAllowsFreshSetupOnTheCurrentGatewayActor(permanent: Bool) async throws {
    let state = IMessageSessionFactoryState()
    let installation = try gatewayRuntimeInstallation()
    let preferences = try #require(UserDefaults(suiteName: "IMessageSessionReplacement-\(UUID().uuidString)"))
    let runtime = DesktopControlRuntime.makeForTesting(installer: IMessageSessionInstaller(), credentials: IMessageSessionCredentials(installation: installation),
        iMessageProviderFactory: { state.provider() }, gatewaySocketFactory: { state.socket() }, paused: true,
        sessionLockState: .unlocked, scheduleReconnect: false, preferences: preferences)
    let original = try await runtime.iMessageSetupSession()
    let oldIntent = sessionReplacementIntent(1)
    try await original.runtime.activateLocalSetup(oldIntent)
    try await original.runtime.setMetadataConsent(true, for: oldIntent)
    _ = try await runtime.resumeIMessageSetupRelay(for: oldIntent)
    let first = try #require(state.sockets.first)
    #expect(try await sessionReplacementSnapshot(oldIntent, revision: 1, id: "first-snapshot", socket: first).imessage == .snapshotAck(.init(revision: 1)))
    let initial = try await sessionReplacementMetadata(oldIntent, revision: 1, id: "initial-metadata", socket: first)
    guard case .result(.conversationsPage(let initialPage))? = initial.imessage else { Issue.record("Initial metadata not admitted"); return }
    #expect(initialPage.conversations.count == 1)
    if permanent { await runtime.drainIMessage() }
    else { await runtime.suspendIMessageForReplacement() }
    #expect(runtime.gatewayConnected)
    let desktopTarget = DesktopControlTarget(installationID: "gateway-mac", workspaceID: "w", configID: "desktop", personaID: "persona", runID: "run", generation: 1)
    try first.push(.init(type: "command", requestID: "desktop-still-connected", target: desktopTarget,
        operation: "desktop_control_status", arguments: .object([:]), deadlineAt: Date().addingTimeInterval(10)))
    #expect(await first.response("desktop-still-connected").type == "result")
    let denied = try await sessionReplacementMetadata(oldIntent, revision: 1, id: "old-denied", socket: first)
    guard case .failure(let oldFailure)? = denied.imessage else { Issue.record("Old scope survived replacement preparation"); return }
    #expect(oldFailure.code == .scopeDenied)
    await #expect(throws: IMessageSetupProviderError.accountChanged) { try await original.runtime.setMetadataConsent(true, for: oldIntent) }
    let current = try await runtime.iMessageSetupSession()
    #expect((current.runtime === original.runtime) == !permanent)
    let newIntent = sessionReplacementIntent(2)
    try await current.runtime.activateLocalSetup(newIntent)
    try await current.runtime.setMetadataConsent(true, for: newIntent)
    _ = try await runtime.resumeIMessageSetupRelay(for: newIntent)
    #expect(state.sockets.count == (permanent ? 2 : 1))
    let active = try #require(state.sockets.last)
    #expect(try await sessionReplacementSnapshot(newIntent, revision: 2, id: "new-snapshot", socket: active).imessage == .snapshotAck(.init(revision: 2)))
    let stale = try await sessionReplacementSnapshot(oldIntent, revision: 1, id: "old-snapshot", socket: active)
    guard case .failure(let staleFailure)? = stale.imessage else { Issue.record("Old setup scope was restored"); return }
    #expect(staleFailure.code == .scopeDenied)
    #expect(try await sessionReplacementSnapshot(newIntent, revision: 3, id: "current-snapshot", socket: active).imessage == .snapshotAck(.init(revision: 3)))
    let response = try await sessionReplacementMetadata(newIntent, revision: 3, id: "fresh-metadata", socket: active)
    guard case .result(.conversationsPage(let page))? = response.imessage else { Issue.record("Fresh setup metadata stayed bound to a retired actor"); return }
    #expect(page.conversations.count == 1)
    #expect(page.conversations.first?.metadata.guid == "selected-guid")
    #expect(state.providers.count == (permanent ? 2 : 1))
    await runtime.shutdownForQuit()
}
