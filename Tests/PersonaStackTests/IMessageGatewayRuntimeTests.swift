import AppKit
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
    private var failingRequestID: String?
    private var failedReplies: [DesktopControlFrame] = []
    func failReply(for requestID: String) { lock.withLock { failingRequestID = requestID } }
    func rejectedReplies() -> [DesktopControlFrame] { lock.withLock { failedReplies } }
    func recordedResponse(_ id: String) -> DesktopControlFrame? { lock.withLock { sent.first { $0.requestID == id } } }
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
        let reject = lock.withLock {
            guard let failingRequestID, frame.requestID == failingRequestID else { return false }
            failedReplies.append(frame)
            return true
        }
        if reject { throw DesktopControlGatewayConnectionError.socketUnavailable }
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
    try socket.push(.init(type: "ready", imessageProtocolVersion: 2))
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        iMessageRuntime: runtime) { _, _ in Issue.record("iMessage must not use the Desktop Control handler"); return .init(type: "failure") }
    try await connection.connect()
    #expect(await connection.heartbeatFrame().imessageProtocolVersion == 2)
    try socket.push(.init(type: "imessage", requestID: "snapshot-1", imessage: .snapshot(.init(installationID: "gateway-mac", revision: 1, setupScope: scope))))
    #expect(await socket.response("snapshot-1").imessage == .snapshotAck(.init(revision: 1)))
    try socket.push(.init(type: "imessage", requestID: "first", imessage: .command(gatewayRuntimeCommand("first"))))
    await provider.waitUntilHeld()
    try socket.push(.init(type: "heartbeat", lastHeartbeat: Date(), imessageProtocolVersion: 2))
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
    try socket.push(.init(type: "ready", imessageProtocolVersion: injected ? 3 : 2))
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
    try socket.push(.init(type: "ready", imessageProtocolVersion: 2))
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
        do { try socket.push(.init(type: "ready", imessageProtocolVersion: 2)) } catch { Issue.record("Cannot encode fixture ready") }
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

private func sessionReplacementSnapshot(_ intent: IMessageRuntimeSetupIntent, revision: Int64, id: String, socket: IMessageRuntimeSocket, bounded: Bool = false) async throws -> DesktopControlFrame {
    try socket.push(.init(type: "imessage", requestID: id,
        imessage: .snapshot(.init(installationID: "gateway-mac", revision: revision, setupScope: intent.scope))))
    if bounded { return try await boundedReplyFailureResponse(socket, requestID: id) }
    return await socket.response(id)
}

private func sessionReplacementMetadata(_ intent: IMessageRuntimeSetupIntent, revision: Int64, id: String, socket: IMessageRuntimeSocket, bounded: Bool = false) async throws -> DesktopControlFrame {
    let command = IMessageGatewayCommand(requestID: id, authorizationID: "grant-\(id)", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
        target: .init(installationID: "gateway-mac", workspaceID: "w", snapshotRevision: revision),
        caller: .init(setupSession: .init(userID: "u", setupReference: String(repeating: "A", count: 43), setupGeneration: intent.scope.generation)),
        input: .setupConversations(.init(limit: 10)))
    try socket.push(.init(type: "imessage", requestID: id, imessage: .command(command)))
    if bounded { return try await boundedReplyFailureResponse(socket, requestID: id) }
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


@Test func iMessageGatewayUnsupportedConfiguredSendReturnsExactSafeFailureWithoutProvider() async throws {
    let socket = IMessageRuntimeSocket()
    try socket.push(.init(type: "ready", imessageProtocolVersion: 1))
    let provider = IMessageGatewayProviderFixture()
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider, referenceDigest: { _ in "unused" })
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        iMessageRuntime: runtime) { _, _ in Issue.record("Configured send reached Desktop Control"); return .init(type: "failure") }
    try await connection.connect()
    let command = IMessageGatewayCommand(requestID: "configured-send", authorizationID: "grant", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(45)),
        target: .init(installationID: "gateway-mac", workspaceID: "workspace", snapshotRevision: 3, configID: "config", configVersion: 2, accountGeneration: "account", sourceGeneration: "source"),
        caller: .init(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1)),
        input: .configured(.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "exact-key", text: "hello"))), sendAttemptID: "attempt")
    try socket.push(.init(type: "imessage", requestID: command.requestID, imessage: .command(command)))
    let response = await socket.response(command.requestID)
    try IMessageGatewayWire.validateResult(response, for: command)
    guard case .failure(let failure)? = response.imessage else { Issue.record("Unsupported send executed"); return }
    #expect(failure.clientRequestID == "exact-key" && failure.retrySafe && failure.code == .capabilityDisabled)
    #expect(await provider.calls == 0)
    #expect(await connection.isConnected())
    await connection.stopAndDrainIMessage()
}


