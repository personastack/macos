import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private enum StabilitySocketError: Error { case closed }

private final class StabilitySocket: DesktopControlSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [URLSessionWebSocketTask.Message] = []
    private var receivers: [CheckedContinuation<URLSessionWebSocketTask.Message, any Error>] = []
    private var blockedSenders: [CheckedContinuation<Void, any Error>] = []
    private var receiveWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var sendWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var received = 0
    private var sent: [DesktopControlFrame] = []
    private var cancelled = false
    private var cancellations = 0
    let holdCancelledReceive: Bool
    let blockSends: Bool

    init(holdCancelledReceive: Bool = false, blockSends: Bool = false) {
        self.holdCancelledReceive = holdCancelledReceive
        self.blockSends = blockSends
    }

    var cancelCount: Int { lock.withLock { cancellations } }
    var sentFrames: [DesktopControlFrame] { lock.withLock { sent } }
    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        cancellations += 1
        let reads = holdCancelledReceive ? [] : receivers
        if !holdCancelledReceive { receivers.removeAll() }
        let writes = blockedSenders
        blockedSenders.removeAll()
        lock.unlock()
        for read in reads { read.resume(throwing: StabilitySocketError.closed) }
        for write in writes { write.resume(throwing: StabilitySocketError.closed) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            received += 1
            let ready = receiveWaiters.filter { $0.0 <= received }
            receiveWaiters.removeAll { $0.0 <= received }
            let message = queued.isEmpty ? nil : queued.removeFirst()
            let closed = cancelled && !holdCancelledReceive
            if message == nil && !closed { receivers.append(continuation) }
            lock.unlock()
            for (_, waiter) in ready { waiter.resume() }
            if let message { continuation.resume(returning: message) }
            else if closed { continuation.resume(throwing: StabilitySocketError.closed) }
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw StabilitySocketError.closed
        }
        let frame = try DesktopControlFrameCodec.decode(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            sent.append(frame)
            let ready = sendWaiters.filter { $0.0 <= sent.count }
            sendWaiters.removeAll { $0.0 <= sent.count }
            let closed = cancelled
            if blockSends && !closed { blockedSenders.append(continuation) }
            lock.unlock()
            for (_, waiter) in ready { waiter.resume() }
            if closed { continuation.resume(throwing: StabilitySocketError.closed) }
            else if !blockSends { continuation.resume() }
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) { pongReceiveHandler(nil) }

    func push(_ frame: DesktopControlFrame) throws {
        let message = URLSessionWebSocketTask.Message.data(try DesktopControlFrameCodec.encode(frame))
        lock.lock()
        let receiver = receivers.isEmpty ? nil : receivers.removeFirst()
        if receiver == nil { queued.append(message) }
        lock.unlock()
        receiver?.resume(returning: message)
    }

    func waitForReceiveCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let ready = received >= count
            if !ready { receiveWaiters.append((count, continuation)) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }

    func waitForSendCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let ready = sent.count >= count
            if !ready { sendWaiters.append((count, continuation)) }
            lock.unlock()
            if ready { continuation.resume() }
        }
    }
}

private final class StabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
}

private actor StabilityCalls {
    private(set) var disconnects = 0
    private(set) var commands = 0
    func disconnected() { disconnects += 1 }
    func command() { commands += 1 }
}

private func stabilityInstallation() throws -> DesktopControlInstallation {
    let profile = DesktopEnvironmentConfiguration.production
    return try JSONDecoder().decode(DesktopControlInstallation.self, from: JSONSerialization.data(withJSONObject: [
        "installation_id": "fixture", "machine_credential": String(repeating: "A", count: 43),
        "gateway_websocket_url": profile.gatewayWebsocketURL.absoluteString, "environment_origin": profile.appOrigin,
    ]))
}

@Suite struct DesktopControlGatewayStabilityTests {
    @Test func silentHandshakeExpiresWithoutStartingCommands() async throws {
        let socket = StabilitySocket()
        let calls = StabilityCalls()
        let connection = DesktopControlGatewayConnection(installation: try stabilityInstallation(), socket: socket,
            handshakeTimeout: .milliseconds(1)) { frame, _ in
                await calls.command()
                return frame
            }
        await #expect(throws: DesktopControlGatewayConnectionError.socketUnavailable) { try await connection.connect() }
        #expect(!(await connection.isConnected()))
        #expect(socket.cancelCount > 0)
        #expect(await calls.commands == 0)
        await connection.stop()
    }

