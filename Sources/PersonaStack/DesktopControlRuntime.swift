import AppKit
import Foundation
import PersonaStackCore

protocol DesktopControlDriverInstalling: Sendable {
    func validateOrInstall(
        repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?
    ) async throws -> CuaDriverInstallation
}

extension CuaDriverInstaller: DesktopControlDriverInstalling {}

@MainActor
final class DesktopControlRuntime: DesktopControlSetupRuntime {
    static let shared = DesktopControlRuntime()

    private let installer: any DesktopControlDriverInstalling
    private let credentials: any DesktopControlCredentialStoring
    private var cuaApplication: NSRunningApplication?
    private var proxy: CuaMCPProxy?
    private var startingProxy: CuaMCPProxy?
    private var gateway: DesktopControlGatewayConnection?
    private var pendingGateway: DesktopControlGatewayConnection?
    private var gatewayConnectionID: UUID?
    private var gatewayAttemptID = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var activeInstallation: DesktopControlInstallation?
    private var executor = DesktopControlCommandExecutor()
    private var lifecycleGeneration = UUID()
    private var disconnecting = false
    private(set) var gatewayConnected = false
    private(set) var tools: Set<String> = []
    private(set) var paused = false
    private(set) var readiness = "unknown"

    private init(installer: any DesktopControlDriverInstalling = CuaDriverInstaller(),
                 credentials: any DesktopControlCredentialStoring = KeychainDesktopControlCredentialStore()) {
        self.installer = installer
        self.credentials = credentials
    }

#if DEBUG
    static func makeForTesting(installer: any DesktopControlDriverInstalling,
                               credentials: any DesktopControlCredentialStoring) -> DesktopControlRuntime {
        DesktopControlRuntime(installer: installer, credentials: credentials)
    }
#endif