private actor IMessageHeldLifecycleAuthorization: AgentBridgeHostedTransport {
    private let response: Data
    private var reply: CheckedContinuation<(Data, Int), any Error>?
    private var entry: CheckedContinuation<Void, Never>?
    private var entered = false
    private var cancellationEntry: CheckedContinuation<Void, Never>?
    private let holdCancellation: Bool
    private(set) var wasCancelled = false
    init(snapshot: IMessageGatewaySnapshot, holdCancellation: Bool = false) throws {
        self.holdCancellation = holdCancellation
        response = try JSONEncoder().encode(IMessageGatewayNativeAuthorizationResponse(authorized: true, snapshot: snapshot))
    }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        #expect(request.url?.path == "/v1/desktop-control/imessage/commands/authorize")
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                reply = $0; entered = true; entry?.resume(); entry = nil
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func waitForCancellation() async { if !wasCancelled { await withCheckedContinuation { cancellationEntry = $0 } } }
    private func cancel() {
        wasCancelled = true; cancellationEntry?.resume(); cancellationEntry = nil
        if !holdCancellation { reply?.resume(throwing: CancellationError()); reply = nil }
    }
    func release() {
        if wasCancelled { reply?.resume(throwing: CancellationError()) }
        else { reply?.resume(returning: (response, 200)) }
        reply = nil
    }
}

@MainActor private struct IMessageLifecycleBindingFixture {
    let workspace = NotificationCenter()
    let snapshot = DesktopSessionSnapshotFixture(.locked)
    let state = IMessageSessionFactoryState()
    let runtime: DesktopControlRuntime
    let session: IMessageNativeSession
    let intent = sessionReplacementIntent(1)
    let authorization: IMessageHeldLifecycleAuthorization
    init(holdCancellation: Bool = false) async throws {
        let installation = try gatewayRuntimeInstallation()
        let scope = IMessageGatewayConfigScope(configID: "config", workspaceID: "w", configVersion: 2,
            accountGeneration: "account-generation", sourceGeneration: "source", accountID: "account", conversationIDs: ["chat"],
            conversationBindings: [.init(conversationID: "chat", nativeChatID: try IMessageRowID(1), nativeChatGUID: "selected-guid")],
            readEnabled: true, sendEnabled: true)
        let grant = IMessageGatewaySnapshot(installationID: installation.installationID, revision: 3, configs: [scope])
        authorization = try IMessageHeldLifecycleAuthorization(snapshot: grant, holdCancellation: holdCancellation)
        let preferences = try #require(UserDefaults(suiteName: "IMessageLifecycleBinding-\(UUID().uuidString)"))
        preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(.production))
        let snapshot = snapshot
        let monitor = DesktopControlSessionLock(workspaceCenter: workspace, activationCenter: NotificationCenter(),
            observeNetwork: false, snapshotReader: { snapshot.value })
        let state = state
        runtime = DesktopControlRuntime.makeForTesting(installer: IMessageSessionInstaller(),
            credentials: IMessageSessionCredentials(installation: installation), iMessageProviderFactory: { state.provider() },
            gatewaySocketFactory: { state.socket() }, iMessageAuthorizationClient: .init(transport: authorization), paused: true,
            sessionLockState: .locked, sessionMonitor: monitor, scheduleReconnect: false, preferences: preferences)
        session = try await runtime.iMessageSetupSession()
        try await session.runtime.activateLocalSetup(intent)
        try await session.runtime.setMetadataConsent(true, for: intent)
        await runtime.connect(installation: installation)
        let socket = try #require(state.sockets.first)
        try socket.push(.init(type: "imessage", requestID: "configured-snapshot", imessage: .snapshot(grant)))
        #expect(await socket.response("configured-snapshot").imessage == .snapshotAck(.init(revision: 3)))
        let command = IMessageGatewayCommand(requestID: "held-configured", authorizationID: "grant", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
            target: .init(installationID: installation.installationID, workspaceID: "w", snapshotRevision: 3, configID: "config", configVersion: 2,
                accountGeneration: "account-generation", sourceGeneration: "source"),
            caller: .init(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1)), input: .configured(.status(.init(integrationID: "config"))))
        try socket.push(.init(type: "imessage", requestID: command.requestID, imessage: .command(command)))
        await authorization.waitUntilEntered()
    }
    func assertRetiredAndCleanUp() async throws {
        await runtime.waitForSessionLockChangeForTesting()
        #expect(!runtime.gatewayConnected)
        #expect(await authorization.wasCancelled)
        await #expect(throws: IMessageSetupProviderError.accountChanged) { try await session.runtime.setMetadataConsent(true, for: intent) }
        // Release the strict fake even when old production failed to cancel it.
        await authorization.release()
        await runtime.shutdownForQuit()
        for provider in state.providers { #expect(await provider.launches == 0) }
    }
}