    @Test func stopDuringHandshakeRejectsBufferedLateReady() async throws {
        let socket = StabilitySocket(holdCancelledReceive: true)
        let connection = DesktopControlGatewayConnection(installation: try stabilityInstallation(), socket: socket) { _, _ in
            Issue.record("Stopped handshake must never admit commands")
            return DesktopControlFrame(type: "failure")
        }
        let connecting = Task { try await connection.connect() }
        await socket.waitForReceiveCount(1)
        await connection.stop()
        try socket.push(DesktopControlFrame(type: "ready"))
        await #expect(throws: DesktopControlGatewayConnectionError.socketUnavailable) { try await connecting.value }
        #expect(!(await connection.isConnected()))
    }

    @Test func expiredCommandReturnsFailureAndKeepsConnection() async throws {
        let socket = StabilitySocket()
        let calls = StabilityCalls()
        try socket.push(DesktopControlFrame(type: "ready"))
        let connection = DesktopControlGatewayConnection(installation: try stabilityInstallation(), socket: socket) { frame, _ in
            await calls.command()
            #expect(frame.deadlineAt == Date(timeIntervalSince1970: 1))
            return DesktopControlFrame(type: "failure", requestID: frame.requestID, errorCode: "desktop_command_expired")
        }
        try await connection.connect()
        let target = DesktopControlTarget(installationID: "fixture", workspaceID: "w", configID: "c", personaID: "p", runID: "r", generation: 1)
        try socket.push(DesktopControlFrame(type: "command", requestID: "expired", target: target,
            operation: "desktop_control_acquire", arguments: .object([:]), deadlineAt: Date(timeIntervalSince1970: 1)))
        await socket.waitForSendCount(1)
        #expect(socket.sentFrames.first?.errorCode == "desktop_command_expired")
        #expect(await calls.commands == 1)
        #expect(await connection.isConnected())
        #expect(socket.cancelCount == 0)
        await connection.stop()
    }

    @Test(arguments: [false, true]) func missingHeartbeatAcknowledgementClosesEvenWithBlockedWrite(blocked: Bool) async throws {
        let socket = StabilitySocket(blockSends: blocked)
        let clock = StabilityClock()
        let calls = StabilityCalls()
        try socket.push(DesktopControlFrame(type: "ready"))
        let connection = DesktopControlGatewayConnection(installation: try stabilityInstallation(), socket: socket,
            now: { clock.now() }, onDisconnect: { _ in await calls.disconnected() }) { _, _ in
                Issue.record("Liveness checks must not execute commands")
                return DesktopControlFrame(type: "failure")
            }
        try await connection.connect()
        await connection.heartbeatTickForTesting()
        await socket.waitForSendCount(1)
        clock.advance(.seconds(45))
        await connection.heartbeatTickForTesting()
        #expect(!(await connection.isConnected()))
        #expect(await calls.disconnects == 1)
        #expect(socket.cancelCount == 1)
    }

    @Test func heartbeatAcknowledgementExtendsConnectionLiveness() async throws {
        let socket = StabilitySocket()
        let clock = StabilityClock()
        try socket.push(DesktopControlFrame(type: "ready"))
        let connection = DesktopControlGatewayConnection(installation: try stabilityInstallation(), socket: socket,
            now: { clock.now() }) { _, _ in DesktopControlFrame(type: "failure") }
        try await connection.connect()
        await socket.waitForReceiveCount(2)
        clock.advance(.seconds(30))
        try socket.push(DesktopControlFrame(type: "heartbeat", lastHeartbeat: Date()))
        await socket.waitForReceiveCount(3)
        clock.advance(.seconds(30))
        await connection.heartbeatTickForTesting()
        await socket.waitForSendCount(1)
        #expect(await connection.isConnected())
        await connection.stop()
    }
}
