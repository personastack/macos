import Foundation
import PersonaStackCore

typealias DesktopControlCommandHandler = @Sendable (DesktopControlFrame, @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame
typealias DesktopControlDisconnectHandler = @Sendable () async -> Void

enum DesktopControlGatewayConnectionError: Error, Equatable {
    case alreadyConnected
    case invalidURL
    case rejected
    case invalidFrame
    case socketUnavailable
}

actor DesktopControlGatewayConnection {
    private let installation: DesktopControlInstallation
    private let handler: DesktopControlCommandHandler
    private let onDisconnect: DesktopControlDisconnectHandler
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeats: Task<Void, Never>?
    private var connected = false
    private var readiness = "ready"

    init(installation: DesktopControlInstallation,
         session: URLSession = .shared,
         onDisconnect: @escaping DesktopControlDisconnectHandler = {},
         handler: @escaping DesktopControlCommandHandler) {
        self.installation = installation
        self.session = session
        self.onDisconnect = onDisconnect
        self.handler = handler
    }

    func connect() async throws {
        guard !connected, socket == nil else { throw DesktopControlGatewayConnectionError.alreadyConnected }
        var request = URLRequest(url: installation.gatewayWebsocketURL, timeoutInterval: 15)
        request.setValue(installation.installationID, forHTTPHeaderField: "X-Desktop-Control-Installation-ID")
        request.setValue("Bearer \(installation.machineCredential)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        do {
            let first = try await task.receive()
            let ready = try DesktopControlFrameCodec.decode(Self.data(from: first))
            guard ready.version == 1, ready.type == "ready" else { throw DesktopControlGatewayConnectionError.rejected }
            connected = true
            reader = Task { await receiveLoop() }
            heartbeats = Task { await heartbeatLoop() }
        } catch {
            stop()
            throw error
        }
    }

    func isConnected() -> Bool { connected }

    func setReadiness(_ value: String) async {
        guard value == "ready" || value == "paused" else { return }
        readiness = value
        guard connected else { return }
        do {
            try await send(DesktopControlFrame(type: "heartbeat", lastHeartbeat: Date(), readiness: value))
        } catch {
            await disconnected()
        }
    }

    func stop() {
        reader?.cancel()
        heartbeats?.cancel()
        reader = nil
        heartbeats = nil
        connected = false
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receiveLoop() async {
        while !Task.isCancelled, connected {
            do {
                guard let socket else { throw DesktopControlGatewayConnectionError.socketUnavailable }
                let message = try await socket.receive()
                let frame = try DesktopControlFrameCodec.decode(Self.data(from: message))
                guard frame.version == 1 else { throw DesktopControlGatewayConnectionError.invalidFrame }
                switch frame.type {
                case "heartbeat":
                    continue
                case "command":
                    guard Self.validCommand(frame, installationID: installation.installationID) else {
                        throw DesktopControlGatewayConnectionError.invalidFrame
                    }
                    let response = await handler(frame) { [weak self] chunk in
                        guard let self,
                              chunk.type == "result_chunk",
                              chunk.requestID == frame.requestID else {
                            throw DesktopControlGatewayConnectionError.invalidFrame
                        }
                        try await self.send(chunk)
                    }
                    guard let requestID = frame.requestID,
                          response.requestID == requestID,
                          response.type == "result" || response.type == "failure" else {
                        throw DesktopControlGatewayConnectionError.invalidFrame
                    }
                    try await send(response)
                default:
                    throw DesktopControlGatewayConnectionError.invalidFrame
                }
            } catch {
                await disconnected()
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled, connected {
            do {
                try await Task.sleep(for: .seconds(15))
                try await send(DesktopControlFrame(type: "heartbeat", lastHeartbeat: Date(), readiness: readiness))
            } catch {
                await disconnected()
                return
            }
        }
    }

    private func send(_ frame: DesktopControlFrame) async throws {
        guard let socket, connected else { throw DesktopControlGatewayConnectionError.socketUnavailable }
        let data = try DesktopControlFrameCodec.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else { throw DesktopControlGatewayConnectionError.invalidFrame }
        try await socket.send(.string(text))
    }

    private func disconnected() async {
        guard connected else { return }
        stop()
        await onDisconnect()
    }

    private static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data): data
        case .string(let text): Data(text.utf8)
        @unknown default: throw DesktopControlGatewayConnectionError.invalidFrame
        }
    }

    private static func validCommand(_ frame: DesktopControlFrame, installationID: String) -> Bool {
        guard let target = frame.target, let requestID = frame.requestID, !requestID.isEmpty,
              target.installationID == installationID,
              !target.workspaceID.isEmpty, !target.configID.isEmpty, !target.personaID.isEmpty,
              !target.runID.isEmpty, target.generation > 0,
              frame.operation != nil, frame.arguments != nil,
              let deadline = frame.deadlineAt, deadline > Date() else { return false }
        return true
    }
}