@Test(arguments: ["sleep", "login"]) @MainActor
func iMessageLifecycleLossCannotBeErasedByImmediateRecovery(loss: String) async throws {
    let fixture = try await IMessageLifecycleBindingFixture()
    #expect(fixture.runtime.gatewayConnected)
    let lost = loss == "sleep" ? NSWorkspace.willSleepNotification : NSWorkspace.sessionDidResignActiveNotification
    let recovered = loss == "sleep" ? NSWorkspace.didWakeNotification : NSWorkspace.sessionDidBecomeActiveNotification
    // No actor yield between events. Cleanup must retain the observed loss.
    fixture.workspace.post(name: lost, object: nil)
    fixture.workspace.post(name: recovered, object: nil)
    try await fixture.assertRetiredAndCleanUp()
}

@Test @MainActor func iMessageReconciledInactiveLoginRetiresLockedPhysicalBinding() async throws {
    let fixture = try await IMessageLifecycleBindingFixture()
    #expect(fixture.runtime.gatewayConnected)
    fixture.snapshot.value = .inactive
    _ = await fixture.runtime.heartbeatReadinessForTesting()
    try await fixture.assertRetiredAndCleanUp()
}


@MainActor private final class IMessageLifecycleFactoryAttempt {
    private var entry: CheckedContinuation<Void, Never>?
    private var started = false
    var finished = false
    func begin() { started = true; entry?.resume(); entry = nil }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { entry = $0 } } }
}

