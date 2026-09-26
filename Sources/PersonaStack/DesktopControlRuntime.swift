import AppKit
import Foundation
import os
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
    static let shared = DesktopControlRuntime(relayStateReader: DesktopControlEnrollmentClient())
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-relay")

    private let sessionLock = DesktopControlSessionLock()
    private var lockGeneration = UUID()
    private let installer: any DesktopControlDriverInstalling
    private let credentials: any DesktopControlCredentialStoring
    private let relayStateReader: (any DesktopControlRelayStateReading)?
    private let preferences: UserDefaults
    private let confirmForegroundSetup: @MainActor () -> Bool
    private var cuaApplication: NSRunningApplication?
    private var selectedCuaApplicationURL: URL?
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
    private var setupMayRunUnconfigured = false
    private var disconnecting = false
    private var executorCleanupInProgress = false
    private var executorCleanupTask: Task<Bool, Never>?
    private var executorCleanupFailed = false
    private var lockCleanupTask: Task<Void, Never>?
    private var proxyInterruptedForLock = false
    private(set) var gatewayConnected = false
    private(set) var tools: Set<String> = []
    private(set) var paused = false
    private(set) var readiness = "unknown"

    private init(installer: any DesktopControlDriverInstalling = CuaDriverInstaller(),
                 credentials: any DesktopControlCredentialStoring = KeychainDesktopControlCredentialStore(),
                 relayStateReader: (any DesktopControlRelayStateReading)? = nil,
                 preferences: UserDefaults = .standard,
                 confirmForegroundSetup: @escaping @MainActor () -> Bool = DesktopControlRuntime.showForegroundSetupConfirmation) {
        self.installer = installer
        self.credentials = credentials
        self.relayStateReader = relayStateReader
        self.preferences = preferences
        self.confirmForegroundSetup = confirmForegroundSetup
        sessionLock.onChange = { [weak self] state in
            guard let self else { return }
            self.lockGeneration = UUID()
            let lockGeneration = self.lockGeneration
            if state != .unlocked {
                self.readiness = "locked"
                self.executorCleanupInProgress = true
                if self.proxy != nil || self.startingProxy != nil { self.proxyInterruptedForLock = true }
                self.proxy?.interrupt()
                self.startingProxy?.interrupt()
                self.lockCleanupTask = Task { await self.cleanupExecutor() }
            }
            Task { await self.sessionLockChanged(lockGeneration) }
        }
    }