    func beginResume() throws -> UUID {
        guard !disconnecting else { throw CancellationError() }
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    func resume() async throws {
        try await resume(generation: beginResume())
    }

    func resume(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { throw CancellationError() }
        try await startCua(forceRepairInstall: false, startPaused: false, generation: generation)
    }

    func beginRepair(expectedGeneration: UUID? = nil) throws -> UUID {
        guard !disconnecting else { throw CancellationError() }
        if let expectedGeneration { try requireCurrentLifecycle(expectedGeneration) }
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    func repair(resumeRelay: Bool = false, expectedGeneration: UUID? = nil) async throws -> UUID {
        let generation = try beginRepair(expectedGeneration: expectedGeneration)
        try await repair(generation: generation, resumeRelay: resumeRelay)
        return generation
    }

    func repair(generation: UUID, resumeRelay: Bool = false) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { throw CancellationError() }
        let remainPaused = paused && !resumeRelay
        await stopLocalControl(generation: generation)
        try requireCurrentLifecycle(generation)
        do {
            do {
                try await startCua(forceRepairInstall: false, startPaused: remainPaused, generation: generation)
            } catch {
                try requireCurrentLifecycle(generation)
                guard Self.shouldForceRepair(after: error) else { throw error }
                try await startCua(forceRepairInstall: true, startPaused: remainPaused, generation: generation)
            }
        } catch {
            guard generation == lifecycleGeneration else { throw error }
            if remainPaused {
                paused = true
                readiness = "paused"
                await gateway?.setReadiness("paused")
            } else {
                paused = false
                readiness = Self.readiness(for: error)
                await gateway?.setReadiness(readiness)
            }
            throw error
        }
    }

    private func startCua(forceRepairInstall: Bool, startPaused: Bool, generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        if proxy == nil {
            do {
                let installation = try await installer.validateOrInstall(
                    repair: forceRepairInstall,
                    commitManagedInstall: { [weak self] installRoot, payload, replacing in
                        guard let self else { throw CancellationError() }
                        try self.requireCurrentLifecycle(generation)
                        guard !self.hasRunningCuaService() else { throw CuaMCPProxyError.serviceRunning }
                        if replacing { try FileManager.default.removeItem(at: installRoot) }
                        try FileManager.default.moveItem(at: payload, to: installRoot)
                    }
                )
                try requireCurrentLifecycle(generation)
                let application = try await launchCuaService(at: installation.applicationURL)
                try requireCurrentLifecycle(generation)
                cuaApplication = application

                let candidate = CuaMCPProxy(executableURL: installation.executableURL)
                startingProxy = candidate
                do {
                    _ = try await candidate.start()
                    try requireCurrentLifecycle(generation)
                    let catalog = try await candidate.listTools()
                    try requireCurrentLifecycle(generation)
                    let validatedTools = try await candidate.validateToolCatalog(catalog)
                    try requireCurrentLifecycle(generation)
                    tools = validatedTools
                    try await verifyCuaReadiness(candidate, generation: generation)
                    try requireCurrentLifecycle(generation)
                    proxy = candidate
                    startingProxy = nil
                } catch {
                    await candidate.stop()
                    if startingProxy === candidate { startingProxy = nil }
                    guard generation == lifecycleGeneration else { throw error }
                    tools = []
                    throw error
                }
            } catch {
                if generation == lifecycleGeneration {
                    await publishReadinessFailure(error, generation: generation)
                }
                throw error
            }
        }
        try requireCurrentLifecycle(generation)
        paused = startPaused
        readiness = startPaused ? "paused" : "ready"
        if let saved = try? credentials.load() {
            await gateway?.setReadiness(readiness)
            try requireCurrentLifecycle(generation)
            beginReconnectLoop(for: saved)
        }
    }

    func startPaused() async throws {
        guard !disconnecting else { throw CancellationError() }
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        paused = true
        readiness = "paused"
        guard let installation = try credentials.load() else { return }
        activeInstallation = installation
        let connected = await gateway?.isConnected() == true
        try requireCurrentLifecycle(generation)
        if connected {
            await gateway?.setReadiness("paused")
            try requireCurrentLifecycle(generation)
        } else {
            do {
                try await establishConnection(installation, generation: generation)
                try requireCurrentLifecycle(generation)
            } catch {
                guard generation == lifecycleGeneration else { return }
            }
        }
        beginReconnectLoop(for: installation)
    }

    func pause() async {
        guard let generation = beginPause() else { return }
        await pause(generation: generation)
    }

    func beginPause() -> UUID? {
        guard !disconnecting else { return nil }
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    func pause(generation: UUID) async {
        guard !disconnecting, generation == lifecycleGeneration else { return }
        await stopLocalControl(generation: generation)
    }

    private func stopLocalControl(generation: UUID) async {
        guard generation == lifecycleGeneration else { return }
        paused = true
        readiness = "paused"
        await gateway?.setReadiness("paused")
        guard generation == lifecycleGeneration else { return }
        let executorToClose = executor
        executor = DesktopControlCommandExecutor()
        await executorToClose.close()
        guard generation == lifecycleGeneration else { return }
        if let startingProxy {
            self.startingProxy = nil
            await startingProxy.stop()
            guard generation == lifecycleGeneration else { return }
        }
        if let proxy {
            self.proxy = nil
            tools = []
            await proxy.stop()
            guard generation == lifecycleGeneration else { return }
        }
        tools = []
    }

    func disconnect() async throws {
        let generation = try beginDisconnect()
        try await disconnect(generation: generation)
    }

    func beginDisconnect() throws -> UUID {
        guard !disconnecting else { throw CancellationError() }
        disconnecting = true
        lifecycleGeneration = UUID()
        paused = true
        readiness = "paused"
        return lifecycleGeneration
    }

    func disconnect(generation: UUID) async throws {
        guard disconnecting, generation == lifecycleGeneration else { throw CancellationError() }
        defer { if generation == lifecycleGeneration { disconnecting = false } }
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        await gateway?.setReadiness("paused")
        guard disconnecting, generation == lifecycleGeneration else { return }
        let pendingConnection = pendingGateway
        pendingGateway = nil
        if pendingConnection != nil { gatewayConnectionID = nil }
        await pendingConnection?.stop()
        guard disconnecting else { return }
        let installation: DesktopControlInstallation?
        let credentialLoadError: Error?
        do {
            installation = try credentials.load()
            credentialLoadError = nil
        } catch {
            installation = nil
            credentialLoadError = error
        }
        activeInstallation = installation
        await stopLocalControl(generation: generation)
        guard disconnecting, generation == lifecycleGeneration else { return }
        let enrollment = DesktopControlEnrollmentClient(credentials: credentials)
        if let installation {
            do {
                try await enrollment.revokeRemote(installation: installation, appURL: LaunchConfiguration.url())
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, generation == self.lifecycleGeneration else { return }
                    self.beginReconnectLoop(for: installation)
                }
                throw error
            }
            guard disconnecting, generation == lifecycleGeneration else { throw CancellationError() }
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        await gateway?.stop()
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        activeInstallation = nil
        if let credentialLoadError { throw credentialLoadError }
        if installation != nil { try credentials.delete() }
        paused = false
    }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID? = nil) async {
        guard !disconnecting else { return }
        let generation = lifecycleGeneration
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        activeInstallation = installation
        let alreadyConnected = await gateway?.isConnected() == true
        guard generation == lifecycleGeneration, !disconnecting else { return }
        if alreadyConnected {
            beginReconnectLoop(for: installation)
            return
        }
        do {
            try await establishConnection(installation, generation: generation)
        } catch {}
        guard generation == lifecycleGeneration, !disconnecting else { return }
        beginReconnectLoop(for: installation)
    }

    func isReady() -> Bool {
        !paused && isCuaReady() && gatewayConnected
    }

    var hasActiveInstallation: Bool { activeInstallation != nil }

    func isCuaReady() -> Bool {
        proxy != nil && !tools.isEmpty && cuaApplication?.isTerminated == false
    }

    static func cuaServiceLaunchConfiguration(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["serve"]
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.environment = CuaDriverCompatibility.processEnvironment(from: inheritedEnvironment)
        return configuration
    }

    private func launchCuaService(at applicationURL: URL) async throws -> NSRunningApplication {
        if let cuaApplication, !cuaApplication.isTerminated {
            return cuaApplication
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == CuaDriverCompatibility.bundleIdentifier && !$0.isTerminated
        }) {
            return running
        }
        return try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: Self.cuaServiceLaunchConfiguration()
        )
    }

    private func hasRunningCuaService() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            guard application.bundleIdentifier == CuaDriverCompatibility.bundleIdentifier,
                  !application.isTerminated else { return false }
            return true
        }
    }

    private func beginReconnectLoop(for installation: DesktopControlInstallation) {
        guard reconnectTask == nil else { return }
        activeInstallation = installation
        reconnectTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !(await self.gateway?.isConnected() ?? false) {
                    let generation = self.lifecycleGeneration
                    guard !self.disconnecting else { return }
                    do {
                        try await self.establishConnection(installation, generation: generation)
                    } catch {}
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func establishConnection(_ installation: DesktopControlInstallation, generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { throw CancellationError() }
        guard paused || isCuaReady() || readiness != "ready" else { throw CuaMCPProxyError.notStarted }
        let attemptID = UUID()
        gatewayAttemptID = attemptID
        if let pendingGateway {
            self.pendingGateway = nil
            gatewayConnectionID = nil
            await pendingGateway.stop()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        }
        if let gateway {
            self.gateway = nil
            gatewayConnectionID = nil
            gatewayConnected = false
            await gateway.stop()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        }
        let connectionID = UUID()
        let connection = DesktopControlGatewayConnection(
            installation: installation,
            onDisconnect: { [weak self] in await self?.gatewayDisconnected(connectionID: connectionID) },
            handler: { [weak self] frame, onChunk in
                guard let self else { return Self.failure(for: frame, code: "desktop_executor_unavailable") }
                return await self.handle(frame, connectionID: connectionID, onChunk: onChunk)
            }
        )
        pendingGateway = connection
        gatewayConnectionID = connectionID
        do {
            try await connection.connect()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
            await connection.setReadiness(readiness)
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
            guard await connection.isConnected() else { throw DesktopControlGatewayConnectionError.socketUnavailable }
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
            gateway = connection
            pendingGateway = nil
            gatewayConnectionID = connectionID
            activeInstallation = installation
            gatewayConnected = true
        } catch {
            if pendingGateway === connection { pendingGateway = nil }
            if gatewayConnectionID == connectionID { gatewayConnectionID = nil }
            if generation == lifecycleGeneration, gatewayAttemptID == attemptID { gatewayConnected = false }
            await connection.stop()
            throw error
        }
    }

    private func gatewayDisconnected(connectionID: UUID) {
        guard gatewayConnectionID == connectionID else { return }
        gatewayAttemptID = UUID()
        gatewayConnected = false
    }

    private func requireCurrentLifecycle(_ generation: UUID) throws {
        guard lifecycleGeneration == generation else { throw CancellationError() }
    }

    func isCurrentLifecycle(_ generation: UUID) -> Bool {
        generation == lifecycleGeneration && !disconnecting
    }

    private func requireCurrentConnectionAttempt(_ generation: UUID, attemptID: UUID) throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, gatewayAttemptID == attemptID else { throw CancellationError() }
    }

    private func publishReadinessFailure(_ error: Error, generation: UUID) async {
        guard generation == lifecycleGeneration else { return }
        readiness = Self.readiness(for: error)
        guard let installation = try? credentials.load() else { return }
        guard generation == lifecycleGeneration else { return }
        activeInstallation = installation
        let connected = await gateway?.isConnected() == true
        guard generation == lifecycleGeneration else { return }
        if !connected {
            do { try await establishConnection(installation, generation: generation) }
            catch {
                guard generation == lifecycleGeneration else { return }
            }
        }
        guard generation == lifecycleGeneration else { return }
        if let gateway {
            await gateway.setReadiness(readiness)
            guard generation == lifecycleGeneration else { return }
        }
        beginReconnectLoop(for: installation)
    }

    static func readiness(for error: Error) -> String {
        guard let error = error as? CuaMCPProxyError else { return "cua_unavailable" }
        switch error {
        case .permissionsRequired:
            return "permission_required"
        case .functionalProbeFailed:
            return "cua_unavailable"
        default:
            return "cua_unavailable"
        }
    }

    static func shouldForceRepair(after error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? CuaMCPProxyError else { return true }
        switch error {
        case .permissionsRequired, .serviceRunning:
            return false
        default:
            return true
        }
    }

    private func handle(_ frame: DesktopControlFrame,
                        connectionID: UUID,
                        onChunk: @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame {
        guard Self.acceptsCommand(connectionID: connectionID,
                                  currentConnectionID: gatewayConnectionID,
                                  disconnecting: disconnecting) else {
            return Self.failure(for: frame, code: "desktop_connection_stale", message: "The desktop connection changed before this command could run. Retry only after checking whether the previous action completed.")
        }
        guard !paused else {
            return Self.failure(for: frame, code: "desktop_paused", message: "Desktop Control is paused on this Mac.")
        }
        guard readiness == "ready" else {
            return Self.failure(for: frame, code: readiness, message: "Desktop Control needs attention on this Mac. Review the connection status in PersonaStack Desktop.")
        }
        guard let activeInstallation, frame.target?.installationID == activeInstallation.installationID else {
            return Self.failure(for: frame, code: "desktop_executor_unavailable")
        }
        return await executor.handle(frame, proxy: proxy, onChunk: onChunk)
    }

    nonisolated private static func failure(for frame: DesktopControlFrame, code: String, message: String = "The desktop command is not available.") -> DesktopControlFrame {
        DesktopControlFrame(version: 1, type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }

    static func acceptsCommand(connectionID: UUID, currentConnectionID: UUID?, disconnecting: Bool) -> Bool {
        !disconnecting && currentConnectionID == connectionID
    }

    private func verifyCuaReadiness(_ candidate: CuaMCPProxy, generation: UUID) async throws {
        let permissions = try await candidate.callTool(
            name: "check_permissions",
            argumentsJSON: Data(#"{"prompt":true,"probe_direct_capture":false}"#.utf8)
        )
        try requireCurrentLifecycle(generation)
        guard let permissionResult = Self.toolResult(permissions),
              let structured = permissionResult["structuredContent"] as? [String: Any],
              structured["accessibility"] as? Bool == true,
              structured["screen_recording"] as? Bool == true else {
            throw CuaMCPProxyError.permissionsRequired
        }

        let screenshot = try await candidate.callTool(
            name: "get_desktop_state",
            argumentsJSON: Data("{}".utf8)
        )
        try requireCurrentLifecycle(generation)
        guard let screenshotResult = Self.toolResult(screenshot),
              let screenshotContent = screenshotResult["content"] as? [[String: Any]],
              screenshotContent.contains(where: { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" }) else {
            throw CuaMCPProxyError.functionalProbeFailed
        }

        let accessibility = try await candidate.callTool(
            name: "get_accessibility_tree",
            argumentsJSON: Data("{}".utf8)
        )
        try requireCurrentLifecycle(generation)
        guard let accessibilityResult = Self.toolResult(accessibility),
              let accessibilityContent = accessibilityResult["content"] as? [[String: Any]],
              !accessibilityContent.isEmpty else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
    }

    private static func toolResult(_ data: Data) -> [String: Any]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["error"] == nil,
              let result = response["result"] as? [String: Any],
              (result["isError"] as? Bool) != true else { return nil }
        return result
    }
}
