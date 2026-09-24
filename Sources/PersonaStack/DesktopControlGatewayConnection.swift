import Foundation
import PersonaStackCore

typealias DesktopControlCommandHandler = @Sendable (DesktopControlFrame, @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame
typealias DesktopControlDisconnectHandler = @Sendable (DesktopControlGatewayConnectionError?) async -> Void
typealias DesktopControlDiagnosticsProvider = @Sendable () async -> DesktopControlDiagnostics

enum DesktopControlGatewayConnectionError: Error, Equatable {
    case alreadyConnected
    case invalidURL
    case rejected
    case upgradeRequired
    case invalidFrame
    case socketUnavailable
}

actor DesktopControlGatewayConnection {
    private static let maximumInFlightCommands = 32
    private static let reservedRevocationCommands = 1

    private let installation: DesktopControlInstallation
    private let handler: DesktopControlCommandHandler
    private let onDisconnect: DesktopControlDisconnectHandler
    private let diagnosticsProvider: DesktopControlDiagnosticsProvider
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeats: Task<Void, Never>?
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var connected = false
    private var readiness = "ready"
    private var diagnosticsSupported = false

    init(installation: DesktopControlInstallation,
         session: URLSession = .shared,
         onDisconnect: @escaping DesktopControlDisconnectHandler = { _ in },
         diagnosticsProvider: @escaping DesktopControlDiagnosticsProvider = { DesktopControlDiagnostics(activeProcesses: 0, openFileHandles: 0, bufferedOutputBytes: 0, outputGapsTotal: 0) },
         handler: @escaping DesktopControlCommandHandler) {
        self.installation = installation
        self.session = session
        self.onDisconnect = onDisconnect
        self.diagnosticsProvider = diagnosticsProvider
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
            if let error = Self.handshakeError(for: ready) { throw error }
            diagnosticsSupported = ready.diagnosticsSupported == true
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
        guard ["unknown", "ready", "permission_required", "cua_unavailable", "paused", "locked", "upgrade_required"].contains(value) else { return }
        readiness = value
        guard connected else { return }
        do {
            try await send(await heartbeatFrame())
        } catch {
            await disconnected()
        }
    }

    func stop() {
        reader?.cancel()
        heartbeats?.cancel()
        for task in commandTasks.values { task.cancel() }
        commandTasks.removeAll()
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
                if frame.version != 1 {
                    await disconnected(error: .upgradeRequired)
                    return
                }
                switch frame.type {
                case "heartbeat":
                    continue
                case "failure" where frame.errorCode == "upgrade_required":
                    await disconnected(error: .upgradeRequired)
                    return
                case "command":
                    guard Self.validCommand(frame, installationID: installation.installationID) else {
                        throw DesktopControlGatewayConnectionError.invalidFrame
                    }
                    guard let requestID = frame.requestID, commandTasks[requestID] == nil else {
                        throw DesktopControlGatewayConnectionError.invalidFrame
                    }
                    guard Self.hasCapacity(for: frame.operation, activeCount: commandTasks.count) else {
                        try await send(DesktopControlFrame(
                            type: "failure",
                            requestID: requestID,
                            errorCode: "desktop_command_capacity",
                            errorMessage: "The desktop is handling other commands. Retry after one finishes."
                        ))
                        continue
                    }
                    commandTasks[requestID] = Task { await processCommand(frame) }
                default:
                    throw DesktopControlGatewayConnectionError.invalidFrame
                }
            } catch {
                await disconnected(error: error as? DesktopControlGatewayConnectionError)
                return
            }
        }
    }

    private func processCommand(_ frame: DesktopControlFrame) async {
        guard let requestID = frame.requestID else { return }
        defer { commandTasks[requestID] = nil }
        let response = await handler(frame) { [weak self] chunk in
            try Task.checkCancellation()
            guard let self, chunk.type == "result_chunk", chunk.requestID == requestID else {
                throw DesktopControlGatewayConnectionError.invalidFrame
            }
            try await self.send(chunk)
        }
        guard !Task.isCancelled, connected,
              response.requestID == requestID,
              response.type == "result" || response.type == "failure" else { return }
        do { try await send(response) }
        catch { await disconnected() }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled, connected {
            do {
                try await Task.sleep(for: .seconds(15))
                try await send(await heartbeatFrame())
            } catch {
                await disconnected()
                return
            }
        }
    }

    private func heartbeatFrame() async -> DesktopControlFrame {
        let diagnostics = diagnosticsSupported ? await diagnosticsProvider() : nil
        return DesktopControlFrame(type: "heartbeat", lastHeartbeat: Date(), readiness: readiness,
                                   diagnostics: diagnostics)
    }

    private func send(_ frame: DesktopControlFrame) async throws {
        guard let socket, connected else { throw DesktopControlGatewayConnectionError.socketUnavailable }
        let data = try DesktopControlFrameCodec.encode(frame)
        guard let text = String(data: data, encoding: .utf8) else { throw DesktopControlGatewayConnectionError.invalidFrame }
        try await socket.send(.string(text))
    }

    private func disconnected(error: DesktopControlGatewayConnectionError? = nil) async {
        guard connected else { return }
        stop()
        await onDisconnect(error)
    }

    static func handshakeError(for frame: DesktopControlFrame) -> DesktopControlGatewayConnectionError? {
        if frame.type == "failure", frame.errorCode == "upgrade_required" { return .upgradeRequired }
        if frame.version != 1 { return .upgradeRequired }
        return frame.type == "ready" ? nil : .rejected
    }

    private static func data(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data): data
        case .string(let text): Data(text.utf8)
        @unknown default: throw DesktopControlGatewayConnectionError.invalidFrame
        }
    }

    static func validCommand(_ frame: DesktopControlFrame, installationID: String) -> Bool {
        guard let target = frame.target, let requestID = frame.requestID, !requestID.isEmpty,
              target.installationID == installationID,
              !target.workspaceID.isEmpty, !target.configID.isEmpty, frame.arguments != nil,
              let deadline = frame.deadlineAt, deadline > Date() else { return false }
        if frame.operation == "desktop_control_revoke_config" {
            return (target.configVersion ?? 0) > 0 && target.personaID.isEmpty && target.runID.isEmpty && target.generation == 0
        }
        guard !target.personaID.isEmpty, !target.runID.isEmpty, target.generation > 0,
              (target.configVersion ?? 0) >= 0 else { return false }
        guard frame.operation != nil else { return false }
        return true
    }

    static func hasCapacity(for operation: String?, activeCount: Int) -> Bool {
        guard activeCount >= 0, activeCount < maximumInFlightCommands else { return false }
        if operation == "desktop_control_revoke_config" { return true }
        return activeCount < maximumInFlightCommands - reservedRevocationCommands
    }
}
