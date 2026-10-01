import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
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

private struct DesktopControlOwnedCuaStopError: LocalizedError {
    var errorDescription: String? {
        "Desktop Control disconnected, but PersonaStack could not stop its desktop control service. Quit PersonaStack to finish local cleanup."
    }
}

enum DesktopControlEnvironmentSwitchError: LocalizedError {
    case cleanupFailed

    var errorDescription: String? {
        "Desktop Control could not finish cleanup. Remote control remains paused. Repair or disconnect it before changing servers."
    }
}

@MainActor
final class DesktopControlRuntime: DesktopControlSetupRuntime {
    static let shared = DesktopControlRuntime(
        relayStateReader: DesktopControlEnrollmentClient(),
        configurationProvider: { try LaunchConfiguration.selectedEnvironment() }
    )
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-relay")

    private let sessionLock = DesktopControlSessionLock()
    private var lockGeneration = UUID()
    private let installer: any DesktopControlDriverInstalling
    private let credentials: any DesktopControlCredentialStoring
    private let relayStateReader: (any DesktopControlRelayStateReading)?
    private let preferences: UserDefaults
    private let configurationProvider: () throws -> DesktopEnvironmentConfiguration
    private let confirmForegroundSetup: @MainActor () -> Bool
    private var cuaService: CuaEmbeddedService?
    private var selectedCuaExecutableURL: URL?
    private var verifiedCuaHostGeneration: UUID?
    private var verifiedCuaCapabilitiesGeneration: UUID?
    private let hostPermissions: @MainActor () -> (accessibility: Bool, screenRecording: Bool)
    private var stopCuaService: @MainActor (CuaEmbeddedService) async -> Bool = { await $0.stop() }
    private var proxy: CuaMCPProxy?
    private var cuaStartup: (id: UUID, task: Task<Void, Error>)?
    private var cuaShutdown: (id: UUID, task: Task<Bool, Never>)?
    private var startingProxy: CuaMCPProxy?
    private var gateway: DesktopControlGatewayConnection?
    private var pendingGateway: DesktopControlGatewayConnection?
    private var gatewayConnectionID: UUID?
    private var gatewayAttemptID = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var activeInstallation: DesktopControlInstallation?
    private var credentialAuthorizationInProgress = false
    private var executor = DesktopControlCommandExecutor()
    private weak var inputPermissionTarget: (any DesktopInputPermissionTarget)?
    private var lifecycleGeneration = UUID() {
        didSet { inputPermissionTarget?.invalidate() }
    }
    private var setupMayRunUnconfigured = false
    // Full startup authorizes recovery. Permission-only preparation cannot do so.
    private var allowsAutomaticCuaRecovery = false
    private var sessionLockChangeTask: Task<Void, Never>?
    private var disconnecting = false
    private var environmentSwitchPending = false
    private var repairInProgress = false
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
                 configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() },
                 confirmForegroundSetup: @escaping @MainActor () -> Bool = DesktopControlRuntime.showForegroundSetupConfirmation,
                 hostPermissions: @escaping @MainActor () -> (accessibility: Bool, screenRecording: Bool) = {
                     (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
                 }) {
        self.installer = installer
        self.credentials = credentials
        self.relayStateReader = relayStateReader
        self.preferences = preferences
        self.configurationProvider = configurationProvider
        self.confirmForegroundSetup = confirmForegroundSetup
        self.hostPermissions = hostPermissions
        sessionLock.onChange = { [weak self] state in
            guard let self else { return }
            self.lockGeneration = UUID()
            self.inputPermissionTarget?.invalidate()
            let lockGeneration = self.lockGeneration
            if state != .unlocked {
                self.verifiedCuaCapabilitiesGeneration = nil
                self.readiness = "locked"
                self.executorCleanupInProgress = true
                if self.proxy != nil || self.startingProxy != nil { self.proxyInterruptedForLock = true }
                self.proxy?.interrupt()
                self.startingProxy?.interrupt()
                self.lockCleanupTask = Task { await self.cleanupExecutor() }
            }
            self.sessionLockChangeTask = Task { await self.sessionLockChanged(lockGeneration) }
        }
    }

