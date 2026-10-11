import Foundation
import PersonaStackCore

typealias DesktopControlCommandHandler = @Sendable (DesktopControlFrame, @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame
typealias DesktopControlDisconnectHandler = @Sendable (DesktopControlGatewayConnectionError?) async -> Void
typealias DesktopControlDiagnosticsProvider = @Sendable () async -> DesktopControlDiagnostics
typealias DesktopControlReadinessProvider = @Sendable () async -> String?
typealias DesktopControlConfigRevocationHandler = @Sendable () async -> Void

enum DesktopControlGatewayConnectionError: Error, Equatable {
    case alreadyConnected
    case invalidURL
    case rejected
    case upgradeRequired
    case invalidFrame
    case socketUnavailable
}

protocol DesktopControlSocket: AnyObject, Sendable {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: DesktopControlSocket {}

actor DesktopControlGatewayConnection {
    private static let maximumInFlightCommands = 32
    private static let reservedRevocationCommands = 2

    private let installation: DesktopControlInstallation
    private let handler: DesktopControlCommandHandler
    private let onDisconnect: DesktopControlDisconnectHandler
    private let diagnosticsProvider: DesktopControlDiagnosticsProvider
    private let readinessProvider: DesktopControlReadinessProvider
    private let afterConfigRevocation: DesktopControlConfigRevocationHandler
    private let session: URLSession
    private let socketOverride: (any DesktopControlSocket)?
    private let handshakeTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var socket: (any DesktopControlSocket)?
    private var reader: Task<Void, Never>?
    private var heartbeats: Task<Void, Never>?
    private var heartbeatSendTask: Task<Void, Never>?
    private var lastGatewayHeartbeat: ContinuousClock.Instant?
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var connected = false
    private var readiness = "unknown"
    private var readinessRevision: UInt64 = 0
    private var cachedDiagnostics: DesktopControlDiagnostics?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotGeneration = UUID()
    private var diagnosticsSupported = false
    private var recoveryProbeID: UUID?
    private var recoveryProbeTimeout: Task<Void, Never>?
#if DEBUG
    var recoveryPingForTesting: (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?
    var recoveryTimeoutForTesting: Duration?
#endif

    init(installation: DesktopControlInstallation,
         session: URLSession? = nil,
         socket: (any DesktopControlSocket)? = nil,
         handshakeTimeout: Duration = .seconds(15),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         onDisconnect: @escaping DesktopControlDisconnectHandler = { _ in },
         diagnosticsProvider: @escaping DesktopControlDiagnosticsProvider = { DesktopControlDiagnostics(activeProcesses: 0, openFileHandles: 0, bufferedOutputBytes: 0, outputGapsTotal: 0) },
         readinessProvider: @escaping DesktopControlReadinessProvider = { nil },
         afterConfigRevocation: @escaping DesktopControlConfigRevocationHandler = {},
         handler: @escaping DesktopControlCommandHandler) {
        self.installation = installation
        self.session = session ?? DesktopControlNetworkSession.makeWithoutRedirects()
        self.socketOverride = socket
        self.handshakeTimeout = handshakeTimeout
        self.now = now
        self.onDisconnect = onDisconnect
        self.diagnosticsProvider = diagnosticsProvider
        self.readinessProvider = readinessProvider
        self.afterConfigRevocation = afterConfigRevocation
        self.handler = handler
    }

    func connect() async throws {
        guard !connected, socket == nil else { throw DesktopControlGatewayConnectionError.alreadyConnected }
        let task: any DesktopControlSocket
        if let socketOverride { task = socketOverride }
        else { task = try makeSocket() }
        socket = task
        task.resume()
        let timeout = handshakeTimeout
        let handshakeTimer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { handshakeTimer.cancel() }
        do {
            let first = try await task.receive()
            guard !Task.isCancelled, socket === task else {
                throw DesktopControlGatewayConnectionError.socketUnavailable
            }
            let ready = try DesktopControlFrameCodec.decode(Self.data(from: first))
            if let error = Self.handshakeError(for: ready) { throw error }
            diagnosticsSupported = ready.diagnosticsSupported == true
            connected = true
            lastGatewayHeartbeat = now()
            reader = Task { await receiveLoop() }
            heartbeats = Task { await heartbeatLoop() }
        } catch {
            if socket === task { stop() }
            throw (error as? DesktopControlGatewayConnectionError) ?? .socketUnavailable
        }
    }

    func makeSocket() throws -> URLSessionWebSocketTask {
        guard (try? installation.requireBoundGateway()) != nil else {
            throw DesktopControlGatewayConnectionError.invalidURL
        }
        var request = URLRequest(url: installation.gatewayWebsocketURL, timeoutInterval: 15)
        request.setValue(installation.installationID, forHTTPHeaderField: "X-Desktop-Control-Installation-ID")
        request.setValue("Bearer \(installation.machineCredential)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = DesktopControlFrameCodec.maximumFrameBytes
        return task
    }

    func isConnected() -> Bool { connected }

    func setReadiness(_ value: String) async {
        guard ["unknown", "ready", "permission_required", "cua_unavailable", "paused", "locked", "upgrade_required"].contains(value) else { return }
        readiness = value
        readinessRevision &+= 1
        guard connected else { return }
        do {
            try await send(heartbeatFrame())
        } catch {
            await disconnected()
        }
    }

    /// A wake can leave URLSession reporting connected for a dead TCP path.
    /// Probe once without interrupting a healthy lease. A bounded failure enters
    /// the ordinary disconnect/cleanup/reconnect path.
    func checkConnectionAfterRecovery() {
        guard connected, recoveryProbeID == nil else { return }
        let id = UUID()
        recoveryProbeID = id
        var timeout: Duration = .seconds(5)
#if DEBUG
        timeout = recoveryTimeoutForTesting ?? timeout
#endif
        recoveryProbeTimeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.finishRecoveryProbe(id: id, healthy: false)
        }
        let completion: @Sendable (Bool) -> Void = { [weak self] healthy in
            Task { await self?.finishRecoveryProbe(id: id, healthy: healthy) }
        }
#if DEBUG
        if let recoveryPingForTesting { recoveryPingForTesting(completion); return }
#endif
        guard let socket else { completion(false); return }
        socket.sendPing { completion($0 == nil) }
    }

    private func finishRecoveryProbe(id: UUID, healthy: Bool) async {
        guard recoveryProbeID == id, connected else { return }
        recoveryProbeID = nil
        recoveryProbeTimeout?.cancel()
        recoveryProbeTimeout = nil
        if healthy {
            // The normal heartbeat refresh publishes current CUA readiness.
            refreshSnapshot()
        } else {
            await disconnected(error: .socketUnavailable)
        }
    }

    func stop() {
        recoveryProbeID = nil
        recoveryProbeTimeout?.cancel()
        recoveryProbeTimeout = nil
        reader?.cancel()
        heartbeats?.cancel()
        heartbeatSendTask?.cancel()
        heartbeatSendTask = nil
        lastGatewayHeartbeat = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotGeneration = UUID()
        cachedDiagnostics = nil
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
                guard !Task.isCancelled, self.socket === socket else { return }
                let frame = try DesktopControlFrameCodec.decode(Self.data(from: message))
                if frame.version != 1 {
                    await disconnected(error: .upgradeRequired)
                    return
                }
                switch frame.type {
                case "heartbeat":
                    lastGatewayHeartbeat = now()
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
                guard !Task.isCancelled else { return }
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
        if Self.shouldReconcileAfterConfigRevocation(frame, response: response), connected {
            await afterConfigRevocation()
        }
    }

    static func shouldReconcileAfterConfigRevocation(_ frame: DesktopControlFrame,
                                                     response: DesktopControlFrame) -> Bool {
        guard frame.operation == "desktop_control_revoke_config",
              response.type == "result", response.errorCode == nil,
              case .object(let result)? = response.result else { return false }
        return result["revoked"] == .bool(true)
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled, connected {
            do {
                try await Task.sleep(for: .seconds(15))
                await heartbeatTick()
            } catch {
                guard !Task.isCancelled else { return }
                await disconnected()
                return
            }
        }
    }

    private func heartbeatTick() async {
        guard connected else { return }
        // Match the gateway's 45-second presence TTL. A successful local send
        // does not prove that a half-open TCP path reached the gateway.
        guard let lastGatewayHeartbeat, lastGatewayHeartbeat.duration(to: now()) < .seconds(45) else {
            await disconnected(error: .socketUnavailable)
            return
        }
        guard heartbeatSendTask == nil else { return }
        let generation = snapshotGeneration
        heartbeatSendTask = Task {
            defer { if generation == snapshotGeneration { heartbeatSendTask = nil } }
            do { try await send(heartbeatFrame()) }
            catch {
                guard !Task.isCancelled, generation == snapshotGeneration else { return }
                await disconnected()
            }
        }
    }

    // Sending presence must never wait behind a tool, filesystem read, or repair.
    // One bounded provider task refreshes these snapshots between heartbeats.
    func heartbeatFrame() -> DesktopControlFrame {
        refreshSnapshot()
        return cachedHeartbeatFrame()
    }

    private func cachedHeartbeatFrame() -> DesktopControlFrame {
        DesktopControlFrame(type: "heartbeat", lastHeartbeat: Date(), readiness: readiness,
                                   diagnostics: diagnosticsSupported ? cachedDiagnostics : nil)
    }

    private func refreshSnapshot() {
        guard snapshotTask == nil else { return }
        let generation = snapshotGeneration
        let revision = readinessRevision
        snapshotTask = Task { [weak self, readinessProvider, diagnosticsProvider] in
            let currentReadiness = await readinessProvider()
            guard !Task.isCancelled else { return }
            let diagnostics = await diagnosticsProvider()
            guard !Task.isCancelled, let self else { return }
            if let update = await self.applySnapshot(currentReadiness, diagnostics: diagnostics,
                                                     generation: generation, revision: revision) {
                await self.sendReadinessUpdate(update)
            }
        }
    }

    private func applySnapshot(_ currentReadiness: String?, diagnostics: DesktopControlDiagnostics,
                               generation: UUID, revision: UInt64) -> DesktopControlFrame? {
        guard generation == snapshotGeneration else { return nil }
        snapshotTask = nil
        cachedDiagnostics = diagnostics
        // An explicit lock/pause/readiness update wins over an older observation.
        if revision == readinessRevision, let currentReadiness,
           ["unknown", "ready", "permission_required", "cua_unavailable", "paused", "locked", "upgrade_required"].contains(currentReadiness) {
            guard readiness != currentReadiness else { return nil }
            readiness = currentReadiness
            // Do not wait for the next 15-second presence heartbeat, or start
            // another probe while publishing this probe's completed result.
            return cachedHeartbeatFrame()
        }
        return nil
    }

    private func sendReadinessUpdate(_ frame: DesktopControlFrame) async {
        guard connected, frame.readiness == readiness else { return }
        do { try await send(frame) }
        catch { await disconnected() }
    }

#if DEBUG
    func heartbeatTickForTesting() async { await heartbeatTick() }
    func configureRecoveryProbeForTesting(timeout: Duration = .seconds(5),
        ping: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) {
        connected = true
        recoveryTimeoutForTesting = timeout
        recoveryPingForTesting = ping
    }
    func hasRecoveryProbeForTesting() -> Bool { recoveryProbeID != nil }

    func applySnapshotForTesting(_ value: String) -> DesktopControlFrame? {
        applySnapshot(value, diagnostics: .init(activeProcesses: 0, openFileHandles: 0,
                                               bufferedOutputBytes: 0, outputGapsTotal: 0),
                      generation: snapshotGeneration, revision: readinessRevision)
    }

    func waitForSnapshotForTesting() async { await snapshotTask?.value }
    func cachedReadinessForTesting() -> String { readiness }
#endif

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
              frame.deadlineAt != nil else { return false }
        if frame.operation == "desktop_control_revoke_config" {
            return (target.configVersion ?? 0) > 0 && target.personaID.isEmpty && target.runID.isEmpty && target.generation == 0
        }
        if frame.operation == "desktop_control_revoke_binding" {
            return (target.configVersion ?? 0) > 0 && !target.personaID.isEmpty && target.runID.isEmpty && target.generation > 0
        }
        guard !target.personaID.isEmpty, !target.runID.isEmpty, target.generation > 0,
              (target.configVersion ?? 0) >= 0 else { return false }
        guard frame.operation != nil else { return false }
        return true
    }

    static func hasCapacity(for operation: String?, activeCount: Int) -> Bool {
        guard activeCount >= 0, activeCount < maximumInFlightCommands else { return false }
        if operation == "desktop_control_revoke_config" || operation == "desktop_control_revoke_binding" { return true }
        if operation == "desktop_control_exec_cancel" || operation == "desktop_control_release" {
            return activeCount < maximumInFlightCommands - 1
        }
        return activeCount < maximumInFlightCommands - reservedRevocationCommands
    }
}