@Test @MainActor func iMessageRecoveryAndFreshFactoryJoinCapturedLossBeforeReusingProvider() async throws {
    let fixture = try await IMessageLifecycleBindingFixture(holdCancellation: true)
    fixture.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    #expect(!fixture.runtime.gatewayConnected)
    fixture.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    await fixture.authorization.waitForCancellation()
    let probe = IMessageLifecycleFactoryAttempt()
    let factory = Task {
        probe.begin()
        defer { probe.finished = true }
        return try await fixture.runtime.iMessageSetupSession()
    }
    await probe.waitUntilStarted()
    for _ in 0..<100 { await Task.yield() }
    #expect(!probe.finished)
    #expect(fixture.state.sockets.count == 1)
    await fixture.authorization.release()
    await fixture.runtime.waitForSessionLockChangeForTesting()
    let current = try await factory.value
    #expect(current.runtime === fixture.session.runtime)
    await #expect(throws: IMessageSetupProviderError.accountChanged) { try await current.runtime.setMetadataConsent(true, for: fixture.intent) }
    for provider in fixture.state.providers { #expect(await provider.launches == 0) }
    let newIntent = sessionReplacementIntent(2)
    try await current.runtime.activateLocalSetup(newIntent)
    try await current.runtime.setMetadataConsent(true, for: newIntent)
    _ = try await fixture.runtime.resumeIMessageSetupRelay(for: newIntent)
    #expect(fixture.state.sockets.count == 2)
    let socket = try #require(fixture.state.sockets.last)
    #expect(try await sessionReplacementSnapshot(newIntent, revision: 4, id: "fresh-after-loss", socket: socket).imessage == .snapshotAck(.init(revision: 4)))
    let response = try await sessionReplacementMetadata(newIntent, revision: 4, id: "new-local-consent", socket: socket)
    guard case .result(.conversationsPage)? = response.imessage else { Issue.record("Fresh setup could not recover after joined loss"); return }
    await fixture.runtime.shutdownForQuit()
}


private actor IMessageReplyFailureEvents {
    private(set) var disconnects = 0
    private(set) var drains = 0
    private(set) var repliesCompleted = 0
    func replied() { repliesCompleted += 1 }
    func disconnected() { disconnects += 1 }
    func drained() { drains += 1 }
}

private actor IMessageReplyFailureProvider: IMessageSetupProviding {
    let failSend: Bool
    private(set) var operations: [String] = []
    private var nextStopGate: ConfiguredRuntimeGate?
    func holdNextStop(_ gate: ConfiguredRuntimeGate) { nextStopGate = gate }
    init(failSend: Bool) { self.failSend = failSend }
    func prerequisites(deadline: Date) -> IMessageGatewayPrerequisitesResult {
        operations.append("prerequisites")
        return .init(databaseReady: true)
    }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int, deadline: Date) throws -> IMessageSetupProviderPage {
        Issue.record("Unexpected setup inventory"); throw IMessageSetupProviderError.dependencyInvalid
    }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification {
        Issue.record("Unexpected setup verification"); throw IMessageSetupProviderError.dependencyInvalid
    }
    func executeConfigured(_ input: IMessageGatewayConfiguredInput, scope: IMessageGatewayConfigScope, deadline: Date,
                           validateCurrent: @escaping @Sendable () async throws -> Bool) async throws -> IMessageGatewayConfiguredResult {
        #expect(try await validateCurrent())
        operations.append(input.operationRawValue)
        switch input {
        case .status: return .status(.init(state: .connected))
        case .sendMessage(let request):
            if failSend { throw IMessageSetupProviderError.busy }
            return .sendMessage(.init(conversationID: request.conversationID, clientRequestID: request.clientRequestID,
                messageID: "one-confirmed-message", confirmedAt: ISO8601DateFormatter().string(from: Date())))
        default: Issue.record("Unexpected configured operation"); throw IMessageSetupProviderError.dependencyInvalid
        }
    }
    func stop() async {
        let gate = nextStopGate
        nextStopGate = nil
        await gate?.pause()
    }
}

private func waitForReplyFailureEvent(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
}

private func boundedReplyFailureResponse(_ socket: IMessageRuntimeSocket, requestID: String) async throws -> DesktopControlFrame {
    let found = await waitForReplyFailureEvent { socket.recordedResponse(requestID) != nil }
    #expect(found, "Missing bounded reply at recovery stage: \(requestID)")
    let frame = socket.recordedResponse(requestID)
    return try #require(frame, "Recovery stage timed out: \(requestID)")
}