#if DEBUG
    func savedInstallationForTesting() async throws -> DesktopControlInstallation? {
        let saved = try await readSavedInstallation()
        activeInstallation = saved
        return saved
    }

    static func makeForTesting(installer: any DesktopControlDriverInstalling,
                               credentials: any DesktopControlCredentialStoring,
                               executor: DesktopControlCommandExecutor? = nil,
                               proxy: CuaMCPProxy? = nil,
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
                               configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { .production },
                               ownedCuaService: CuaEmbeddedService? = nil,
                               stopCuaService: (@MainActor (CuaEmbeddedService) async -> Bool)? = nil,
                               confirmForegroundSetup: @escaping @MainActor () -> Bool = { true },
                               hostPermissions: @escaping @MainActor () -> (accessibility: Bool, screenRecording: Bool) = {
                                   (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
                               }) -> DesktopControlRuntime {
        let runtime = DesktopControlRuntime(installer: installer, credentials: credentials, relayStateReader: relayStateReader,
                                            preferences: preferences, configurationProvider: configurationProvider,
                                            confirmForegroundSetup: confirmForegroundSetup, hostPermissions: hostPermissions)
        if let executor { runtime.executor = executor }
        runtime.proxy = proxy
        runtime.gatewayConnectionID = connectionID
        runtime.activeInstallation = installation
        runtime.gatewayConnected = connected
        runtime.readiness = readiness
        runtime.paused = paused
        runtime.executorCleanupInProgress = cleanupInProgress
        runtime.executorCleanupFailed = cleanupFailed
        runtime.cuaService = ownedCuaService
        if let stopCuaService { runtime.stopCuaService = stopCuaService }
        if let sessionLockState { runtime.sessionLock.receive(sessionLockState) }
        return runtime
    }

    func handleForTesting(_ frame: DesktopControlFrame, connectionID: UUID) async -> DesktopControlFrame {
        await handle(frame, connectionID: connectionID, onChunk: { _ in })
    }

    func replaceExecutorForTesting(_ replacement: DesktopControlCommandExecutor) { executor = replacement }

    /// Recreates the daemon left by enrolled app startup before the first
    /// foreground session confirmation, without opening a gateway connection.
    func startUnconfirmedPermissionRuntimeForTesting() async throws {
        try await startPermissionCua(generation: lifecycleGeneration, remainPaused: paused)
    }

    var lockCleanupStartedForTesting: Bool { executorCleanupInProgress && readiness == "locked" }
    var executorCleanupFailedForTesting: Bool { executorCleanupFailed }

    func waitForLockCleanupForTesting() async { await lockCleanupTask?.value }
    func waitForSessionLockChangeForTesting() async { await sessionLockChangeTask?.value }
    func receiveSessionLockForTesting(_ state: DesktopControlSessionLock.State) { sessionLock.receive(state) }

    func heartbeatReadinessForTesting() async -> String? { await heartbeatReadiness() }
    var hasPendingRelayReconnectForTesting: Bool { reconnectTask != nil }
#endif

    func beginResume() throws -> UUID {
        guard !credentialAuthorizationInProgress, !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    /// App launch owns only this captured profile and lifecycle. A native Retry
    /// may replace it while the passive credential read is still pending.
    func startAtLaunch(configuration: DesktopEnvironmentConfiguration, paused: Bool) async {
        guard !Task.isCancelled, (try? configurationProvider()) == configuration,
              let generation = try? beginResume() else { return }
        preferences.set("", forKey: DesktopControlPreferenceKeys.relayError(configuration))
        preferences.set("", forKey: "desktopControlRepairError")
        do {
            if paused { try await startPaused(generation: generation) }
            else { try await resume(generation: generation) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrentLifecycle(generation), !environmentSwitchPending,
                  (try? configurationProvider()) == configuration else { return }
            preferences.set(error.localizedDescription, forKey: DesktopControlPreferenceKeys.relayError(configuration))
        }
    }

    func resume() async throws {
        try await resume(generation: beginResume())
    }

    /// Only the native menu action may request access to a saved Keychain item.
    /// Startup, page state and reconnect continue to use noninteractive reads.
    func authorizeSavedInstallation(generation: UUID) async throws {
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard !credentialAuthorizationInProgress, !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        credentialAuthorizationInProgress = true
        defer { credentialAuthorizationInProgress = false }
        let configuration = try configurationProvider()
        if let activeInstallation {
            try activeInstallation.requireEnvironment(configuration.appPageURL, configuration: configuration)
            clearCredentialAccessError(configuration: configuration)
            return
        }
        let store = credentials
        let saved = try await Task.detached(priority: .userInitiated) {
            try store.loadWithUserInteraction()
        }.value
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending,
              try configurationProvider() == configuration else { throw CancellationError() }
        try saved?.requireEnvironment(configuration.appPageURL, configuration: configuration)
        activeInstallation = saved
        clearCredentialAccessError(configuration: configuration)
    }

    private func clearCredentialAccessError(configuration: DesktopEnvironmentConfiguration) {
        let key = DesktopControlPreferenceKeys.relayError(configuration)
        let credentialErrors = [DesktopControlEnrollmentError.credentialAccessRequired.localizedDescription,
                                DesktopControlEnrollmentError.credentialStoreUnavailable.localizedDescription]
        if let message = preferences.string(forKey: key), credentialErrors.contains(message) {
            preferences.set("", forKey: key)
        }
    }

    func resume(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        setupMayRunUnconfigured = false
        guard let installation = try await savedInstallationForStartup(generation: generation) else {
            throw DesktopControlEnrollmentError.installationMissing
        }
        if await stopIfNoActiveConfiguration(installation: installation, generation: generation) { return }
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { return }
        try await startCua(forceRepairInstall: false, startPaused: false, generation: generation)
    }

    func resumeForSetup(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
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
        guard !disconnecting, !repairInProgress else { throw CancellationError() }
        if let expectedGeneration { try requireCurrentLifecycle(expectedGeneration) }
        repairInProgress = true
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    func repair(resumeRelay: Bool = false, expectedGeneration: UUID? = nil) async throws -> UUID {
        let generation = try beginRepair(expectedGeneration: expectedGeneration)
        try await repair(generation: generation, resumeRelay: resumeRelay)
        return generation
    }

    func repair(generation: UUID, resumeRelay: Bool = false) async throws {
        defer { repairInProgress = false }
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { throw CancellationError() }
        let remainPaused = paused && !resumeRelay
        await stopLocalControl(generation: generation)
        try requireCurrentLifecycle(generation)
        guard await stopOwnedCuaService() else { throw DesktopControlOwnedCuaStopError() }
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

    private func startCua(forceRepairInstall: Bool, startPaused: Bool, generation: UUID, verifyCapabilities: Bool = true) async throws {
        try requireCurrentStartup(generation)
        // A successor cannot adopt a daemon while its earlier startup still
        // owns initialization or cleanup, even if the socket already exists.
        while cuaStartup != nil || cuaShutdown != nil {
            if let previous = cuaStartup {
                previous.task.cancel()
                startingProxy?.interrupt()
                _ = await previous.task.result
                if cuaStartup?.id == previous.id { cuaStartup = nil }
                try requireCurrentStartup(generation)
            }
            if let shutdown = cuaShutdown {
                let stopped = await shutdown.task.value
                if cuaShutdown?.id == shutdown.id { cuaShutdown = nil }
                try requireCurrentStartup(generation)
                guard stopped else { throw DesktopControlOwnedCuaStopError() }
            }
        }
        let id = UUID()
        let task = Task { @MainActor in
            try await self.startOwnedCua(forceRepairInstall: forceRepairInstall, startPaused: startPaused,
                                         generation: generation, verifyCapabilities: verifyCapabilities)
        }
        cuaStartup = (id, task)
        defer { if cuaStartup?.id == id { cuaStartup = nil } }
        try await withTaskCancellationHandler {
            do { try await task.value }
            catch {
                if task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard self?.cuaStartup?.id == id else { return }
                self?.startingProxy?.interrupt()
            }
        }
    }

    private func requireCurrentStartup(_ generation: UUID) throws {
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
    }

    private func startOwnedCua(forceRepairInstall: Bool, startPaused: Bool, generation: UUID, verifyCapabilities: Bool) async throws {
        try requireCurrentStartup(generation)
        if verifyCapabilities { allowsAutomaticCuaRecovery = true }
        let wasVerifiedReady = isCuaReady() && readiness == "ready"
        if proxy == nil {
            do {
                let installation = try await installer.validateOrInstall(
                    repair: forceRepairInstall,
                    commitManagedInstall: { [weak self] installRoot, payload, replacing in
                        guard let self else { throw CancellationError() }
                        try self.requireCurrentStartup(generation)
                        guard !self.hasRunningCuaService() else { throw CuaMCPProxyError.serviceRunning }
                        if replacing { try FileManager.default.removeItem(at: installRoot) }
                        try FileManager.default.moveItem(at: payload, to: installRoot)
                    }
                )
                try requireCurrentStartup(generation)
                let service = try await launchCuaService(executableURL: installation.executableURL, generation: generation)
                selectedCuaExecutableURL = installation.executableURL
                try requireCurrentStartup(generation)
                let candidate = CuaMCPProxy(
                    executableURL: installation.executableURL,
                    socketURL: service.socketURL,
                    expectedDaemonPID: service.processIdentifier
                )
                startingProxy = candidate
                do {
                    _ = try await candidate.start()
                    try requireCurrentStartup(generation)
                    let catalog = try await candidate.listTools()
                    try requireCurrentStartup(generation)
                    let validatedTools = try await candidate.validateToolCatalog(catalog)
                    try requireCurrentStartup(generation)
                    tools = validatedTools
                    try await verifyCuaHostIdentity(candidate, generation: generation)
                    try requireCurrentStartup(generation)
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
                if !Task.isCancelled, generation == lifecycleGeneration {
                    if verifyCapabilities { await publishReadinessFailure(error, generation: generation) }
                    else { readiness = Self.readiness(for: error) }
                }
                throw error
            }
        }
        try requireCurrentStartup(generation)
        if verifyCapabilities, let proxy {
            do { try await verifyCuaReadiness(proxy, generation: generation) }
            catch {
                if !Task.isCancelled { await publishReadinessFailure(error, generation: generation) }
                throw error
            }
        }
        try requireCurrentStartup(generation)
        paused = startPaused
        readiness = startPaused ? "paused" : (sessionLock.allowsControl ? (verifyCapabilities || wasVerifiedReady ? "ready" : "permission_required") : "locked")
        // Permission-only startup never reads enrollment or activates a relay.
        if verifyCapabilities, let saved = try? await readSavedInstallation() {
            try requireCurrentStartup(generation)
            activeInstallation = saved
            await gateway?.setReadiness(readiness)
            try requireCurrentStartup(generation)
            beginReconnectLoop(for: saved)
        }
    }

    func startPaused() async throws {
        try await startPaused(generation: beginResume())
    }

    private func startPaused(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        setupMayRunUnconfigured = false
        guard let installation = try await savedInstallationForStartup(generation: generation) else {
            throw DesktopControlEnrollmentError.installationMissing
        }
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

    func shutdownForQuit() async {
        allowsAutomaticCuaRecovery = false
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        disconnecting = true
        setupMayRunUnconfigured = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        proxy?.interrupt()
        startingProxy?.interrupt()
        let pending = pendingGateway
        let current = gateway
        pendingGateway = nil
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        await pending?.stop()
        await current?.stop()
        await stopLocalControl(generation: generation)
        _ = await stopOwnedCuaService()
        activeInstallation = nil
    }

    func prepareForEnvironmentSwitch() async throws {
        guard !disconnecting || environmentSwitchPending else { throw CancellationError() }
        allowsAutomaticCuaRecovery = false
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        disconnecting = true
        environmentSwitchPending = true
        setupMayRunUnconfigured = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        proxy?.interrupt()
        startingProxy?.interrupt()
        let pending = pendingGateway
        let current = gateway
        pendingGateway = nil
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        await pending?.stop()
        await current?.stop()
        await stopLocalControl(generation: generation)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        let cuaStopped = await stopOwnedCuaService()
        await gateway?.stop()
        gateway = nil
        gatewayConnectionID = nil
        activeInstallation = nil
        guard !executorCleanupFailed, cuaStopped else {
            readiness = "cua_unavailable"
            throw DesktopControlEnvironmentSwitchError.cleanupFailed
        }
        readiness = "unknown"
    }

    func completeEnvironmentSwitch() {
        guard environmentSwitchPending else { return }
        environmentSwitchPending = false
        disconnecting = false
    }

    func abortEnvironmentSwitch() {
        guard environmentSwitchPending else { return }
        disconnecting = false
        paused = true
        if readiness == "unknown" { readiness = "cua_unavailable" }
    }

    var hasPendingEnvironmentSwitch: Bool { environmentSwitchPending }
    var isDisconnecting: Bool { disconnecting }

    func disconnect() async throws {
        let generation = try beginDisconnect()
        try await disconnect(generation: generation)
    }

    func beginDisconnect() throws -> UUID {
        guard !disconnecting else { throw CancellationError() }
        disconnecting = true
        allowsAutomaticCuaRecovery = false
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
            installation = try await readSavedInstallation()
            credentialLoadError = nil
        } catch {
            installation = nil
            credentialLoadError = error
        }
        guard disconnecting, generation == lifecycleGeneration else { return }
        activeInstallation = installation
        await stopLocalControl(generation: generation)
        guard disconnecting, generation == lifecycleGeneration else { return }
        let enrollment = DesktopControlEnrollmentClient(credentials: credentials)
        if let installation {
            do {
                try await enrollment.revokeRemote(installation: installation, appURL: LaunchConfiguration.selectedURL())
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
        let cuaStopped = await stopOwnedCuaService()
        activeInstallation = nil
        if let credentialLoadError { throw credentialLoadError }
        // Keep the installation identity after revocation. Deleting it would
        // let a later setup enroll a second identity while its config remains.
        environmentSwitchPending = false
        paused = false
        if !cuaStopped { throw DesktopControlOwnedCuaStopError() }
    }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID? = nil) async {
        guard !disconnecting, !environmentSwitchPending else { return }
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
        !environmentSwitchPending && !paused && sessionLock.allowsControl && readiness == "ready" && isCuaReady() && gatewayConnected
    }

    var nativeExecutorReady: Bool {
        !environmentSwitchPending && !paused && sessionLock.allowsControl && !executorCleanupInProgress
            && !executorCleanupFailed && !executor.nativeVerificationInProgress
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
        let permissions = hostPermissions()
        guard permissions.accessibility else {
            verifiedCuaCapabilitiesGeneration = nil
            return false
        }
        return isOwnedCuaRunning() && verifiedCuaCapabilitiesGeneration == cuaService?.generation
    }

    private func isOwnedCuaRunning() -> Bool {
        guard proxy != nil, !tools.isEmpty, let cuaService, cuaService.isRunning,
              verifiedCuaHostGeneration == cuaService.generation,
              let selectedCuaExecutableURL else { return false }
        return cuaService.executableURL.resolvingSymlinksInPath().standardizedFileURL
            == selectedCuaExecutableURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Opening the checklist cannot replace a runtime or interrupt remote work.
    /// An unlocked idle process may start its existing permission-only owner.
    func prepareCuaPermissionsAutomatically() async throws {
        try Task.checkCancellation()
        guard sessionLock.allowsControl else { throw DesktopPermissionAutomaticCheckError.sessionConfirmationRequired }
        if isOwnedCuaRunning(), let proxy, let service = cuaService {
            let generation = lifecycleGeneration
            let lock = lockGeneration
            let running = await proxy.isProcessRunning()
            try requireCurrentStartup(generation)
            guard self.proxy === proxy, cuaService === service, lockGeneration == lock,
                  sessionLock.allowsControl else { throw CancellationError() }
            if running { return }
        }
        guard canStartAutomaticPermissionRuntime else { throw DesktopPermissionAutomaticCheckError.runtimeStartRequired }
        let generation = lifecycleGeneration
        let lock = lockGeneration
        let executor = self.executor
        let id: UUID
        do { id = try await executor.beginNativeVerification() }
        catch is CancellationError { throw CancellationError() }
        catch { throw DesktopInputPermissionVerificationError.busy }
        defer { executor.endNativeVerification(id) }
        try requireCurrentStartup(generation)
        try executor.requireNativeVerification(id)
        guard self.executor === executor, lockGeneration == lock, sessionLock.allowsControl,
              canStartAutomaticPermissionRuntime else { throw CancellationError() }
        try await startPermissionCua(generation: generation, remainPaused: paused)
        try requireCurrentStartup(generation)
        try executor.requireNativeVerification(id)
        guard self.executor === executor, lockGeneration == lock, sessionLock.allowsControl else { throw CancellationError() }
    }

    private var canStartAutomaticPermissionRuntime: Bool {
        proxy == nil && cuaService == nil && cuaStartup == nil && cuaShutdown == nil && startingProxy == nil &&
        gateway == nil && pendingGateway == nil && reconnectTask == nil && gatewayConnectionID == nil &&
        !disconnecting && !environmentSwitchPending && !repairInProgress && !executorCleanupInProgress && !executorCleanupFailed
    }

    /// Explicit native setup only. It never attaches or replaces enrollment.
    func prepareCuaPermissions() async throws {
        try Task.checkCancellation()
        guard !disconnecting, !environmentSwitchPending, !repairInProgress else { throw CancellationError() }
        // A cached credential is not an active relay. Retain only existing relay recovery.
        allowsAutomaticCuaRecovery = gateway != nil || pendingGateway != nil || reconnectTask != nil
        let preflightGeneration = lifecycleGeneration
        // The running daemon proves ownership, not an unlocked session. Explicit
        // Setup must confirm even when it can reuse that daemon after app launch.
        try confirmForegroundSession()
        try requireCurrentStartup(preflightGeneration)
        let ownedDaemonRunning = isOwnedCuaRunning()
        if let existing = proxy {
            let running = await existing.isProcessRunning()
            try Task.checkCancellation()
            try requireCurrentLifecycle(preflightGeneration)
            if ownedDaemonRunning && running { return }
            verifiedCuaCapabilitiesGeneration = nil
            await existing.stop()
            try Task.checkCancellation()
            try requireCurrentLifecycle(preflightGeneration)
            guard proxy === existing else { throw CancellationError() }
            proxy = nil
            tools = []
        }
        if !ownedDaemonRunning {
            guard await stopOwnedCuaService() else { throw DesktopControlOwnedCuaStopError() }
            try Task.checkCancellation()
            try requireCurrentLifecycle(preflightGeneration)
        }
        let remainPaused = paused
        let generation = try beginResume()
        try confirmForegroundSession()
        try await startPermissionCua(generation: generation, remainPaused: remainPaused)
    }

    /// Read-only. It cannot install a runtime or request an OS permission.
    func cuaPermissionSnapshot() async throws -> CuaDriverPermissionSnapshot {
        guard let proxy, let service = cuaService, service.isRunning else { throw CuaMCPProxyError.notStarted }
        return try await readCuaPermissionSnapshot(proxy, service: service, generation: lifecycleGeneration, timeout: 5)
    }

    func restartCuaAfterPermissionChange() async throws {
        try Task.checkCancellation()
        guard !repairInProgress else { throw CancellationError() }
        // A cached credential is not an active relay. Retain only existing relay recovery.
        allowsAutomaticCuaRecovery = gateway != nil || pendingGateway != nil || reconnectTask != nil
        let remainPaused = paused
        let generation = try beginResume()
        try confirmForegroundSession()
        await stopLocalControl(generation: generation)
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard await stopOwnedCuaService() else { throw DesktopControlOwnedCuaStopError() }
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        try await startPermissionCua(generation: generation, remainPaused: remainPaused)
    }

    private func startPermissionCua(generation: UUID, remainPaused: Bool) async throws {
        do {
            try await startCua(forceRepairInstall: false, startPaused: remainPaused, generation: generation, verifyCapabilities: false)
        } catch {
            if !Task.isCancelled, !(error is CancellationError), generation == lifecycleGeneration, remainPaused {
                paused = true
                readiness = "paused"
                await gateway?.setReadiness("paused")
            }
            throw error
        }
    }

    /// Used by disclosed native checklist checks and explicit capture setup.
    func verifyCuaCapabilitiesForPermissions() async throws {
        try await verifyCuaCapabilitiesAutomatically()
    }

    func verifyCuaCapabilitiesAutomatically() async throws {
        guard sessionLock.allowsControl, isOwnedCuaRunning(), let proxy, let service = cuaService else {
            throw CuaMCPProxyError.permissionsRequired
        }
        let generation = lifecycleGeneration
        let lock = lockGeneration
        let executor = self.executor
        let id: UUID
        do { id = try await executor.beginNativeVerification() }
        catch is CancellationError { throw CancellationError() }
        catch { throw DesktopInputPermissionVerificationError.busy }
        defer { executor.endNativeVerification(id) }
        func requireCurrent() throws {
            try requireCurrentStartup(generation)
            try executor.requireNativeVerification(id)
            guard self.executor === executor, self.proxy === proxy, cuaService === service, service.isRunning,
                  sessionLock.allowsControl, lockGeneration == lock,
                  !disconnecting, !environmentSwitchPending, !repairInProgress,
                  !executorCleanupInProgress, !executorCleanupFailed else { throw CancellationError() }
            let grants = hostPermissions()
            if !grants.accessibility { verifiedCuaCapabilitiesGeneration = nil }
            guard grants.accessibility, grants.screenRecording else { throw CuaMCPProxyError.permissionsRequired }
        }
        try requireCurrent()
        try await verifyCuaReadiness(proxy, generation: generation, timeout: 15, requireScreenCapture: true,
                                    verifyOwner: requireCurrent)
        try requireCurrent()
    }

    /// Input proof is local-only and cannot share the daemon with a remote task.
    func verifyCuaInputForPermissions(target: any DesktopInputPermissionTarget) async throws {
        defer {
            target.invalidate()
            if inputPermissionTarget === target { inputPermissionTarget = nil }
        }
        guard sessionLock.allowsControl, hostPermissions().accessibility, isOwnedCuaRunning(), let proxy, let service = cuaService,
              !disconnecting, !environmentSwitchPending, !repairInProgress,
              !executorCleanupInProgress, !executorCleanupFailed else { throw CuaMCPProxyError.permissionsRequired }
        let generation = lifecycleGeneration
        let snapshot = try await readCuaPermissionSnapshot(proxy, service: service, generation: generation, timeout: 5)
        guard snapshot.hostAttributionValid, snapshot.accessibility else { throw CuaMCPProxyError.permissionsRequired }
        let lock = lockGeneration
        let executor = self.executor
        let id: UUID
        do { id = try await executor.beginNativeVerification(onInvalidation: { [weak target] in target?.invalidate() }) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DesktopInputPermissionVerificationError.busy }
        defer { executor.endNativeVerification(id) }
        inputPermissionTarget = target
        func requireCurrent() throws {
            try Task.checkCancellation()
            try requireCurrentLifecycle(generation)
            try executor.requireNativeVerification(id)
            guard self.executor === executor, self.proxy === proxy, cuaService === service,
                  service.isRunning, hostPermissions().accessibility, isOwnedCuaRunning(), sessionLock.allowsControl, lockGeneration == lock,
                  !repairInProgress, !executorCleanupInProgress, !executorCleanupFailed else { throw CancellationError() }
        }
        try requireCurrent()
        try await DesktopInputPermissionVerifier.verify(target: target, call: { name, arguments in
            try requireCurrent()
            let response = try await proxy.callTool(name: name, argumentsJSON: arguments, timeout: 5)
            try requireCurrent()
            return response
        }, isCurrent: requireCurrent)
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

    private func launchCuaService(executableURL: URL, generation: UUID) async throws -> CuaEmbeddedService {
        if let existing = cuaService {
            guard existing.isRunning,
                  existing.executableURL.resolvingSymlinksInPath() == executableURL.resolvingSymlinksInPath() else {
                throw CuaMCPProxyError.serviceMismatch
            }
            return existing
        }
        let service = CuaEmbeddedService(executableURL: executableURL)
        cuaService = service
        do {
            try await service.start { try self.requireCurrentStartup(generation) }
            try requireCurrentStartup(generation)
            guard cuaService === service else { throw CancellationError() }
            return service
        } catch {
            if cuaService === service { _ = await stopOwnedCuaService() }
            else { _ = await service.stop() }
            throw error
        }
    }

    private func hasRunningCuaService() -> Bool { cuaService != nil }

    private func beginReconnectLoop(for installation: DesktopControlInstallation) {
        guard !environmentSwitchPending, reconnectTask == nil else { return }
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
        guard !disconnecting, !environmentSwitchPending, !executorCleanupInProgress else { throw CancellationError() }
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
        inputPermissionTarget?.invalidate()
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
        guard self.lockGeneration == lockGeneration, !disconnecting else { return }
        guard allowsAutomaticCuaRecovery else {
            if proxyInterruptedForLock { readiness = paused ? "paused" : "permission_required" }
            return
        }
        guard !paused else { return }
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
        guard let installation = try? await readSavedInstallation() else { return }
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
        guard !disconnecting, !environmentSwitchPending else { return }
        let generation = lifecycleGeneration
        let configuration: DesktopEnvironmentConfiguration
        do { configuration = try configurationProvider() }
        catch { return }
        setupMayRunUnconfigured = false
        let saved: DesktopControlInstallation?
        do { saved = try await readSavedInstallation() }
        catch { return }
        guard generation == lifecycleGeneration, !disconnecting, !environmentSwitchPending else { return }
        do { try saved?.requireEnvironment(configuration.appPageURL, configuration: configuration) }
        catch { return }
        activeInstallation = saved
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
            let hasActiveConfig = try await relayStateReader.hasActiveConfig(installation: installation, appURL: LaunchConfiguration.selectedURL())
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

    private func readSavedInstallation() async throws -> DesktopControlInstallation? {
        if let activeInstallation { return activeInstallation }
        let store = credentials
        return try await Task.detached(priority: .userInitiated) { try store.load() }.value
    }

    private func savedInstallationForStartup(generation: UUID) async throws -> DesktopControlInstallation? {
        let configuration = try configurationProvider()
        let saved = try await readSavedInstallation()
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending,
              try configurationProvider() == configuration else { throw CancellationError() }
        activeInstallation = saved
        return saved
    }

    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation? {
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        let generation = lifecycleGeneration
        let configuration = try configurationProvider()
        guard (try? DesktopControlEnvironment.origin(appURL)) == configuration.appOrigin else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let saved: DesktopControlInstallation?
        do { saved = try await readSavedInstallation() }
        catch {
            guard generation == lifecycleGeneration, !disconnecting, !environmentSwitchPending,
                  try configurationProvider() == configuration else { throw CancellationError() }
            if let credentialError = error as? DesktopControlEnrollmentError,
               credentialError == .credentialAccessRequired || credentialError == .credentialStoreUnavailable {
                // An explicit authorization can finish while this passive read
                // waits for Keychain. Its valid cache supersedes the older error.
                if let activeInstallation {
                    try activeInstallation.requireEnvironment(appURL, configuration: configuration)
                    clearCredentialAccessError(configuration: configuration)
                    return activeInstallation
                }
                preferences.set(credentialError.localizedDescription,
                                forKey: DesktopControlPreferenceKeys.relayError(configuration))
            }
            throw error
        }
        guard generation == lifecycleGeneration, !disconnecting, !environmentSwitchPending,
              try configurationProvider() == configuration else { throw CancellationError() }
        try saved?.requireEnvironment(appURL, configuration: configuration)
        activeInstallation = saved
        return saved
    }

    private func hasActiveConfig(for installation: DesktopControlInstallation) async throws -> Bool {
        guard let relayStateReader else { return true }
        return try await relayStateReader.hasActiveConfig(installation: installation, appURL: LaunchConfiguration.selectedURL())
    }

    private func reconcileRelayAfterConfigRevocation(connectionID: UUID) async {
        guard gatewayConnectionID == connectionID, !disconnecting, !environmentSwitchPending,
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
        guard lifecycleGeneration == expectedLifecycle, !disconnecting, !environmentSwitchPending else { return }
        allowsAutomaticCuaRecovery = false
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
        let cuaStopped = await stopOwnedCuaService()
        guard generation == lifecycleGeneration else { return }
        if executorCleanupFailed || !cuaStopped {
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
        if let configuration = try? configurationProvider() {
            preferences.set(false, forKey: DesktopControlPreferenceKeys.relayEnabled(configuration))
            preferences.set(false, forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
        }
        paused = false
        readiness = "unknown"
    }

    private func stopOwnedCuaService() async -> Bool {
        if let shutdown = cuaShutdown { return await shutdown.task.value }
        let id = UUID()
        // Shutdown outlives cancellation of a permission check. Publish its
        // owner before yielding so startup cannot adopt a retiring daemon.
        let task = Task { @MainActor in await self.stopCurrentCuaService() }
        cuaShutdown = (id, task)
        defer { if cuaShutdown?.id == id { cuaShutdown = nil } }
        return await task.value
    }

    private func stopCurrentCuaService() async -> Bool {
        guard let service = cuaService else {
            selectedCuaExecutableURL = nil
            verifiedCuaHostGeneration = nil
            verifiedCuaCapabilitiesGeneration = nil
            return true
        }
        guard await stopCuaService(service) else { return false }
        guard cuaService === service else { return true }
        cuaService = nil
        selectedCuaExecutableURL = nil
        verifiedCuaHostGeneration = nil
        verifiedCuaCapabilitiesGeneration = nil
        return true
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
        // validateOrInstall already replaces an invalid installation. A proxy,
        // permission, or functional probe failure happened after validation;
        // reinstalling then collides with the live Cua daemon and hides the
        // original error.
        return !(error is CuaMCPProxyError)
    }

    private func handle(_ frame: DesktopControlFrame,
                        connectionID: UUID,
                        onChunk: @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame {
        guard Self.acceptsCommand(connectionID: connectionID,
                                  currentConnectionID: gatewayConnectionID,
                                  disconnecting: disconnecting || environmentSwitchPending) else {
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
        if isStatus || Self.requiresCua(frame.operation) {
            await markExitedCuaProxyUnavailable()
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
            if Self.shouldRetryGuiObservation(operation: frame.operation, readiness: readiness),
               Self.acceptsCommand(connectionID: connectionID,
                                   currentConnectionID: gatewayConnectionID,
                                   disconnecting: disconnecting),
               !paused, sessionLock.allowsControl, !executorCleanupInProgress, !executorCleanupFailed {
                let retried = await executor.handle(frame, proxy: proxy, onChunk: onChunk)
                guard sessionLock.allowsControl else {
                    return Self.failure(for: frame, code: "locked", message: "This Mac locked while the command was running. Check whether the action completed before retrying.")
                }
                return retried
            }
            if readiness == "ready" { return response }
            return Self.failure(for: frame, code: readiness, message: "Cua could not complete GUI control. Review its permissions and service status in PersonaStack Desktop.")
        }
        return response
    }

    static func shouldRetryGuiObservation(operation: String?, readiness: String) -> Bool {
        operation == "desktop_control_observe" && readiness == "ready"
    }

    private func heartbeatReadiness() async -> String? {
        await markExitedCuaProxyUnavailable()
        if Self.shouldProbeGuiRecovery(readiness: readiness, paused: paused,
                                       unlocked: sessionLock.allowsControl, cuaReady: isOwnedCuaRunning()),
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
                    if readiness == "cua_unavailable" {
                        do {
                            try await replaceFailedCuaProxy(proxy, generation: generation)
                            if generation == lifecycleGeneration, !paused, sessionLock.allowsControl {
                                readiness = "ready"
                            }
                        } catch {
                            if generation == lifecycleGeneration { readiness = Self.readiness(for: error) }
                        }
                    }
                }
            }
        }
        guard readiness == "ready" else { return readiness }
        guard isCuaReady() else {
            readiness = "cua_unavailable"
            return readiness
        }
        Self.clearRecoveredRepairError(preferences: preferences, readiness: readiness, cuaReady: true)
        return readiness
    }

    private func markExitedCuaProxyUnavailable() async {
        guard readiness == "ready", let currentProxy = proxy else { return }
        guard !(await currentProxy.isProcessRunning()), readiness == "ready", proxy === currentProxy else { return }
        verifiedCuaCapabilitiesGeneration = nil
        readiness = "cua_unavailable"
    }

    static func clearRecoveredRepairError(preferences: UserDefaults, readiness: String, cuaReady: Bool) {
        guard readiness == "ready", cuaReady else { return }
        if preferences.string(forKey: "desktopControlRepairError")?.isEmpty == false {
            preferences.set("", forKey: "desktopControlRepairError")
        }
        if preferences.string(forKey: "desktopControlLoginItemError")?
            .hasPrefix("Cua service could not be repaired:") == true {
            preferences.set("", forKey: "desktopControlLoginItemError")
        }
    }

    static func shouldProbeGuiRecovery(readiness: String, paused: Bool, unlocked: Bool, cuaReady: Bool) -> Bool {
        (readiness == "permission_required" || readiness == "cua_unavailable") && !paused && unlocked && cuaReady
    }

    private func readinessAfterGuiFailure(generation: UUID) async -> String {
        verifiedCuaCapabilitiesGeneration = nil
        guard generation == lifecycleGeneration, isOwnedCuaRunning(), let proxy else { return "cua_unavailable" }
        do {
            try await verifyCuaReadiness(proxy, generation: generation, timeout: 5)
            return generation == lifecycleGeneration
                ? Self.reconciledGuiReadiness(permissionProbeSucceeded: true, failureReadiness: "cua_unavailable")
                : readiness
        } catch {
            guard generation == lifecycleGeneration else { return readiness }
            let failureReadiness = Self.readiness(for: error)
            guard failureReadiness == "cua_unavailable" else { return failureReadiness }
            do {
                try await replaceFailedCuaProxy(proxy, generation: generation)
                return generation == lifecycleGeneration && !paused && sessionLock.allowsControl ? "ready" : readiness
            } catch {
                return generation == lifecycleGeneration ? Self.readiness(for: error) : readiness
            }
        }
    }

    private func replaceFailedCuaProxy(_ failed: CuaMCPProxy, generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard proxy === failed, startingProxy == nil, isOwnedCuaRunning(),
              let service = cuaService, let selectedCuaExecutableURL else {
            throw CuaMCPProxyError.serviceMismatch
        }
        if !(await failed.isProcessRunning()) {
            await failed.stop()
        }
        let candidate = CuaMCPProxy(
            executableURL: selectedCuaExecutableURL,
            socketURL: service.socketURL, expectedDaemonPID: service.processIdentifier
        )
        startingProxy = candidate
        do {
            _ = try await candidate.start()
            try requireCurrentLifecycle(generation)
            let catalog = try await candidate.listTools()
            try requireCurrentLifecycle(generation)
            let validatedTools = try await candidate.validateToolCatalog(catalog)
            try await verifyCuaHostIdentity(candidate, generation: generation)
            try await verifyCuaReadiness(candidate, generation: generation, timeout: 25)
            try requireCurrentLifecycle(generation)
            guard proxy === failed, startingProxy === candidate, isOwnedCuaRunning() else {
                throw CuaMCPProxyError.serviceMismatch
            }
            proxy = candidate
            tools = validatedTools
            startingProxy = nil
            await failed.stop()
        } catch {
            await candidate.stop()
            if startingProxy === candidate { startingProxy = nil }
            throw error
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
                                    timeout: Int32 = 60, requireScreenCapture: Bool = false,
                                    verifyOwner: @MainActor () throws -> Void = {}) async throws {
        try Task.checkCancellation()
        try verifyOwner()
        guard let service = cuaService else { throw CuaMCPProxyError.notStarted }
        if !requireScreenCapture { verifiedCuaCapabilitiesGeneration = nil }
        try await verifyCuaPermissions(candidate, generation: generation, timeout: timeout, requireScreenCapture: requireScreenCapture)

        try Task.checkCancellation()
        try verifyOwner()

        // Accessibility is sufficient for element actions. Checklist capture
        // checks opt in separately. All proof stays in the unlocked session.
        guard sessionLock.allowsControl else { return }
        let probeLockGeneration = lockGeneration
        if requireScreenCapture {
            let screenshot = try await candidate.callTool(
                name: "get_desktop_state", argumentsJSON: Data("{}".utf8), timeout: timeout
            )
            try Task.checkCancellation()
            try requireCurrentLifecycle(generation)
            try verifyOwner()
            guard let screenshotResult = Self.toolResult(screenshot),
                  let content = screenshotResult["content"] as? [[String: Any]],
                  content.contains(where: Self.hasCapturePixels) else {
                throw CuaMCPProxyError.functionalProbeFailed
            }
        }
        try verifyOwner()
        let accessibility = try await candidate.callTool(
            name: "get_accessibility_tree", argumentsJSON: Data("{}".utf8), timeout: timeout
        )
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        try verifyOwner()
        guard let result = Self.toolResult(accessibility),
              let content = result["content"] as? [[String: Any]],
              content.contains(where: { $0["type"] as? String == "text" && !($0["text"] as? String ?? "").isEmpty }) else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
        guard cuaService === service, service.isRunning, sessionLock.allowsControl,
              lockGeneration == probeLockGeneration else { throw CancellationError() }
        let permissions = hostPermissions()
        guard permissions.accessibility && (!requireScreenCapture || permissions.screenRecording) else { throw CuaMCPProxyError.permissionsRequired }
        verifiedCuaCapabilitiesGeneration = service.generation
    }

    private static func hasCapturePixels(_ item: [String: Any]) -> Bool {
        guard item["type"] as? String == "image", item["mimeType"] as? String == "image/png",
              let base64 = item["data"] as? String, let data = Data(base64Encoded: base64),
              let image = NSBitmapImageRep(data: data) else { return false }
        return image.pixelsWide > 0 && image.pixelsHigh > 0
    }

    private func verifyCuaPermissions(_ candidate: CuaMCPProxy, generation: UUID,
                                      timeout: Int32 = 60, requireScreenCapture: Bool = false) async throws {
        guard let service = cuaService else { throw CuaMCPProxyError.notStarted }
        let snapshot = try await readCuaPermissionSnapshot(candidate, service: service, generation: generation, timeout: timeout)
        guard snapshot.hostAttributionValid else { throw CuaMCPProxyError.serviceMismatch }
        guard snapshot.accessibility && (!requireScreenCapture || snapshot.screenRecording) else { throw CuaMCPProxyError.permissionsRequired }
    }

    private func verifyCuaHostIdentity(_ candidate: CuaMCPProxy, generation: UUID) async throws {
        guard let service = cuaService, service.isRunning else { throw CuaMCPProxyError.serviceMismatch }
        let response = try await candidate.hostIdentityReport()
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard cuaService === service, service.isRunning,
              Self.validCuaHostIdentity(response, executableURL: service.executableURL, hostPID: Darwin.getpid()) else {
            throw CuaMCPProxyError.serviceMismatch
        }
        verifiedCuaHostGeneration = service.generation
    }

    static func validCuaHostIdentity(_ response: Data, executableURL: URL, hostPID: Int32) -> Bool {
        guard let structured = toolResult(response)?["structuredContent"] as? [String: Any],
              structured["schema_version"] as? String == CuaDriverCompatibility.schemaVersion,
              structured["driver_version"] as? String == CuaDriverCompatibility.version,
              structured["platform"] as? String == "darwin",
              let checks = structured["checks"] as? [[String: Any]] else { return false }
        let identity = checks.filter { $0["name"] as? String == "bundle_identity" }
        guard identity.count == 1, identity[0]["status"] as? String == "pass",
              let data = identity[0]["data"] as? [String: Any],
              data["bundle_identifier"] as? String == CuaDriverCompatibility.hostBundleIdentifier,
              data["configured_bundle_identifier"] as? String == CuaDriverCompatibility.hostBundleIdentifier,
              data["identity_source"] as? String == "parent_application",
              data["parent_process_id"] as? Int32 == hostPID,
              let executable = data["executable_path"] as? String else { return false }
        return URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL
            == executableURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func readCuaPermissionSnapshot(_ candidate: CuaMCPProxy, service: CuaEmbeddedService, generation: UUID,
                                          timeout: Int32) async throws -> CuaDriverPermissionSnapshot {
        try Task.checkCancellation()
        guard service.isRunning, verifiedCuaHostGeneration == service.generation else { throw CuaMCPProxyError.serviceMismatch }
        do {
            let permissions = try await candidate.callTool(
                name: "check_permissions",
                argumentsJSON: CuaDriverCompatibility.permissionProbeArgumentsJSON,
                timeout: timeout
            )
            try Task.checkCancellation()
            try requireCurrentLifecycle(generation)
            guard cuaService === service, service.isRunning,
                  let structured = Self.toolResult(permissions)?["structuredContent"] as? [String: Any] else {
                throw CuaMCPProxyError.functionalProbeFailed
            }
            let snapshot = try CuaDriverPermissionSnapshot.parse(structured, daemonPID: service.processIdentifier, hostPID: Darwin.getpid(),
                verificationKey: "\(CuaDriverCompatibility.version):\(service.generation.uuidString):\(service.processIdentifier)")
            let native = hostPermissions()
            let accessibility = snapshot.accessibility && native.accessibility
            let screenRecording = snapshot.screenRecording && native.screenRecording
            if !snapshot.hostAttributionValid || !accessibility { verifiedCuaCapabilitiesGeneration = nil }
            return CuaDriverPermissionSnapshot(accessibility: accessibility, screenRecording: screenRecording,
                                               hostAttributionValid: snapshot.hostAttributionValid, verificationKey: snapshot.verificationKey)
        } catch {
            if !Task.isCancelled, cuaService === service, lifecycleGeneration == generation { verifiedCuaCapabilitiesGeneration = nil }
            throw error
        }
    }

    static func permissionProbeFailure(rpcError: Bool, toolError: Bool, hasStructured: Bool,
                                       accessibility: Bool, screenRecording: Bool) -> CuaMCPProxyError? {
        if rpcError || toolError || !hasStructured { return .functionalProbeFailed }
        if !accessibility { return .permissionsRequired }
        return nil
    }

    private static func toolResult(_ data: Data) -> [String: Any]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["error"] == nil,
              let result = response["result"] as? [String: Any],
              (result["isError"] as? Bool) != true else { return nil }
        return result
    }
}
