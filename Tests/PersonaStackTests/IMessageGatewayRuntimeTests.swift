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
    func prerequisites(deadline: Date) async throws -> IMessageGatewayPrerequisitesResult {
        calls += 1
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
    func stop() { pending?.resume(throwing: CancellationError()); pending = nil }
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