@Test(arguments: ["read-result", "send-result", "send-failure"])
func iMessageReplyTransportFailureDrainsAndAllowsFreshBindingWithoutReplay(mode: String) async throws {
    let provider = IMessageReplyFailureProvider(failSend: mode == "send-failure")
    let events = IMessageReplyFailureEvents()
    let scope = try configuredFixtureScope()
    let snapshot = IMessageGatewaySnapshot(installationID: "gateway-mac", revision: 3, configs: [scope])
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider,
        referenceDigest: { IMessageSetupProvider.setupReferenceDigest($0) }, authorizeConfigured: { command, _, _ in
            #expect(command.target.snapshotRevision == 3)
            return snapshot
        })
    await runtime.setConfiguredPolicy(enabled: true)
    let socket = IMessageRuntimeSocket()
    try socket.push(.init(type: "ready", imessageProtocolVersion: 2))
    let connection = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: socket,
        onDisconnect: { _ in await events.disconnected() }, iMessageRuntime: runtime) { _, _ in
            Issue.record("Messages reply failure must not execute Desktop Control"); return .init(type: "failure")
        }
    try await connection.connect()
    try socket.push(.init(type: "imessage", requestID: "scope", imessage: .snapshot(snapshot)))
    #expect(try await boundedReplyFailureResponse(socket, requestID: "scope").imessage == .snapshotAck(.init(revision: 3)))
    let input: IMessageGatewayConfiguredInput = mode == "read-result" ? .status(.init(integrationID: "config"))
        : .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "never-replay", text: "hello"))
    let command = IMessageGatewayCommand(requestID: "failed-reply", authorizationID: "original-grant",
        deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(mode == "read-result" ? 10 : 45)),
        target: .init(installationID: "gateway-mac", workspaceID: "workspace", snapshotRevision: 3, configID: "config",
            configVersion: 2, accountGeneration: "account", sourceGeneration: "source"),
        caller: .init(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1)),
        input: .configured(input), sendAttemptID: mode == "read-result" ? nil : "one-attempt")
    socket.failReply(for: command.requestID)
    try socket.push(.init(type: "imessage", requestID: command.requestID, imessage: .command(command)))
    let disconnected = await waitForReplyFailureEvent { await events.disconnects == 1 }
    #expect(disconnected, "Reply send failure must finish joined cleanup and notify disconnection")
    #expect(socket.rejectedReplies().count == 1)
    let rejected = try #require(socket.rejectedReplies().first)
    if mode == "send-failure" {
        guard case .failure(let value)? = rejected.imessage else { Issue.record("Missing uncertain send failure"); return }
        #expect(value.code == .outcomeUnknown && !value.retrySafe && value.clientRequestID == "never-replay")
    } else {
        guard case .result? = rejected.imessage else { Issue.record("Missing completed provider result"); return }
    }
    // Old production has an irreducible in-memory Task.value cycle. Bound RED
    // observation instead of joining that cycle and hanging the test binary.
    guard disconnected else { return }
    let drain = Task { await connection.stopAndDrainIMessage(); await events.drained() }
    let drained = await waitForReplyFailureEvent { await events.drains == 1 }
    #expect(drained)
    guard drained else { drain.cancel(); return }
    await drain.value
    #expect(!(await connection.isConnected()))
    #expect(await events.disconnects == 1)
    let freshSocket = IMessageRuntimeSocket()
    try freshSocket.push(.init(type: "ready", imessageProtocolVersion: 2))
    let fresh = DesktopControlGatewayConnection(installation: try gatewayRuntimeInstallation(), socket: freshSocket,
        iMessageRuntime: runtime) { _, _ in Issue.record("Unexpected Desktop Control recovery"); return .init(type: "failure") }
    try await fresh.connect()
    try freshSocket.push(.init(type: "imessage", requestID: command.requestID, imessage: .command(command)))
    guard case .failure(let stale)? = try await boundedReplyFailureResponse(freshSocket, requestID: command.requestID).imessage else { Issue.record("Old grant survived reconnect"); return }
    #expect(stale.code == .scopeDenied)
    let intent = sessionReplacementIntent(2)
    try await runtime.activateLocalSetup(intent)
    #expect(try await sessionReplacementSnapshot(intent, revision: 4, id: "fresh-setup", socket: freshSocket, bounded: true).imessage == .snapshotAck(.init(revision: 4)))
    let denied = try await sessionReplacementMetadata(intent, revision: 4, id: "no-new-consent", socket: freshSocket, bounded: true)
    guard case .failure(let consent)? = denied.imessage else { Issue.record("Recovery manufactured metadata consent"); return }
    #expect(consent.code == .scopeDenied)
    try await runtime.setMetadataConsent(true, for: intent)
    // The current setup generation must match the newly confirmed intent.
    let freshCommand = IMessageGatewayCommand(requestID: "current-prerequisites", authorizationID: "fresh-grant",
        deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
        target: .init(installationID: "gateway-mac", workspaceID: "w", snapshotRevision: 4),
        caller: .init(setupSession: .init(userID: "u", setupReference: String(repeating: "A", count: 43), setupGeneration: 2)), input: .prerequisites)
    try freshSocket.push(.init(type: "imessage", requestID: freshCommand.requestID, imessage: .command(freshCommand)))
    guard case .result(.prerequisites)? = try await boundedReplyFailureResponse(freshSocket, requestID: freshCommand.requestID).imessage else { Issue.record("Fresh consent and grant could not recover"); return }
    #expect(await provider.operations == [input.operationRawValue, "prerequisites"])
    await fresh.stopAndDrainIMessage()
    await runtime.drain()
}