#if DEBUG
    func savedInstallationForTesting() throws -> DesktopControlInstallation? {
        try savedInstallation()
    }

    static func makeForTesting(installer: any DesktopControlDriverInstalling,
                               credentials: any DesktopControlCredentialStoring,
                               executor: DesktopControlCommandExecutor? = nil,
                               connectionID: UUID? = nil,
                               installation: DesktopControlInstallation? = nil,
                               connected: Bool = false,
                               readiness: String = "unknown",
                               paused: Bool = false,
                               sessionLockState: DesktopControlSessionLock.State? = nil,
                               cleanupInProgress: Bool = false,
                               cleanupFailed: Bool = false,
                               relayStateReader: (any DesktopControlRelayStateReading)? = nil,
                               preferences: UserDefaults = .standard,
                               confirmForegroundSetup: @escaping @MainActor () -> Bool = { true }) -> DesktopControlRuntime {
        let runtime = DesktopControlRuntime(installer: installer, credentials: credentials, relayStateReader: relayStateReader, preferences: preferences, confirmForegroundSetup: confirmForegroundSetup)
        if let executor { runtime.executor = executor }
        runtime.gatewayConnectionID = connectionID
        runtime.activeInstallation = installation
        runtime.gatewayConnected = connected
        runtime.readiness = readiness
        runtime.paused = paused
        runtime.executorCleanupInProgress = cleanupInProgress
        runtime.executorCleanupFailed = cleanupFailed
        if let sessionLockState { runtime.sessionLock.receive(sessionLockState) }
        return runtime
    }

    func handleForTesting(_ frame: DesktopControlFrame, connectionID: UUID) async -> DesktopControlFrame {
        await handle(frame, connectionID: connectionID, onChunk: { _ in })
    }

    var lockCleanupStartedForTesting: Bool { executorCleanupInProgress && readiness == "locked" }

    func waitForLockCleanupForTesting() async { await lockCleanupTask?.value }
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
        setupMayRunUnconfigured = false
        guard let installation = try savedInstallation() else { return }
        if await stopIfNoActiveConfiguration(installation: installation, generation: generation) { return }
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { return }
        try await startCua(forceRepairInstall: false, startPaused: false, generation: generation)
    }

    func resumeForSetup(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { throw CancellationError() }
        try confirmForegroundSession()
        try requireCurrentLifecycle(generation)
        setupMayRunUnconfigured = true
        try await startCua(forceRepairInstall: false, startPaused: false, generation: generation)
    }

    var requiresForegroundSessionConfirmation: Bool { sessionLock.state == .unknown }

    func confirmForegroundSession() throws {
        if sessionLock.state == .locked {
            throw DesktopControlEnrollmentError.nativeCapabilitiesUnavailable
        }
        guard sessionLock.state == .unknown else { return }
        guard confirmForegroundSetup() else { throw CancellationError() }
        sessionLock.confirmForegroundSetup()
    }

    private static func showForegroundSetupConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow Desktop Control on this Mac?"
        alert.informativeText = "Continue setup while this Mac is unlocked. PersonaStack will stop remote control when the screen locks."
        alert.addButton(withTitle: "Continue setup")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
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
                let socketURL = Self.cuaSocketURL()
                let application = try await launchCuaService(
                    at: installation.applicationURL, socketURL: socketURL, generation: generation
                )
                try requireCurrentLifecycle(generation)
                cuaApplication = application
                selectedCuaApplicationURL = installation.applicationURL

                let candidate = CuaMCPProxy(
                    executableURL: installation.executableURL,
                    socketURL: socketURL,
                    expectedDaemonPID: application.processIdentifier
                )
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
        readiness = startPaused ? "paused" : (sessionLock.allowsControl ? "ready" : "locked")
        if let saved = try? savedInstallation() {
            await gateway?.setReadiness(readiness)
            try requireCurrentLifecycle(generation)
            beginReconnectLoop(for: saved)
        }
    }

    func startPaused() async throws {
        guard !disconnecting else { throw CancellationError() }
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        setupMayRunUnconfigured = false
        guard let installation = try savedInstallation() else { return }
        if await stopIfNoActiveConfiguration(installation: installation, generation: generation) { return }
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { return }
        paused = true
        readiness = "paused"
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
        await cleanupExecutor()
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
            installation = try savedInstallation()
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
        } catch {
            let failure = error as NSError
            logger.error("gateway connection failed: \(failure.domain, privacy: .public) code \(failure.code, privacy: .public)")
        }
        guard generation == lifecycleGeneration, !disconnecting else { return }
        beginReconnectLoop(for: installation)
    }

    func isReady() -> Bool {
        !paused && sessionLock.allowsControl && readiness == "ready" && isCuaReady() && gatewayConnected
    }

    var nativeExecutorReady: Bool {
        !paused && sessionLock.allowsControl && !executorCleanupInProgress && !executorCleanupFailed
    }

    var hasActiveInstallation: Bool { activeInstallation != nil }

    var sessionRecoveryMessage: String? {
        switch sessionLock.state {
        case .unknown: "Confirm this Mac is unlocked to enable remote control."
        case .locked: "Unlock this Mac to enable remote control."
        case .unlocked: nil
        }
    }

    func isCuaReady() -> Bool {
        guard proxy != nil, !tools.isEmpty,
              let cuaApplication, !cuaApplication.isTerminated,
              let selectedCuaApplicationURL,
              Self.matchesSelectedApplication(cuaApplication.bundleURL, selectedCuaApplicationURL) else { return false }
        return CuaSocketIdentity.peerPID(at: Self.cuaSocketURL()) == cuaApplication.processIdentifier
    }

    func probeNativeCapabilities(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !paused, sessionLock.allowsControl, readiness == "ready", isCuaReady(), nativeExecutorReady else {
            throw DesktopControlEnrollmentError.nativeCapabilitiesUnavailable
        }
        let probeExecutor = DesktopControlCommandExecutor()
        do {
            try await probeExecutor.probeNativeCapabilities { [weak self] in
                guard let self else { throw CancellationError() }
                try self.requireCurrentLifecycle(generation)
            }
            guard await probeExecutor.close() else { throw DesktopControlEnrollmentError.nativeCapabilitiesUnavailable }
        } catch {
            _ = await probeExecutor.close()
            throw error
        }
        try requireCurrentLifecycle(generation)
    }

    static func cuaServiceLaunchConfiguration(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        socketURL: URL? = nil
    ) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["serve"] + (socketURL.map { ["--socket", $0.path] } ?? [])
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.environment = CuaDriverCompatibility.processEnvironment(from: inheritedEnvironment)
        return configuration
    }

    static func cuaSocketURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Caches/cua-driver/cua-driver.sock")
    }

    static func matchesSelectedApplication(_ runningURL: URL?, _ selectedURL: URL) -> Bool {
        runningURL?.resolvingSymlinksInPath().standardizedFileURL ==
            selectedURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func launchCuaService(at applicationURL: URL, socketURL: URL,
                                  generation: UUID) async throws -> NSRunningApplication {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == CuaDriverCompatibility.bundleIdentifier && !$0.isTerminated
        }
        guard running.count <= 1,
              running.allSatisfy({ Self.matchesSelectedApplication($0.bundleURL, applicationURL) }) else {
            throw CuaMCPProxyError.serviceMismatch
        }
        let application: NSRunningApplication
        if let existing = running.first {
            application = existing
        } else {
            guard CuaSocketIdentity.peerPID(at: socketURL) == nil else {
                throw CuaMCPProxyError.serviceMismatch
            }
            application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: Self.cuaServiceLaunchConfiguration(socketURL: socketURL)
            )
        }
        guard Self.matchesSelectedApplication(application.bundleURL, applicationURL),
              application.processIdentifier > 0 else { throw CuaMCPProxyError.serviceMismatch }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            try requireCurrentLifecycle(generation)
            guard !application.isTerminated else { throw CuaMCPProxyError.processExited }
            if let peerPID = CuaSocketIdentity.peerPID(at: socketURL) {
                guard peerPID == application.processIdentifier else { throw CuaMCPProxyError.serviceMismatch }
                return application
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CuaMCPProxyError.timeout
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
                    if !self.setupMayRunUnconfigured {
                        do {
                            let hasActiveConfig = try await self.hasActiveConfig(for: installation)
                            guard generation == self.lifecycleGeneration else { return }
                            if !hasActiveConfig {
                                await self.stopIdleRelay(expectedLifecycle: generation)
                                return
                            }
                        } catch {
                            // Keep reconnecting when the authority cannot be read.
                        }
                    }
                    do {
                        try await self.establishConnection(installation, generation: generation)
                    } catch {
                        let failure = error as NSError
                        self.logger.error("gateway reconnect failed: \(failure.domain, privacy: .public) code \(failure.code, privacy: .public)")
                        if Self.readiness(for: error) == "upgrade_required" {
                            self.readiness = "upgrade_required"
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }

    private func establishConnection(_ installation: DesktopControlInstallation, generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !executorCleanupInProgress else { throw CancellationError() }
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
            await cleanupExecutor()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        }
        let connectionID = UUID()
        let connection = DesktopControlGatewayConnection(
            installation: installation,
            onDisconnect: { [weak self] error in await self?.gatewayDisconnected(connectionID: connectionID, error: error) },
            diagnosticsProvider: { [weak self] in
                guard let self else {
                    return DesktopControlDiagnostics(activeProcesses: 0, openFileHandles: 0,
                                                     bufferedOutputBytes: 0, outputGapsTotal: 0)
                }
                return await self.executor.diagnostics()
            },
            readinessProvider: { [weak self] in await self?.heartbeatReadiness() },
            afterConfigRevocation: { [weak self] in await self?.reconcileRelayAfterConfigRevocation(connectionID: connectionID) },
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

    func gatewayDisconnected(connectionID: UUID, error: DesktopControlGatewayConnectionError?) async {
        guard gatewayConnectionID == connectionID else { return }
        let disconnectAttempt = UUID()
        let generation = lifecycleGeneration
        gatewayAttemptID = disconnectAttempt
        gatewayConnected = false
        gatewayConnectionID = nil
        await cleanupExecutor()
        guard gatewayAttemptID == disconnectAttempt, lifecycleGeneration == generation else { return }
        if executorCleanupFailed { readiness = "cua_unavailable" }
        if error == .upgradeRequired { readiness = "upgrade_required" }
    }

    private func cleanupExecutor() async {
        if let task = executorCleanupTask {
            _ = await task.value
            return
        }
        executorCleanupInProgress = true
        let oldExecutor = executor
        let task = Task { await oldExecutor.close() }
        executorCleanupTask = task
        let clean = await task.value
        executorCleanupFailed = !clean
        if clean { executor = DesktopControlCommandExecutor() }
        executorCleanupTask = nil
        executorCleanupInProgress = false
    }

    private func sessionLockChanged(_ lockGeneration: UUID) async {
        if !sessionLock.allowsControl {
            readiness = "locked"
            await cleanupExecutor()
            guard self.lockGeneration == lockGeneration, !sessionLock.allowsControl else { return }
            await gateway?.setReadiness("locked")
            return
        }
        guard self.lockGeneration == lockGeneration else { return }
        if let task = lockCleanupTask { await task.value }
        lockCleanupTask = nil
        if let task = executorCleanupTask { _ = await task.value }
        guard self.lockGeneration == lockGeneration, !paused, !disconnecting else { return }
        let generation = lifecycleGeneration
        if proxyInterruptedForLock {
            proxyInterruptedForLock = false
            if let interruptedProxy = proxy {
                proxy = nil
                tools = []
                await interruptedProxy.stop()
            }
            if let interruptedStartingProxy = startingProxy {
                startingProxy = nil
                await interruptedStartingProxy.stop()
            }
            guard self.lockGeneration == lockGeneration, generation == lifecycleGeneration else { return }
            do {
                try await startCua(forceRepairInstall: false, startPaused: false, generation: generation)
            } catch {
                guard self.lockGeneration == lockGeneration, generation == lifecycleGeneration else { return }
                readiness = Self.readiness(for: error)
                await gateway?.setReadiness(readiness)
                return
            }
        }
        guard let proxy else { return }
        do {
            try await verifyCuaReadiness(proxy, generation: generation)
            guard self.lockGeneration == lockGeneration, sessionLock.allowsControl,
                  generation == lifecycleGeneration, !paused, !executorCleanupFailed else { return }
            readiness = "ready"
        } catch {
            guard self.lockGeneration == lockGeneration, generation == lifecycleGeneration else { return }
            readiness = Self.readiness(for: error)
        }
        await gateway?.setReadiness(readiness)
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
        guard let installation = try? savedInstallation() else { return }
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

    func finishSetupIfIdle() async {
        let generation = lifecycleGeneration
        setupMayRunUnconfigured = false
        let saved: DesktopControlInstallation?
        do { saved = try savedInstallation() }
        catch { return }
        guard let installation = saved else {
            await stopIdleRelay(expectedLifecycle: generation)
            return
        }
        do {
            let hasActiveConfig = try await hasActiveConfig(for: installation)
            guard generation == lifecycleGeneration else { return }
            if !hasActiveConfig { await stopIdleRelay(expectedLifecycle: generation) }
        } catch {
            // Preserve the relay when the API cannot prove that no workspace still uses it.
        }
    }

    private func stopIfNoActiveConfiguration(installation: DesktopControlInstallation, generation: UUID) async -> Bool {
        guard let relayStateReader else { return false }
        do {
            let hasActiveConfig = try await relayStateReader.hasActiveConfig(installation: installation, appURL: LaunchConfiguration.url())
            guard generation == lifecycleGeneration else { return false }
            if !hasActiveConfig {
                await stopIdleRelay(expectedLifecycle: generation)
                return true
            }
        } catch {
            // A failed read must not stop a relay another workspace may still use.
        }
        return false
    }

    private func savedInstallation() throws -> DesktopControlInstallation? {
        if let activeInstallation { return activeInstallation }
        let saved = try credentials.load()
        activeInstallation = saved
        return saved
    }

    func savedInstallation(for appURL: URL) throws -> DesktopControlInstallation? {
        let saved = try savedInstallation()
        try saved?.requireEnvironment(appURL)
        return saved
    }

    private func hasActiveConfig(for installation: DesktopControlInstallation) async throws -> Bool {
        guard let relayStateReader else { return true }
        return try await relayStateReader.hasActiveConfig(installation: installation, appURL: LaunchConfiguration.url())
    }

    private func reconcileRelayAfterConfigRevocation(connectionID: UUID) async {
        guard gatewayConnectionID == connectionID, !disconnecting,
              !setupMayRunUnconfigured, let installation = activeInstallation else { return }
        let generation = lifecycleGeneration
        do {
            let hasActiveConfig = try await hasActiveConfig(for: installation)
            guard gatewayConnectionID == connectionID, generation == lifecycleGeneration else { return }
            if !hasActiveConfig { await stopIdleRelay(expectedLifecycle: generation) }
        } catch {
            // A failed read must not stop a relay another workspace may still use.
        }
    }

    private func stopIdleRelay(expectedLifecycle: UUID) async {
        guard lifecycleGeneration == expectedLifecycle, !disconnecting else { return }
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        setupMayRunUnconfigured = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        let pending = pendingGateway
        pendingGateway = nil
        await pending?.stop()
        guard generation == lifecycleGeneration else { return }
        await stopLocalControl(generation: generation)
        guard generation == lifecycleGeneration else { return }
        if executorCleanupFailed {
            readiness = "cua_unavailable"
            await gateway?.setReadiness(readiness)
            if let installation = activeInstallation, gateway != nil { beginReconnectLoop(for: installation) }
            return
        }
        await gateway?.stop()
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        activeInstallation = nil
        preferences.set(false, forKey: "desktopControlRelayEnabled")
        preferences.set(false, forKey: "desktopControlRelayPaused")
        paused = false
        readiness = "unknown"
    }

    static func readiness(for error: Error) -> String {
        if let gatewayError = error as? DesktopControlGatewayConnectionError, gatewayError == .upgradeRequired {
            return "upgrade_required"
        }
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
        case .permissionsRequired, .serviceRunning, .serviceMismatch:
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
        let isStatus = frame.operation == "desktop_control_status"
        guard isStatus || (!executorCleanupInProgress && !executorCleanupFailed) else {
            return Self.failure(for: frame, code: "desktop_executor_unavailable")
        }
        if frame.operation == "desktop_control_revoke_config" || frame.operation == "desktop_control_revoke_binding" {
            guard let activeInstallation, frame.target?.installationID == activeInstallation.installationID else {
                return Self.failure(for: frame, code: "desktop_executor_unavailable")
            }
            return await executor.handle(frame, proxy: proxy, onChunk: onChunk)
        }
        guard isStatus || sessionLock.allowsControl else {
            return Self.failure(for: frame, code: "locked", message: "Unlock this Mac before using Desktop Control. After starting the service, lock and unlock once to confirm the current session.")
        }
        guard isStatus || !paused else {
            return Self.failure(for: frame, code: "desktop_paused", message: "Desktop Control is paused on this Mac.")
        }
        guard let activeInstallation, frame.target?.installationID == activeInstallation.installationID else {
            return Self.failure(for: frame, code: "desktop_executor_unavailable")
        }
        if Self.requiresCua(frame.operation) {
            if readiness == "ready", !isCuaReady() {
                readiness = "cua_unavailable"
                await gateway?.setReadiness(readiness)
            }
            guard readiness == "ready" else {
                return Self.failure(for: frame, code: readiness, message: "GUI control needs attention on this Mac. Review Cua permissions and service status in PersonaStack Desktop.")
            }
        }
        let commandGeneration = lifecycleGeneration
        let response = await executor.handle(frame, proxy: proxy, onChunk: onChunk)
        if !isStatus && !sessionLock.allowsControl {
            return Self.failure(for: frame, code: "locked", message: "This Mac locked while the command was running. Check whether the action completed before retrying.")
        }
        if isStatus {
            return Self.enrichStatus(response,
                                     connected: gatewayConnected,
                                     guiReadiness: readiness,
                                     nativeExecutorReady: !executorCleanupInProgress && !executorCleanupFailed,
                                     paused: paused,
                                     locked: sessionLock.state == .locked,
                                     sessionUnlocked: sessionLock.allowsControl)
        }
        if Self.requiresCua(frame.operation), response.type == "failure", response.errorCode == "desktop_command_failed" {
            let recoveredReadiness = await readinessAfterGuiFailure(generation: commandGeneration)
            guard commandGeneration == lifecycleGeneration else { return response }
            readiness = recoveredReadiness
            await gateway?.setReadiness(readiness)
            if readiness == "ready" { return response }
            return Self.failure(for: frame, code: readiness, message: "Cua could not complete GUI control. Review its permissions and service status in PersonaStack Desktop.")
        }
        return response
    }

    private func heartbeatReadiness() async -> String? {
        if Self.shouldProbeGuiRecovery(readiness: readiness, paused: paused,
                                       unlocked: sessionLock.allowsControl, cuaReady: isCuaReady()),
           let proxy {
            let generation = lifecycleGeneration
            let previousReadiness = readiness
            do {
                try await verifyCuaReadiness(proxy, generation: generation, timeout: 5)
                if generation == lifecycleGeneration, readiness == previousReadiness,
                   !paused, sessionLock.allowsControl, isCuaReady() {
                    readiness = "ready"
                }
            } catch {
                if generation == lifecycleGeneration, readiness == previousReadiness {
                    readiness = Self.readiness(for: error)
                }
            }
        }
        guard readiness == "ready" else { return readiness }
        guard isCuaReady() else {
            readiness = "cua_unavailable"
            return readiness
        }
        return readiness
    }

    static func shouldProbeGuiRecovery(readiness: String, paused: Bool, unlocked: Bool, cuaReady: Bool) -> Bool {
        (readiness == "permission_required" || readiness == "cua_unavailable") && !paused && unlocked && cuaReady
    }

    private func readinessAfterGuiFailure(generation: UUID) async -> String {
        guard generation == lifecycleGeneration, isCuaReady(), let proxy else { return "cua_unavailable" }
        do {
            try await verifyCuaPermissions(proxy, generation: generation, timeout: 5)
            return generation == lifecycleGeneration
                ? Self.reconciledGuiReadiness(permissionProbeSucceeded: true, failureReadiness: "cua_unavailable")
                : readiness
        } catch {
            guard generation == lifecycleGeneration else { return readiness }
            return Self.reconciledGuiReadiness(permissionProbeSucceeded: false, failureReadiness: Self.readiness(for: error))
        }
    }

    static func reconciledGuiReadiness(permissionProbeSucceeded: Bool, failureReadiness: String) -> String {
        permissionProbeSucceeded ? "ready" : failureReadiness
    }

    static func enrichStatus(_ frame: DesktopControlFrame,
                             connected: Bool,
                             guiReadiness: String,
                             nativeExecutorReady: Bool,
                             paused: Bool,
                             locked: Bool,
                             sessionUnlocked: Bool) -> DesktopControlFrame {
        guard frame.type == "result", case .object(var result)? = frame.result else { return frame }
        let guiReady = guiReadiness == "ready"
        let nativeReady = nativeExecutorReady && result["native_executor_ready"] == .bool(true)
        result["connected"] = .bool(connected)
        result["gui_readiness"] = .string(guiReadiness)
        result["gui_ready"] = .bool(guiReady)
        result["available"] = .bool(nativeReady)
        result["native_executor_ready"] = .bool(nativeReady)
        result["paused"] = .bool(paused)
        result["locked"] = .bool(locked)
        result["session_unlocked"] = .bool(sessionUnlocked)
        result["control_available"] = .bool(connected && guiReady && nativeReady && !paused && sessionUnlocked)
        return DesktopControlFrame(version: frame.version, type: frame.type, requestID: frame.requestID,
                                   result: .object(result))
    }

    nonisolated private static func failure(for frame: DesktopControlFrame, code: String, message: String = "The desktop command is not available.") -> DesktopControlFrame {
        DesktopControlFrame(version: 1, type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }

    static func acceptsCommand(connectionID: UUID, currentConnectionID: UUID?, disconnecting: Bool) -> Bool {
        !disconnecting && currentConnectionID == connectionID
    }

    static func requiresCua(_ operation: String?) -> Bool {
        switch operation {
        case "desktop_control_observe", "desktop_control_input", "desktop_control_application",
             "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser":
            return true
        default:
            return false
        }
    }

    private func verifyCuaReadiness(_ candidate: CuaMCPProxy, generation: UUID,
                                    timeout: Int32 = 60) async throws {
        try await verifyCuaPermissions(candidate, generation: generation, timeout: timeout)

        // Permission setup remains available while the initial lock state is
        // unknown. Actual screen probes wait for an observed unlock.
        guard sessionLock.allowsControl else { return }

        let screenshot = try await candidate.callTool(
            name: "get_desktop_state",
            argumentsJSON: Data("{}".utf8), timeout: timeout
        )
        try requireCurrentLifecycle(generation)
        guard let screenshotResult = Self.toolResult(screenshot),
              let screenshotContent = screenshotResult["content"] as? [[String: Any]],
              screenshotContent.contains(where: { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" }) else {
            throw CuaMCPProxyError.functionalProbeFailed
        }

        let accessibility = try await candidate.callTool(
            name: "get_accessibility_tree",
            argumentsJSON: Data("{}".utf8), timeout: timeout
        )
        try requireCurrentLifecycle(generation)
        guard let accessibilityResult = Self.toolResult(accessibility),
              let accessibilityContent = accessibilityResult["content"] as? [[String: Any]],
              !accessibilityContent.isEmpty else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
    }

    private func verifyCuaPermissions(_ candidate: CuaMCPProxy, generation: UUID,
                                      timeout: Int32 = 60) async throws {
        let permissions = try await candidate.callTool(
            name: "check_permissions",
            argumentsJSON: CuaDriverCompatibility.permissionProbeArgumentsJSON,
            timeout: timeout
        )
        try requireCurrentLifecycle(generation)
        guard let permissionResult = Self.toolResult(permissions),
              let structured = permissionResult["structuredContent"] as? [String: Any],
              structured["accessibility"] as? Bool == true,
              structured["screen_recording"] as? Bool == true else {
            throw CuaMCPProxyError.permissionsRequired
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