@Test func iMessageReplyPhaseRetainsAdmissionSlotAndJoinsOwnedProviderCleanup() async throws {
    let provider = IMessageReplyFailureProvider(failSend: false)
    let events = IMessageReplyFailureEvents()
    let replyGate = ConfiguredRuntimeGate(), stopGate = ConfiguredRuntimeGate()
    let snapshot = IMessageGatewaySnapshot(installationID: "gateway-mac", revision: 3, configs: [try configuredFixtureScope()])
    let runtime = IMessageRuntime(installationID: "gateway-mac", provider: provider, referenceDigest: { _ in "unused" },
        authorizeConfigured: { _, _, _ in snapshot })
    let connectionID = UUID()
    await runtime.bind(connectionID: connectionID)
    await runtime.setConfiguredPolicy(enabled: true)
    #expect(await runtime.install(snapshot, connectionID: connectionID) == .snapshotAck(.init(revision: 3)))
    func command(_ id: String, send: Bool = false) -> IMessageGatewayCommand {
        .init(requestID: id, authorizationID: "grant-\(id)",
            deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(send ? 45 : 10)),
            target: .init(installationID: "gateway-mac", workspaceID: "workspace", snapshotRevision: 3, configID: "config",
                configVersion: 2, accountGeneration: "account", sourceGeneration: "source"),
            caller: .init(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1)),
            input: .configured(send ? .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "one-key", text: "hello"))
                : .status(.init(integrationID: "config"))), sendAttemptID: send ? "one-attempt" : nil)
    }
    let firstAdmission = await runtime.admit(command("active", send: true), connectionID: connectionID) { _ in
        await replyGate.pause()
        await events.replied()
    }
    #expect(firstAdmission == nil)
    await replyGate.wait()
    #expect(await provider.operations == ["imessage_send_message"])
    let duplicate = await runtime.admit(command("same-attempt", send: true), connectionID: connectionID) { _ in Issue.record("Duplicate attempt executed") }
    #expect(duplicate?.code == .requestInProgress && duplicate?.retrySafe == false)
    for index in 0..<IMessageRuntime.maximumWaitingCommands {
        let admission = await runtime.admit(command("waiting-\(index)"), connectionID: connectionID) { payload in
            guard case .failure(let value) = payload else { Issue.record("Queued read ran during held reply"); return }
            #expect(value.code == .scopeDenied)
        }
        #expect(admission == nil)
    }
    let overflow = await runtime.admit(command("overflow"), connectionID: connectionID) { _ in Issue.record("Overflow executed") }
    #expect(overflow?.code == .busy)
    await provider.holdNextStop(stopGate)
    let drain = Task { await runtime.suspendAndDrain(); await events.drained() }
    await stopGate.wait()
    #expect(await events.drains == 0)
    #expect(await events.repliesCompleted == 0)
    await stopGate.release()
    let drained = await waitForReplyFailureEvent { await events.drains == 1 }
    #expect(drained, "Provider cleanup must join without waiting for an already completed provider's reply callback")
    await replyGate.release()
    let completed = await waitForReplyFailureEvent { await events.repliesCompleted == 1 }
    #expect(completed)
    guard drained && completed else { drain.cancel(); return }
    await drain.value
    #expect(await provider.operations == ["imessage_send_message"])
    await runtime.drain()
}
