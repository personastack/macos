import AppKit
import Foundation
import os
import PersonaStackCore
import ServiceManagement

protocol DesktopControlDriverInstalling: Sendable {
    func discoverExisting() async throws -> CuaDriverInstallation?
    func install() async throws -> CuaDriverInstallation
    func install(progress: CuaInstallProgress) async throws -> CuaDriverInstallation
}

extension DesktopControlDriverInstalling {
    func install(progress: CuaInstallProgress) async throws -> CuaDriverInstallation {
        let installation = try await install()
        await progress(.installed)
        return installation
    }
}

extension CuaDriverInstaller: DesktopControlDriverInstalling {}

private struct DesktopControlLocalCleanupError: LocalizedError {
    var errorDescription: String? {
        "PersonaStack could not confirm that its CUA session ended. Remote control remains paused. Check CUA before reconnecting."
    }
}

enum DesktopControlEnvironmentSwitchError: LocalizedError {
    case cleanupFailed
    var errorDescription: String? {
        "PersonaStack could not finish session cleanup. Remote control remains paused. Disconnect before changing servers."
    }
}

protocol DesktopControlCuaServicing: Sendable {
    var socketURL: URL { get }
    func setup(installation: CuaDriverInstallation) async throws
    func requestPermissions(installation: CuaDriverInstallation) async throws
    func inspectPeer(installation: CuaDriverInstallation) async throws -> Int32
}
extension CuaStandaloneService: DesktopControlCuaServicing {}

struct CuaSetupBlockedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct IMessageNativeSession: Sendable {
    let installation: DesktopControlInstallation
    let configuration: DesktopEnvironmentConfiguration
    let runtime: IMessageRuntime
    let provider: IMessageSetupProvider
}

@MainActor
final class DesktopControlRuntime: DesktopControlSetupRuntime {
    static let shared = DesktopControlRuntime(
        relayStateReader: DesktopControlEnrollmentClient(),
        configurationProvider: { try LaunchConfiguration.selectedEnvironment() }
    )
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-relay")
    private let installer: any DesktopControlDriverInstalling
    private let credentials: any DesktopControlCredentialStoring
    private let relayStateReader: (any DesktopControlRelayStateReading)?
    private let preferences: UserDefaults
    private let configurationProvider: () throws -> DesktopEnvironmentConfiguration
    private let revokeInstallation: @Sendable (DesktopControlInstallation, DesktopEnvironmentConfiguration) async throws -> Void
    private var disconnectConfiguration: (generation: UUID, configuration: DesktopEnvironmentConfiguration)?
    private let sessionLock: DesktopControlSessionLock
    private let cuaService: any DesktopControlCuaServicing
    private var selectedCuaInstallation: CuaDriverInstallation?
    private var daemonPID: Int32?
    private var proxy: CuaMCPProxy?
    private var startingProxy: CuaMCPProxy?
#if DEBUG
    private var proxyFactoryForTesting: ((CuaDriverInstallation, URL, Int32) -> CuaMCPProxy)?
    private var reconnectAttemptForTesting: (() async throws -> Void)?
    private var gatewaySocketFactoryForTesting: (() -> any DesktopControlSocket)?
    private var scheduleReconnectForTesting = true
    private var beforeCuaPublicationForTesting: (() async -> Void)?
#endif
    private var cuaStartup: (id: UUID, task: Task<Void, Error>)?
    private var gateway: DesktopControlGatewayConnection?
    private var pendingGateway: DesktopControlGatewayConnection?
    private var gatewayConnectionID: UUID?
    private var gatewayAttemptID = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelayTask: Task<Void, Error>?
    private var connectionRecoveryRequested = false
    private var reconnectLoopID = UUID()
    private var activeInstallation: DesktopControlInstallation?
    private var credentialAuthorizationInProgress = false
    private var executor = DesktopControlCommandExecutor()
    private var lifecycleGeneration = UUID()
    private var sessionAvailabilityGeneration = UUID()
    // Connection intent never grants provider or workspace authorization.
    private var desktopControlSetupGeneration: UUID?
    private struct IMessageSetupRelayIntent: Equatable {
        let localGeneration: UUID
        let setupReferenceSHA256: String
        let journeyGeneration: Int64
        let expiresAt: Date
    }
    private var iMessageSetupIntent: IMessageSetupRelayIntent?
    private var iMessageSession: IMessageNativeSession?
    private var iMessageSessionGeneration = UUID()
    private var iMessageCleanupTask: Task<Void, Never>?
    private var iMessageProviderFactory: () -> IMessageSetupProvider = { IMessageSetupProvider() }
    private var iMessageAuthorizationClient = IMessageConfiguredAuthorizationClient()
    private var relayConfigurationState: DesktopControlConfigurationState?
    private var relayAuthorityReadSucceeded = false
    private var relayStateReadID = UUID()
    private var relayNow: () -> Date = Date.init
    private var disconnecting = false
    private var environmentSwitchPending = false
    private var repairInProgress = false
    private var executorCleanupInProgress = false
    private var pauseCleanupGeneration: UUID?
    private var executorCleanupTask: Task<Bool, Never>?
    private var executorCleanupFailed = false
    private var lockCleanupTask: Task<Void, Never>?
    private var sessionLockChangeTask: Task<Void, Never>?
    private var lastSuccessfulConnection: Date?
    private(set) var gatewayConnected = false
    private(set) var tools: Set<String> = []
    private(set) var paused = false
    private(set) var readiness = "unknown"
    private(set) var cuaPermissions: CuaDriverPermissionSnapshot?
    private var capabilitiesVerified = false
    private var lastCuaCheck: Date?
    private var cuaCheckFailure: String?
    private var cuaConnectionNeedsRefresh = false

    private init(installer: any DesktopControlDriverInstalling = CuaDriverInstaller(),
                 cuaService: any DesktopControlCuaServicing = CuaStandaloneService(),
                 credentials: any DesktopControlCredentialStoring = FileDesktopControlCredentialStore(),
                 relayStateReader: (any DesktopControlRelayStateReading)? = nil,
                 preferences: UserDefaults = .standard,
                 configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() },
                 revokeInstallation: (@Sendable (DesktopControlInstallation, DesktopEnvironmentConfiguration) async throws -> Void)? = nil,
                 sessionLock: DesktopControlSessionLock = DesktopControlSessionLock()) {
        self.installer = installer
        self.cuaService = cuaService
        self.credentials = credentials
        self.relayStateReader = relayStateReader
        self.preferences = preferences
        self.configurationProvider = configurationProvider
        self.revokeInstallation = revokeInstallation ?? { installation, configuration in
            try await DesktopControlEnrollmentClient(credentials: credentials).revokeRemote(installation: installation, appURL: configuration.appPageURL)
        }
        self.sessionLock = sessionLock
        Self.clearObsoleteCredentialErrors(in: preferences)
        sessionLock.onChange = { [weak self] _ in
            guard let self else { return }
            self.scheduleSessionAvailabilityCheck()
        }
        sessionLock.onRecovery = { [weak self] in
            guard let self else { return }
            self.scheduleSessionAvailabilityCheck(requestRecovery: true)
        }
        sessionLock.onLifecycleLoss = { [weak self] in self?.latchSessionAvailabilityLoss() }
    }

    var hasActiveInstallation: Bool { activeInstallation != nil }
    var hasPendingIMessageCleanup: Bool { iMessageSession != nil || iMessageCleanupTask != nil }
    var hasPendingEnvironmentSwitch: Bool { environmentSwitchPending }
    var isDisconnecting: Bool { disconnecting }
    var hasPendingControlCleanupForQuit: Bool {
        iMessageCleanupTask != nil || executorCleanupInProgress || executorCleanupFailed || !executor.permissionSetupAvailable
    }
    var permissionSetupAvailable: Bool {
        cuaSetupBlockReason == nil
    }
    var cuaSetupBlockReason: String? {
        if disconnecting { return "PersonaStack is disconnecting this Mac. Wait for it to finish, then check again." }
        if environmentSwitchPending { return "The server change needs attention. Complete it in Server Settings, then check CUA again." }
        if executorCleanupFailed { return "Remote control cleanup needs attention. Retry Stop PersonaStack Control before setting up CUA." }
        if executorCleanupInProgress { return "PersonaStack is stopping remote control. Wait for it to finish, then check again." }
        if repairInProgress || executor.nativeVerificationInProgress {
            return "Another CUA check or setup is running. Finish it or cancel it, then check again."
        }
        if !executor.permissionSetupAvailable {
            return "Remote control is active or stopping. Use Stop PersonaStack Control before setting up CUA."
        }
        return nil
    }
    var cuaSetupMessage: String {
        cuaSetupBlockReason ?? (isCuaReady() ? CuaSetupReadiness.ready.message : cuaCheckFailure)
            ?? "CUA needs attention. Choose Set Up CUA to continue."
    }
    private var controlSessionIsUsable: Bool { sessionLock.isAwakeAndActive }
    var sessionRecoveryMessage: String? {
        sessionLock.isAwakeAndActive ? nil : "Desktop Control is unavailable while this Mac is asleep or another login session is active."
    }
    func isCuaReady() -> Bool { proxy != nil && !tools.isEmpty && capabilitiesVerified }
    func isReady() -> Bool {
        !environmentSwitchPending && !paused && controlSessionIsUsable
            && !executorCleanupInProgress && !executorCleanupFailed
            && readiness == "ready" && isCuaReady() && gatewayConnected
    }

    func cuaInstalledForSetup() async throws -> Bool {
        try await installer.discoverExisting() != nil
    }

    /// A setup read may connect our idle client, but never installs, starts CUA, or prompts.
    func observeCuaForSetup() async throws -> CuaSetupReadiness {
        let generation = lifecycleGeneration
        var installed = false
        do {
            try Task.checkCancellation()
            if let reason = cuaSetupBlockReason {
                return .unavailable(installed: selectedCuaInstallation != nil, message: reason)
            }
            let discovered = try await installer.discoverExisting()
            try requireCurrentLifecycle(generation)
            try Task.checkCancellation()
            if let reason = cuaSetupBlockReason {
                return .unavailable(installed: discovered != nil, message: reason)
            }
            guard let installation = discovered else {
                capabilitiesVerified = false
                cuaPermissions = nil
                return .absent
            }
            installed = true
            try requireCurrentLifecycle(generation)
            if let reason = cuaSetupBlockReason { return .unavailable(installed: true, message: reason) }
            do { _ = try await cuaService.inspectPeer(installation: installation) }
            catch CuaMCPProxyError.notStarted {
                try requireCurrentLifecycle(generation)
                try Task.checkCancellation()
                if let reason = cuaSetupBlockReason { return .unavailable(installed: true, message: reason) }
                capabilitiesVerified = false
                cuaPermissions = nil
                return .stopped
            }
            try requireCurrentLifecycle(generation)
            if let reason = cuaSetupBlockReason { return .unavailable(installed: true, message: reason) }
            try await checkCuaConnectionForSetup()
            try requireCurrentLifecycle(generation)
            return .ready
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try requireCurrentLifecycle(generation)
            try Task.checkCancellation()
            if let reason = cuaSetupBlockReason { return .unavailable(installed: installed, message: reason) }
            if let blocked = error as? CuaSetupBlockedError {
                return .unavailable(installed: installed, message: blocked.message)
            }
            recordCuaFailure(error)
            if (error as? CuaMCPProxyError) == .permissionsRequired, let snapshot = cuaPermissions {
                return .permissions(snapshot)
            }
            return .unavailable(installed: installed, message: Self.cuaSetupFailureMessage(error))
        }
    }

    static func cuaSetupFailureMessage(_ error: Error) -> String {
        if let error = error as? CuaDriverInstallError { return error.errorDescription ?? "CUA installation failed. Try again." }
        if let error = error as? CuaStandaloneServiceError { return error.errorDescription ?? "CUA setup failed. Check again." }
        if let error = error as? CuaMCPProxyError { return error.errorDescription ?? "CUA could not be checked. Try again." }
        if let error = error as? CuaSetupBlockedError { return error.message }
        return "CUA could not complete this step. Check again or open Diagnostics for connection details."
    }

    private func requireCuaSetupAvailable() throws {
        if let reason = cuaSetupBlockReason { throw CuaSetupBlockedError(message: reason) }
    }

    /// Explicit local setup owns installation and launch. Passive relay paths never call this.
    func installCuaForSetup(progress: CuaInstallProgress = { _ in }) async throws {
        try requireCuaSetupAvailable()
        let setupExecutor = executor
        let exclusion = try await setupExecutor.beginNativeVerification()
        defer { setupExecutor.endNativeVerification(exclusion) }
        try Task.checkCancellation()
        let generation = lifecycleGeneration
        let installation = try await installer.install(progress: progress)
        try requireCurrentLifecycle(generation)
        try Task.checkCancellation()
        try setupExecutor.requireNativeVerification(exclusion)
        await progress(.starting)
        try requireCurrentLifecycle(generation)
        try Task.checkCancellation()
        try setupExecutor.requireNativeVerification(exclusion)
        try await cuaService.setup(installation: installation)
        try requireCurrentLifecycle(generation)
        selectedCuaInstallation = installation
    }

    func requestCuaPermissionsForSetup() async throws {
        try requireCuaSetupAvailable()
        let setupExecutor = executor
        let exclusion = try await setupExecutor.beginNativeVerification()
        defer { setupExecutor.endNativeVerification(exclusion) }
        try Task.checkCancellation()
        let generation = lifecycleGeneration
        guard let installation = try await installer.discoverExisting() else { throw CuaMCPProxyError.notStarted }
        try requireCurrentLifecycle(generation)
        try Task.checkCancellation()
        try setupExecutor.requireNativeVerification(exclusion)
        try await cuaService.requestPermissions(installation: installation)
        try requireCurrentLifecycle(generation)
    }

    func checkCuaConnectionForSetup() async throws {
        try requireCuaSetupAvailable()
        let setupExecutor = executor
        let exclusion = try await setupExecutor.beginNativeVerification()
        defer { setupExecutor.endNativeVerification(exclusion) }
        try Task.checkCancellation()
        let generation = lifecycleGeneration
        try await drainCuaStartup(generation: generation)
        try setupExecutor.requireNativeVerification(exclusion)
        // Setup exclusion proves that this client owns no remote lease. Refresh
        // only our idle MCP connection so an independently restarted CUA can be
        // checked before enrollment, when no relay heartbeat exists to recover it.
        let previous = proxy
        proxy = nil
        daemonPID = nil
        selectedCuaInstallation = nil
        tools = []
        capabilitiesVerified = false
        cuaPermissions = nil
        if !paused { readiness = "cua_unavailable" }
        await previous?.stop()
        try requireCurrentLifecycle(generation)
        try setupExecutor.requireNativeVerification(exclusion)
        try Task.checkCancellation()
        do {
            try await startCua(startPaused: paused, generation: generation, connectRelay: false)
        } catch {
            if generation == lifecycleGeneration, !Task.isCancelled { await gateway?.setReadiness(readiness) }
            throw error
        }
        try requireCurrentLifecycle(generation)
        await gateway?.setReadiness(readiness)
    }

    @discardableResult
    func refreshCuaReadiness() async -> Bool {
        let generation = lifecycleGeneration
        guard let proxy else {
            recordCuaFailure(CuaMCPProxyError.notStarted)
            return false
        }
        do {
            try await verifyCuaReadiness(proxy, generation: generation)
            if !paused && controlSessionIsUsable { readiness = "ready" }
            return isCuaReady()
        } catch {
            guard generation == lifecycleGeneration, !Task.isCancelled, self.proxy === proxy else { return false }
            recordCuaFailure(error)
            return false
        }
    }

    private func recordCuaFailure(_ error: Error) {
        capabilitiesVerified = false
        if (error as? CuaMCPProxyError) != .permissionsRequired { cuaPermissions = nil }
        readiness = Self.readiness(for: error)
        lastCuaCheck = Date()
        // Only our finite error types may appear in diagnostics. Never copy an
        // arbitrary transport error, path, tool response, or command content.
        cuaCheckFailure = (error as? CuaMCPProxyError)?.errorDescription
            ?? (error as? CuaDriverInstallError)?.errorDescription
            ?? "CUA could not be checked. Open Set Up CUA and try again."
        cuaConnectionNeedsRefresh = (error as? CuaMCPProxyError) != .permissionsRequired
    }

    func presentationSnapshot() -> DesktopControlPresentation {
        let configuration = try? configurationProvider()
        let enabled = configuration.map { preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled($0)) } ?? false
        let hasError = configuration.map {
            !(preferences.string(forKey: DesktopControlPreferenceKeys.relayError($0)) ?? "").isEmpty
        } ?? false
        return DesktopControlPresentation(enabled: enabled, paused: paused, connected: gatewayConnected,
                                          readiness: readiness, sessionMessage: sessionRecoveryMessage,
                                          hasError: hasError, cleanupPending: executorCleanupInProgress || pauseCleanupGeneration != nil,
                                          cleanupFailed: executorCleanupFailed,
                                          environmentSwitchPending: environmentSwitchPending,
                                          trustedConfiguration: configuration != nil,
                                          activity: executor.presentationActivity)
    }

    func beginResume() throws -> UUID {
        guard !credentialAuthorizationInProgress, !disconnecting, !environmentSwitchPending,
              pauseCleanupGeneration == nil, !executorCleanupInProgress else { throw CancellationError() }
        lifecycleGeneration = UUID()
        return lifecycleGeneration
    }

    func startAtLaunch(configuration: DesktopEnvironmentConfiguration, paused: Bool) async {
        guard !Task.isCancelled, (try? configurationProvider()) == configuration,
              let generation = try? beginResume() else { return }
        preferences.set("", forKey: DesktopControlPreferenceKeys.relayError(configuration))
        preferences.set("", forKey: "desktopControlRepairError")
        do {
            let desktopEnabled = preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(configuration))
            let iMessageOnly = !desktopEnabled && preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration))
                && !preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration))
            if paused || iMessageOnly { try await startPaused(generation: generation) }
            else { try await resume(generation: generation) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrentLifecycle(generation), !environmentSwitchPending,
                  (try? configurationProvider()) == configuration else { return }
            preferences.set(Self.connectionFailureMessage(error), forKey: DesktopControlPreferenceKeys.relayError(configuration))
        }
    }

    static func connectionFailureMessage(_ error: Error) -> String {
        // CUA readiness already owns these failures and their recovery. Saving
        // a second connection error would keep the menu failed after repair.
        if error is CuaMCPProxyError || error is CuaDriverInstallError || error is CuaStandaloneServiceError {
            return ""
        }
        return error.localizedDescription
    }

    func resume() async throws {
        try await resume(generation: beginResume())
    }

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
        let saved = try await readStoredInstallation(allowUserInteraction: true)
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
        if let message = preferences.string(forKey: key),
           credentialErrors.contains(message) || Self.isObsoleteCredentialError(message) {
            preferences.set("", forKey: key)
        }
    }

    private static func isObsoleteCredentialError(_ message: String) -> Bool {
        message.hasPrefix("Desktop Control needs Keychain access.")
            || message.hasPrefix("macOS Keychain could not access the Desktop Control installation.")
    }

    private static func clearObsoleteCredentialErrors(in preferences: UserDefaults) {
        for (key, value) in preferences.dictionaryRepresentation() {
            guard key == "desktopControlRelayError" || key.hasPrefix("desktopControlRelayError.")
                    || key == "desktopControlRepairError",
                  let message = value as? String, isObsoleteCredentialError(message) else { continue }
            preferences.set("", forKey: key)
        }
    }

    func resume(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        desktopControlSetupGeneration = nil
        guard let installation = try await savedInstallationForStartup(generation: generation) else {
            throw DesktopControlEnrollmentError.installationMissing
        }
        if await stopIfNoActiveConfiguration(installation: installation, generation: generation) { return }
        try requireCurrentLifecycle(generation)
        guard !disconnecting else { return }
        paused = false
        if desktopControlStartupIntended {
            try await startCua(startPaused: false, generation: generation)
        } else {
            await stopInactiveDesktopControl(generation: generation)
            try requireCurrentLifecycle(generation)
            await connect(installation: installation, expectedGeneration: generation)
        }
    }

    func resumeForSetup(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        guard sessionLock.isAwakeAndActive else { throw CancellationError() }
        try requireCurrentLifecycle(generation)
        desktopControlSetupGeneration = generation
        try await startCua(startPaused: false, generation: generation)
    }

    /// Construction creates no provider process or permission request.
    func iMessageSetupSession() async throws -> IMessageNativeSession {
        let availability = sessionAvailabilityGeneration
        let configuration = try configurationProvider()
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        guard let installation = try await readStoredInstallation() else { throw DesktopControlEnrollmentError.installationMissing }
        try Task.checkCancellation()
        guard availability == sessionAvailabilityGeneration, configuration == (try configurationProvider()),
              !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        return try await iMessageSession(for: installation, configuration: configuration)
    }

    private func iMessageSession(for installation: DesktopControlInstallation,
                                configuration: DesktopEnvironmentConfiguration) async throws -> IMessageNativeSession {
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        let availability = sessionAvailabilityGeneration
        await sessionLockChangeTask?.value
        try Task.checkCancellation()
        guard availability == sessionAvailabilityGeneration, sessionLock.isAwakeAndActive else { throw CancellationError() }
        let expectedCleanup = iMessageSessionGeneration
        await iMessageCleanupTask?.value
        try Task.checkCancellation()
        guard expectedCleanup == iMessageSessionGeneration, availability == sessionAvailabilityGeneration,
              sessionLock.isAwakeAndActive else { throw CancellationError() }
        if let session = iMessageSession, session.installation == installation, session.configuration == configuration { return session }
        let expected = await retireIMessageSession()
        try Task.checkCancellation()
        guard !disconnecting, !environmentSwitchPending, configuration == (try configurationProvider()) else { throw CancellationError() }
        let provider = iMessageProviderFactory()
        let runtime = IMessageRuntime(installationID: installation.installationID, provider: provider,
            referenceDigest: IMessageSetupProvider.setupReferenceDigest, textDigest: IMessageSetupProvider.messageTextDigest,
            authorizeConfigured: { [weak self, provider] command, connectionID, deadline in
                guard let self else { throw IMessageConfiguredAuthorizationError.unavailable }
                return try await self.authorizeConfiguredIMessage(command, connectionID: connectionID, provider: provider,
                    installation: installation, configuration: configuration, deadline: deadline)
            })
        await runtime.setConfiguredPolicy(enabled: configuredIMessageEnabled(configuration))
        await runtime.setExecutionAvailable(sessionLock.isAwakeAndActive)
        guard expected == iMessageSessionGeneration, availability == sessionAvailabilityGeneration,
              sessionLock.isAwakeAndActive else { await runtime.drain(); throw CancellationError() }
        let session = IMessageNativeSession(installation: installation, configuration: configuration, runtime: runtime, provider: provider)
        iMessageSession = session
        return session
    }

    /// A failed or canceled replacement can keep using the same shared socket.
    /// The actor remains bound, but no setup consent or snapshot survives.
    func suspendIMessageForReplacement() async {
        await sessionLockChangeTask?.value
        iMessageSetupIntent = nil
        iMessageSessionGeneration = UUID()
        let id = iMessageSessionGeneration
        let previous = iMessageCleanupTask, session = iMessageSession
        let task = Task {
            await previous?.value
            await session?.runtime.suspendAndDrain()
        }
        iMessageCleanupTask = task
        await task.value
        if iMessageSessionGeneration == id { iMessageCleanupTask = nil }
    }

    func drainIMessage() async {
        _ = await retireIMessageSession()
    }

    private func retireIMessageSession() async -> UUID {
        await sessionLockChangeTask?.value
        iMessageSessionGeneration = UUID()
        let previous = iMessageCleanupTask, session = iMessageSession
        iMessageSession = nil
        let id = iMessageSessionGeneration
        let task = Task {
            await previous?.value
            await session?.runtime.drain()
        }
        iMessageCleanupTask = task
        await task.value
        if iMessageSessionGeneration == id { iMessageCleanupTask = nil }
        return id
    }

    private func configuredIMessageEnabled(_ configuration: DesktopEnvironmentConfiguration) -> Bool {
        preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration))
            && !preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration))
    }
    private func authorizeConfiguredIMessage(_ command: IMessageGatewayCommand, connectionID: UUID, provider: IMessageSetupProvider,
                                            installation: DesktopControlInstallation, configuration: DesktopEnvironmentConfiguration,
                                            deadline: Date) async throws -> IMessageGatewaySnapshot {
        let digest: String?
        if case .configured(.sendMessage(let input)) = command.input { digest = IMessageSetupProvider.messageTextDigest(input.text) }
        else { digest = nil }
        return try await iMessageAuthorizationClient.authorize(command, installation: installation, configuration: configuration,
            deadline: deadline, humanTextSHA256: digest, validateCurrent: { [weak self, provider] in
                guard let self else { throw CancellationError() }
                try await self.requireConfiguredIMessageContext(connectionID: connectionID, provider: provider,
                    installation: installation, configuration: configuration)
            })
    }
    private func requireConfiguredIMessageContext(connectionID: UUID, provider: IMessageSetupProvider,
                                                 installation: DesktopControlInstallation, configuration: DesktopEnvironmentConfiguration) async throws {
        try Task.checkCancellation()
        guard !disconnecting, !environmentSwitchPending, sessionLock.isAwakeAndActive, configuredIMessageEnabled(configuration),
              (try configurationProvider()) == configuration, iMessageSession?.provider === provider,
              iMessageSession?.installation == installation, let connection = pendingGateway ?? gateway else { throw CancellationError() }
        guard await connection.hasIMessageBinding(connectionID), !Task.isCancelled,
              (pendingGateway === connection || gateway === connection), iMessageSession?.provider === provider,
              sessionLock.isAwakeAndActive, configuredIMessageEnabled(configuration) else { throw CancellationError() }
    }
    private func reconcileIMessageExecutionAvailability() async {
        await iMessageSession?.runtime.setExecutionAvailable(sessionLock.isAwakeAndActive)
    }

    func refreshIMessageRelayPreference() async {
        guard let configuration = try? configurationProvider(), !disconnecting, !environmentSwitchPending else { return }
        let enabled = preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration))
        let paused = preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration))
        await iMessageSession?.runtime.setConfiguredPolicy(enabled: enabled && !paused)
        if !enabled || paused {
            iMessageSetupIntent = nil
            await iMessageSession?.runtime.suspendAndDrain()
        }
        try? await reconcileRelayIntent(generation: lifecycleGeneration)
    }

    func resumeIMessageSetupRelay(for intent: IMessageRuntimeSetupIntent) async throws -> UUID {
        let generation = lifecycleGeneration
        try await resumeForIMessageSetup(generation: generation, setupReferenceSHA256: intent.scope.setupReferenceSHA256,
            journeyGeneration: intent.scope.generation, expiresAt: IMessageGatewayWire.utcDate(intent.scope.expiresAt))
        return generation
    }

    func finishIMessageSetupRelay(for intent: IMessageRuntimeSetupIntent, generation: UUID) async {
        guard let expiry = try? IMessageGatewayWire.utcDate(intent.scope.expiresAt) else { return }
        if let configuration = try? configurationProvider() {
            await iMessageSession?.runtime.setConfiguredPolicy(enabled: configuredIMessageEnabled(configuration))
        }
        try? await finishIMessageSetupIfIdle(generation: generation, setupReferenceSHA256: intent.scope.setupReferenceSHA256,
            journeyGeneration: intent.scope.generation, expiresAt: expiry)
    }

    /// Only the authenticated native coordinator may supply the API journey receipt.
    /// This intent keeps setup metadata transport alive. It grants no provider access.
    func resumeForIMessageSetup(generation: UUID, setupReferenceSHA256: String,
                               journeyGeneration: Int64, expiresAt: Date) async throws {
        try requireCurrentLifecycle(generation)
        let now = relayNow()
        guard !disconnecting, !environmentSwitchPending, sessionLock.isAwakeAndActive,
              Self.isCanonicalSetupReferenceDigest(setupReferenceSHA256), journeyGeneration > 0,
              expiresAt > now, expiresAt.timeIntervalSince(now) <= 24 * 60 * 60 else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        if let current = iMessageSetupIntent, current.setupReferenceSHA256 == setupReferenceSHA256 {
            guard expiresAt == current.expiresAt, journeyGeneration >= current.journeyGeneration else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
        }
        guard let installation = try await savedInstallationForStartup(generation: generation) else {
            throw DesktopControlEnrollmentError.installationMissing
        }
        try requireCurrentLifecycle(generation)
        let configuration = try configurationProvider()
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        guard expiresAt > relayNow() else { throw DesktopControlEnrollmentError.invalidRequest }
        if let current = iMessageSetupIntent, current.setupReferenceSHA256 == setupReferenceSHA256 {
            guard expiresAt == current.expiresAt, journeyGeneration >= current.journeyGeneration else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
        }
        iMessageSetupIntent = IMessageSetupRelayIntent(localGeneration: generation,
            setupReferenceSHA256: setupReferenceSHA256, journeyGeneration: journeyGeneration, expiresAt: expiresAt)
        // Do not touch CUA, Desktop Control pause, or another family's setup intent.
        await connect(installation: installation, expectedGeneration: generation)
    }

    func finishIMessageSetupIfIdle(generation: UUID, setupReferenceSHA256: String,
                                  journeyGeneration: Int64, expiresAt: Date) async throws {
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        let receipt = IMessageSetupRelayIntent(localGeneration: generation,
            setupReferenceSHA256: setupReferenceSHA256, journeyGeneration: journeyGeneration, expiresAt: expiresAt)
        guard iMessageSetupIntent == receipt else { return }
        iMessageSetupIntent = nil
        // A Desktop Control pause/resume may have advanced the shared lifecycle.
        // The exact iMessage receipt fences release independently of that family.
        try await reconcileRelayIntent(generation: lifecycleGeneration)
    }

    private static func isCanonicalSetupReferenceDigest(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="), data.count == 32 else { return false }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }

    private var desktopControlConnectionIntended: Bool {
        desktopControlSetupGeneration != nil || relayConfigurationState?.hasActiveConfig == true
            || relayStateReader == nil || (relayConfigurationState == nil && (proxy != nil || startingProxy != nil))
    }

    private var desktopControlStartupIntended: Bool {
        desktopControlSetupGeneration != nil || relayStateReader == nil
            || (relayAuthorityReadSucceeded && relayConfigurationState?.hasActiveConfig == true)
    }

    private var temporaryRelayConnectionIntended: Bool {
        desktopControlSetupGeneration != nil || iMessageSetupIntent.map { $0.expiresAt > relayNow() } == true
    }

    private var relayConnectionIntended: Bool {
        temporaryRelayConnectionIntended || relayConfigurationState.map(hasActiveRelayCapability) == true
    }

    private func hasActiveRelayCapability(_ state: DesktopControlConfigurationState) -> Bool {
        guard let configuration = try? configurationProvider() else { return state.hasActiveConfig }
        return DesktopRelayStartupPolicy.shouldStart(desktopControlEnabled: state.hasActiveConfig, desktopControlPaused: false,
            imessageEnabled: state.hasActiveIMessageConfig && preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)),
            imessagePaused: preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration)))
    }

    func beginRepair(expectedGeneration: UUID? = nil) throws -> UUID {
        guard !disconnecting, !repairInProgress, pauseCleanupGeneration == nil else { throw CancellationError() }
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

    func startPaused() async throws {
        try await startPaused(generation: beginResume())
    }

    private func startPaused(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        desktopControlSetupGeneration = nil
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
        guard !disconnecting, pauseCleanupGeneration == nil else { return nil }
        lifecycleGeneration = UUID()
        paused = true
        readiness = "paused"
        pauseCleanupGeneration = lifecycleGeneration
        return lifecycleGeneration
    }

    func pause(generation: UUID) async {
        defer { if pauseCleanupGeneration == generation { pauseCleanupGeneration = nil } }
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
        guard generation == lifecycleGeneration, !executorCleanupFailed else { return }
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
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        disconnecting = true
        desktopControlSetupGeneration = nil
        iMessageSetupIntent = nil
        relayConfigurationState = nil
        relayAuthorityReadSucceeded = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        let pending = pendingGateway
        let current = gateway
        pendingGateway = nil
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        await pending?.stopAndDrainIMessage()
        await current?.stopAndDrainIMessage()
        await drainIMessage()
        await stopLocalControl(generation: generation)
        activeInstallation = nil
        // A refused Quit leaves the app available for an explicit cleanup retry.
        if executorCleanupFailed { disconnecting = false }
    }

    func prepareForEnvironmentSwitch() async throws {
        guard !disconnecting || environmentSwitchPending else { throw CancellationError() }
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        disconnecting = true
        environmentSwitchPending = true
        lastSuccessfulConnection = nil
        desktopControlSetupGeneration = nil
        iMessageSetupIntent = nil
        relayConfigurationState = nil
        relayAuthorityReadSucceeded = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        let pending = pendingGateway
        let current = gateway
        pendingGateway = nil
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        await pending?.stopAndDrainIMessage()
        await current?.stopAndDrainIMessage()
        await drainIMessage()
        await stopLocalControl(generation: generation)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        await gateway?.stopAndDrainIMessage()
        gateway = nil
        gatewayConnectionID = nil
        activeInstallation = nil
        guard !executorCleanupFailed else {
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

    func disconnect() async throws {
        let generation = try beginDisconnect()
        try await disconnect(generation: generation)
    }

    func beginDisconnect() throws -> UUID {
        guard !disconnecting else { throw CancellationError() }
        let configuration = try configurationProvider()
        try activeInstallation?.requireEnvironment(configuration.appPageURL, configuration: configuration)
        disconnecting = true
        lifecycleGeneration = UUID()
        disconnectConfiguration = (lifecycleGeneration, configuration)
        // Machine revocation affects both families. Persist the local fence
        // before suspension so a failed response cannot trigger crash recovery.
        preferences.set(true, forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
        preferences.set(true, forKey: IMessagePreferenceKeys.relayPaused(configuration))
        desktopControlSetupGeneration = nil
        iMessageSetupIntent = nil
        relayConfigurationState = nil
        relayAuthorityReadSucceeded = false
        paused = true
        readiness = "paused"
        return lifecycleGeneration
    }

    func disconnect(generation: UUID) async throws {
        guard disconnecting, generation == lifecycleGeneration,
              let receipt = disconnectConfiguration, receipt.generation == generation else { throw CancellationError() }
        let configuration = receipt.configuration
        defer {
            if generation == lifecycleGeneration { disconnecting = false; disconnectConfiguration = nil }
        }
        await drainIMessage()
        guard disconnecting, generation == lifecycleGeneration else { throw CancellationError() }
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
        await pendingConnection?.stopAndDrainIMessage()
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
        guard !executorCleanupFailed else {
            readiness = "cua_unavailable"
            await gateway?.setReadiness(readiness)
            throw DesktopControlLocalCleanupError()
        }
        if let installation {
            try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
            try await revokeInstallation(installation, configuration)
            guard disconnecting, generation == lifecycleGeneration else { throw CancellationError() }
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        await gateway?.stopAndDrainIMessage()
        gateway = nil
        gatewayConnectionID = nil
        gatewayConnected = false
        activeInstallation = nil
        if let credentialLoadError { throw credentialLoadError }
        // Keep the installation identity after revocation. Deleting it would
        // let a later setup enroll a second identity while its config remains.
        preferences.set(false, forKey: DesktopControlPreferenceKeys.relayEnabled(configuration))
        preferences.set(false, forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
        preferences.set(false, forKey: IMessagePreferenceKeys.relayEnabled(configuration))
        preferences.set(false, forKey: IMessagePreferenceKeys.relayPaused(configuration))
        environmentSwitchPending = false
        paused = false
    }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID? = nil) async {
        guard !disconnecting, !environmentSwitchPending, sessionLock.isAwakeAndActive else { return }
        let generation = lifecycleGeneration
        guard expectedGeneration == nil || expectedGeneration == generation else { return }
        let sameInstallation = activeInstallation == installation
        activeInstallation = installation
        let socketConnected = await gateway?.isConnected() == true
        let alreadyConnected = sameInstallation && socketConnected
        guard generation == lifecycleGeneration, !disconnecting else { return }
        if alreadyConnected {
            let expectedIMessageSession = iMessageSessionGeneration
            let currentActor = try? await gatewayUsesCurrentIMessageSession(installation)
            guard generation == lifecycleGeneration, !disconnecting else { return }
            if currentActor == true, expectedIMessageSession == iMessageSessionGeneration {
                beginReconnectLoop(for: installation)
                return
            }
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

    private func gatewayUsesCurrentIMessageSession(_ installation: DesktopControlInstallation) async throws -> Bool {
        let session = try await iMessageSession(for: installation, configuration: configurationProvider())
        return await gateway?.usesIMessageRuntime(session.runtime) == true
    }

    private func requestConnectionRecovery() {
        guard reconnectTask != nil, !disconnecting, !environmentSwitchPending else { return }
        connectionRecoveryRequested = true
        reconnectDelayTask?.cancel()
    }

    private func beginReconnectLoop(for installation: DesktopControlInstallation) {
#if DEBUG
        guard scheduleReconnectForTesting else { return }
#endif
        guard !environmentSwitchPending, reconnectTask == nil else { return }
        activeInstallation = installation
        let loopID = UUID()
        reconnectLoopID = loopID
        reconnectTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.reconnectLoopID == loopID {
                    self.reconnectTask = nil
                    self.reconnectDelayTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                if self.connectionRecoveryRequested {
                    self.connectionRecoveryRequested = false
                    await self.gateway?.checkConnectionAfterRecovery()
                }
                guard !Task.isCancelled, self.reconnectLoopID == loopID else { return }
                guard await self.reconnectIfNeeded(installation, loopID: loopID) else { return }
                guard !Task.isCancelled else { return }
                if self.connectionRecoveryRequested { continue }
                let delay = Task { try await Task.sleep(for: .seconds(5)) }
                self.reconnectDelayTask = delay
                await withTaskCancellationHandler {
                    _ = try? await delay.value
                } onCancel: { delay.cancel() }
                guard self.reconnectLoopID == loopID else { return }
                self.reconnectDelayTask = nil
            }
        }
    }

    private func reconnectIfNeeded(_ installation: DesktopControlInstallation, loopID: UUID) async -> Bool {
        await sessionLockChangeTask?.value
        guard sessionLock.isAwakeAndActive else { return true }
        let connected = await gateway?.isConnected() ?? false
        guard !Task.isCancelled, reconnectLoopID == loopID, !disconnecting else { return false }
        let generation = lifecycleGeneration
        do {
            _ = try await refreshRelayConfiguration(installation: installation, generation: generation)
            guard !Task.isCancelled, reconnectLoopID == loopID, !disconnecting else { return false }
            guard generation == lifecycleGeneration else { return true }
            if !relayConnectionIntended {
                try? await stopIdleRelay(expectedLifecycle: generation)
                return false
            }
            if !desktopControlConnectionIntended {
                await stopInactiveDesktopControl(generation: generation)
            }
        } catch {
            // Authority failure preserves the shared socket and retries. It cannot start CUA.
            _ = temporaryRelayConnectionIntended
        }
        if connected { return true }
        guard !Task.isCancelled, reconnectLoopID == loopID, !disconnecting else { return false }
        guard generation == lifecycleGeneration else { return true }
        do {
            try await establishConnection(installation, generation: generation)
        } catch {
            guard generation == lifecycleGeneration else { return true }
            let failure = error as NSError
            logger.error("gateway reconnect failed: \(failure.domain, privacy: .public) code \(failure.code, privacy: .public)")
            if Self.readiness(for: error) == "upgrade_required" { readiness = "upgrade_required" }
        }
        return true
    }

    private func establishConnection(_ installation: DesktopControlInstallation, generation: UUID) async throws {
        await sessionLockChangeTask?.value
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending, !executorCleanupInProgress, sessionLock.isAwakeAndActive else { throw CancellationError() }
#if DEBUG
        if let reconnectAttemptForTesting { try await reconnectAttemptForTesting(); return }
#endif
        guard paused || isCuaReady() || readiness != "ready" else { throw CuaMCPProxyError.notStarted }
        let attemptID = UUID()
        gatewayAttemptID = attemptID
        if let pendingGateway {
            self.pendingGateway = nil
            gatewayConnectionID = nil
            await pendingGateway.stopAndDrainIMessage()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        }
        if let gateway {
            self.gateway = nil
            gatewayConnectionID = nil
            gatewayConnected = false
            await gateway.stopAndDrainIMessage()
            await cleanupExecutor()
            try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        }
        let session = try await iMessageSession(for: installation, configuration: configurationProvider())
        try requireCurrentConnectionAttempt(generation, attemptID: attemptID)
        let connectionID = UUID()
        var socketOverride: (any DesktopControlSocket)? = nil
#if DEBUG
        socketOverride = gatewaySocketFactoryForTesting?()
#endif
        let connection = DesktopControlGatewayConnection(
            installation: installation,
            socket: socketOverride,
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
            iMessageRuntime: session.runtime,
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
            lastSuccessfulConnection = Date()
        } catch {
            if pendingGateway === connection { pendingGateway = nil }
            if gatewayConnectionID == connectionID { gatewayConnectionID = nil }
            if generation == lifecycleGeneration, gatewayAttemptID == attemptID { gatewayConnected = false }
            await connection.stopAndDrainIMessage()
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
        requestConnectionRecovery()
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

    func finishSetupIfIdle() async throws {
        try Task.checkCancellation()
        guard !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        let generation = lifecycleGeneration
        let configuration = try configurationProvider()
        desktopControlSetupGeneration = nil
        let saved = try await readSavedInstallation()
        try Task.checkCancellation()
        guard generation == lifecycleGeneration, !disconnecting, !environmentSwitchPending,
              try configurationProvider() == configuration else { throw CancellationError() }
        try saved?.requireEnvironment(configuration.appPageURL, configuration: configuration)
        activeInstallation = saved
        guard let installation = saved else {
            try await stopIdleRelay(expectedLifecycle: generation)
            return
        }
        let state = try await refreshRelayConfiguration(installation: installation, generation: generation)
        try Task.checkCancellation()
        guard generation == lifecycleGeneration, !disconnecting, !environmentSwitchPending,
              try configurationProvider() == configuration else { throw CancellationError() }
        if !hasActiveRelayCapability(state) && !temporaryRelayConnectionIntended {
            try await stopIdleRelay(expectedLifecycle: generation)
        } else if !desktopControlConnectionIntended {
            await stopInactiveDesktopControl(generation: generation)
        }
    }

    private func stopIfNoActiveConfiguration(installation: DesktopControlInstallation, generation: UUID) async -> Bool {
        do {
            let state = try await refreshRelayConfiguration(installation: installation, generation: generation)
            guard generation == lifecycleGeneration else { return false }
            if !hasActiveRelayCapability(state) && !temporaryRelayConnectionIntended {
                try? await stopIdleRelay(expectedLifecycle: generation)
                return true
            }
        } catch {
            // A failed read must not stop a relay another workspace may still use.
        }
        return false
    }

    private func readSavedInstallation() async throws -> DesktopControlInstallation? {
        if let activeInstallation { return activeInstallation }
        return try await readStoredInstallation()
    }

    private func readStoredInstallation(allowUserInteraction: Bool = false) async throws -> DesktopControlInstallation? {
        let store = credentials
        // Legacy Keychain authorization and its serialized interaction gate can
        // block. Keep that work off Swift's cooperative task executor so page
        // reads cannot prevent the native authorization owner from progressing.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    if allowUserInteraction { return try store.loadWithUserInteraction() }
                    return try store.load()
                })
            }
        }
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

    @discardableResult
    private func refreshRelayConfiguration(installation: DesktopControlInstallation,
                                           generation: UUID) async throws -> DesktopControlConfigurationState {
        let configuration = try configurationProvider()
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        let readID = UUID()
        relayStateReadID = readID
        let state: DesktopControlConfigurationState
        if let relayStateReader {
            do {
                state = try await relayStateReader.configurationState(installation: installation, appURL: configuration.appPageURL)
            } catch {
                if generation == lifecycleGeneration, relayStateReadID == readID { relayAuthorityReadSucceeded = false }
                throw error
            }
        } else {
            state = .init(hasActiveConfig: true, hasConfig: true)
        }
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard !disconnecting, !environmentSwitchPending, relayStateReadID == readID,
              try configurationProvider() == configuration,
              activeInstallation == installation else { throw CancellationError() }
        relayConfigurationState = state
        relayAuthorityReadSucceeded = true
        return state
    }

    private func reconcileRelayIntent(generation: UUID) async throws {
        guard let installation = activeInstallation else {
            if !temporaryRelayConnectionIntended { try await stopIdleRelay(expectedLifecycle: generation) }
            return
        }
        _ = try await refreshRelayConfiguration(installation: installation, generation: generation)
        if !relayConnectionIntended { try await stopIdleRelay(expectedLifecycle: generation) }
        else if !desktopControlConnectionIntended { await stopInactiveDesktopControl(generation: generation) }
    }

    private func stopInactiveDesktopControl(generation: UUID) async {
        guard generation == lifecycleGeneration, !desktopControlConnectionIntended else { return }
        let wasPaused = paused
        if cuaStartup != nil { try? await drainCuaStartup(generation: generation) }
        guard generation == lifecycleGeneration, !desktopControlConnectionIntended else { return }
        if proxy != nil || startingProxy != nil || executor.currentLease != nil || executor.needsSessionCleanup {
            await stopLocalControl(generation: generation)
        }
        guard generation == lifecycleGeneration else { return }
        paused = wasPaused
        capabilitiesVerified = false
        readiness = executorCleanupFailed ? "cua_unavailable" : (wasPaused ? "paused" : "unknown")
        await gateway?.setReadiness(readiness)
    }

    private func reconcileRelayAfterConfigRevocation(connectionID: UUID) async {
        guard gatewayConnectionID == connectionID, !disconnecting, !environmentSwitchPending else { return }
        let generation = lifecycleGeneration
        do { try await reconcileRelayIntent(generation: generation) }
        catch {
            // A failed read must not stop a relay another workspace may still use.
        }
    }

    private func stopIdleRelay(expectedLifecycle: UUID) async throws {
        guard lifecycleGeneration == expectedLifecycle, !disconnecting, !environmentSwitchPending else { throw CancellationError() }
        lifecycleGeneration = UUID()
        let generation = lifecycleGeneration
        desktopControlSetupGeneration = nil
        iMessageSetupIntent = nil
        relayConfigurationState = nil
        relayAuthorityReadSucceeded = false
        reconnectTask?.cancel()
        reconnectTask = nil
        gatewayAttemptID = UUID()
        paused = true
        readiness = "paused"
        let pending = pendingGateway
        pendingGateway = nil
        await pending?.stopAndDrainIMessage()
        guard generation == lifecycleGeneration else { throw CancellationError() }
        await stopLocalControl(generation: generation)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        if executorCleanupFailed {
            readiness = "cua_unavailable"
            await gateway?.setReadiness(readiness)
            if let installation = activeInstallation, gateway != nil { beginReconnectLoop(for: installation) }
            throw DesktopControlLocalCleanupError()
        }
        await gateway?.stopAndDrainIMessage()
        guard generation == lifecycleGeneration else { throw CancellationError() }
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
        try Task.checkCancellation()
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

    nonisolated private static func failure(for frame: DesktopControlFrame, code: String, message: String = "The desktop command is not available.") -> DesktopControlFrame {
        DesktopControlFrame(version: 1, type: "failure", requestID: frame.requestID, errorCode: code, errorMessage: message)
    }

    static func acceptsCommand(connectionID: UUID, currentConnectionID: UUID?, disconnecting: Bool) -> Bool {
        !disconnecting && currentConnectionID == connectionID
    }

    static func requiresCua(_ operation: String?) -> Bool {
        switch operation {
        case "desktop_control_observe", "desktop_control_input", "desktop_control_application",
             "desktop_control_window", "desktop_control_clipboard", "desktop_control_browser", "desktop_control_cua":
            return true
        default:
            return false
        }
    }

    private static func toolResult(_ data: Data) -> [String: Any]? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["error"] == nil,
              let result = response["result"] as? [String: Any],
              (result["isError"] as? Bool) != true else { return nil }
        return result
    }

    func repair(generation: UUID, resumeRelay: Bool = false) async throws {
        defer { repairInProgress = false }
        try requireCurrentLifecycle(generation)
        let remainPaused = paused && !resumeRelay
        await stopLocalControl(generation: generation)
        try requireCurrentLifecycle(generation)
        guard !executorCleanupFailed else { throw DesktopControlLocalCleanupError() }
        try await startCua(startPaused: remainPaused, generation: generation)
    }

    private func drainCuaStartup(generation: UUID) async throws {
        try requireCurrentLifecycle(generation)
        while let previous = cuaStartup {
            previous.task.cancel()
            startingProxy?.interrupt()
            _ = await previous.task.result
            if cuaStartup?.id == previous.id { cuaStartup = nil }
            try requireCurrentLifecycle(generation)
            try Task.checkCancellation()
        }
    }

    private func startCua(startPaused: Bool, generation: UUID, connectRelay: Bool = true) async throws {
        try requireCurrentLifecycle(generation)
        guard !connectRelay || !executor.nativeVerificationInProgress else { throw CuaMCPProxyError.serviceRunning }
        try await drainCuaStartup(generation: generation)
        guard !connectRelay || !executor.nativeVerificationInProgress else { throw CuaMCPProxyError.serviceRunning }
        let id = UUID()
        let task = Task { @MainActor in
            try await self.connectCua(startPaused: startPaused, generation: generation, connectRelay: connectRelay)
        }
        cuaStartup = (id, task)
        defer { if cuaStartup?.id == id { cuaStartup = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func makeCuaProxy(installation: CuaDriverInstallation, pid: Int32) -> CuaMCPProxy {
#if DEBUG
        if let factory = proxyFactoryForTesting { return factory(installation, cuaService.socketURL, pid) }
#endif
        return CuaMCPProxy(executableURL: installation.executableURL,
                           socketURL: cuaService.socketURL, expectedDaemonPID: pid)
    }

    private func connectCua(startPaused: Bool, generation: UUID, connectRelay: Bool) async throws {
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard !executorCleanupFailed else { throw DesktopControlLocalCleanupError() }
        do {
            if proxy == nil {
                guard let installation = try await installer.discoverExisting() else { throw CuaMCPProxyError.notStarted }
                try requireCurrentLifecycle(generation)
                let pid = try await cuaService.inspectPeer(installation: installation)
                try requireCurrentLifecycle(generation)
                let candidate = makeCuaProxy(installation: installation, pid: pid)
                startingProxy = candidate
                do {
                    _ = try await candidate.start()
                    try Task.checkCancellation()
                    try requireCurrentLifecycle(generation)
                    let catalog = try await candidate.listTools()
                    let validatedTools = try await candidate.validateToolCatalog(catalog)
#if DEBUG
                    if let barrier = beforeCuaPublicationForTesting {
                        beforeCuaPublicationForTesting = nil
                        await barrier()
                    }
#endif
                    try Task.checkCancellation()
                    try requireCurrentLifecycle(generation)
                    selectedCuaInstallation = installation
                    daemonPID = pid
                    tools = validatedTools
                    proxy = candidate
                    startingProxy = nil
                } catch {
                    await candidate.stop()
                    if startingProxy === candidate { startingProxy = nil }
                    throw error
                }
            }
            guard let proxy else { throw CuaMCPProxyError.notStarted }
            try await verifyCuaReadiness(proxy, generation: generation)
            try requireCurrentLifecycle(generation)
            paused = startPaused
            readiness = startPaused ? "paused" : (controlSessionIsUsable ? "ready" : sessionLock.readiness)
            if connectRelay, let saved = try? await readSavedInstallation() {
                try requireCurrentLifecycle(generation)
                activeInstallation = saved
                await gateway?.setReadiness(readiness)
                try requireCurrentLifecycle(generation)
                beginReconnectLoop(for: saved)
            }
        } catch {
            if generation == lifecycleGeneration, !Task.isCancelled {
                recordCuaFailure(error)
                if connectRelay { await publishReadinessFailure(error, generation: generation) }
                else { readiness = Self.readiness(for: error) }
            }
            throw error
        }
    }

    private func verifyCuaReadiness(_ candidate: CuaMCPProxy, generation: UUID) async throws {
        guard let installation = selectedCuaInstallation, let daemonPID else { throw CuaMCPProxyError.notStarted }
        let peer = try await cuaService.inspectPeer(installation: installation)
        try requireCurrentLifecycle(generation)
        guard peer == daemonPID else { throw CuaMCPProxyError.serviceMismatch }
        let response = try await candidate.callTool(name: "check_permissions",
            argumentsJSON: CuaDriverCompatibility.permissionProbeArgumentsJSON, timeout: 5)
        try Task.checkCancellation()
        try requireCurrentLifecycle(generation)
        guard proxy === candidate,
              let structured = Self.toolResult(response)?["structuredContent"] as? [String: Any] else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
        let snapshot = try CuaDriverPermissionSnapshot.parseStandalone(structured, daemonPID: daemonPID)
        cuaPermissions = snapshot
        guard snapshot.standaloneAttributionValid else { throw CuaMCPProxyError.serviceMismatch }
        guard snapshot.accessibility, snapshot.screenRecording, snapshot.directCaptureVerified else { throw CuaMCPProxyError.permissionsRequired }
        capabilitiesVerified = true
        lastCuaCheck = Date()
        cuaCheckFailure = nil
        cuaConnectionNeedsRefresh = false
        Self.clearRecoveredRepairError(preferences: preferences, readiness: "ready", cuaReady: true)
    }

    private func cleanupExecutor() async {
        if let task = executorCleanupTask { _ = await task.value; return }
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

    private func scheduleSessionAvailabilityCheck(requestRecovery: Bool = false) {
        let previous = sessionLockChangeTask
        let generation = sessionAvailabilityGeneration
        sessionLockChangeTask = Task {
            await previous?.value
            guard generation == sessionAvailabilityGeneration, !disconnecting, !environmentSwitchPending else { return }
            await reconcileIMessageExecutionAvailability()
            guard generation == sessionAvailabilityGeneration, sessionLock.isAwakeAndActive,
                  !disconnecting, !environmentSwitchPending else { return }
            if requestRecovery { requestConnectionRecovery() }
        }
    }

    /// Capture the loss synchronously. Recovery cannot erase this event or reuse
    /// a physical connection while its captured actor/provider is still stopping.
    private func latchSessionAvailabilityLoss() {
        sessionAvailabilityGeneration = UUID()
        let previous = sessionLockChangeTask
        let pending = pendingGateway, current = gateway, session = iMessageSession
        pendingGateway = nil; gateway = nil; gatewayConnectionID = nil; gatewayConnected = false
        gatewayAttemptID = UUID()
        iMessageSetupIntent = nil
        capabilitiesVerified = false
        readiness = sessionLock.readiness
        executorCleanupInProgress = true
        let task = Task {
            await previous?.value
            await session?.runtime.setExecutionAvailable(false)
            await session?.runtime.suspendAndDrain()
            await pending?.stopAndDrainIMessage()
            await current?.stopAndDrainIMessage()
            await cleanupExecutor()
        }
        sessionLockChangeTask = task
        lockCleanupTask = task
    }

    private func heartbeatReadiness() async -> String? {
        guard !Task.isCancelled else { return nil }
        sessionLock.reconcile()
        let generation = lifecycleGeneration
        guard desktopControlConnectionIntended else {
            await stopInactiveDesktopControl(generation: generation)
            return readiness
        }
        if (executorCleanupFailed || executor.needsSessionCleanup) && !executorCleanupInProgress {
            if paused { await stopLocalControl(generation: generation) }
            else { await cleanupExecutor() }
            guard generation == lifecycleGeneration, !Task.isCancelled else { return nil }
        }
        if paused { return "paused" }
        if executorCleanupInProgress || executorCleanupFailed { return "cua_unavailable" }
        if !controlSessionIsUsable { return sessionLock.readiness }
        guard !executor.nativeVerificationInProgress else { return nil }
        let observedProxy = proxy
        let proxyRunning = await observedProxy?.isProcessRunning() ?? false
        guard generation == lifecycleGeneration, !Task.isCancelled,
              proxy === observedProxy, !executor.nativeVerificationInProgress else { return nil }
        if !proxyRunning || cuaConnectionNeedsRefresh {
            if executor.currentLease != nil { await cleanupExecutor() }
            guard generation == lifecycleGeneration, !Task.isCancelled,
                  proxy === observedProxy, !executor.nativeVerificationInProgress else { return nil }
            guard !executorCleanupFailed else { return "cua_unavailable" }
            if let old = proxy { await old.stop() }
            guard generation == lifecycleGeneration, !Task.isCancelled,
                  proxy === observedProxy, !executor.nativeVerificationInProgress else { return nil }
            proxy = nil
            tools = []
            capabilitiesVerified = false
            guard desktopControlStartupIntended else { return "unknown" }
            do { try await startCua(startPaused: false, generation: generation) }
            catch { return Self.readiness(for: error) }
        }
        let ready = await refreshCuaReadiness()
        guard generation == lifecycleGeneration, !Task.isCancelled else { return nil }
        if !ready, executor.currentLease != nil { await cleanupExecutor() }
        if ready { readiness = "ready" }
        return readiness
    }

    private func handle(_ frame: DesktopControlFrame, connectionID: UUID,
                        onChunk: @escaping @Sendable (DesktopControlFrame) async throws -> Void) async -> DesktopControlFrame {
        guard Self.acceptsCommand(connectionID: connectionID, currentConnectionID: gatewayConnectionID,
                                  disconnecting: disconnecting || environmentSwitchPending) else {
            return Self.failure(for: frame, code: "desktop_connection_stale")
        }
        guard let activeInstallation, frame.target?.installationID == activeInstallation.installationID else {
            return Self.failure(for: frame, code: "desktop_executor_unavailable")
        }
        guard let deadline = frame.deadlineAt, deadline > Date(), !Task.isCancelled else {
            return Self.failure(for: frame, code: "desktop_command_expired",
                                message: "The command expired before execution. No new action was started.")
        }
        sessionLock.reconcile()
        let isStatus = frame.operation == "desktop_control_status"
        let cleanup = ["desktop_control_release", "desktop_control_revoke_config", "desktop_control_revoke_binding"].contains(frame.operation ?? "")
        if !isStatus && !cleanup {
            guard desktopControlConnectionIntended else {
                return Self.failure(for: frame, code: "desktop_executor_unavailable")
            }
            guard !paused else { return Self.failure(for: frame, code: "desktop_paused") }
            guard !executorCleanupInProgress, !executorCleanupFailed, controlSessionIsUsable else {
                return Self.failure(for: frame, code: "desktop_executor_unavailable")
            }
            guard await refreshCuaReadiness() else {
                await gateway?.setReadiness(readiness)
                return Self.failure(for: frame, code: readiness,
                                    message: cuaCheckFailure ?? "CUA needs attention. Open Set Up CUA on this Mac.")
            }
            guard Self.acceptsCommand(connectionID: connectionID, currentConnectionID: gatewayConnectionID,
                                      disconnecting: disconnecting || environmentSwitchPending), !paused else {
                return Self.failure(for: frame, code: "desktop_connection_stale")
            }
        }
        let generation = lifecycleGeneration
        let response = await executor.handle(frame, proxy: proxy, onChunk: onChunk)
        if !isStatus, executor.needsSessionCleanup {
            readiness = "cua_unavailable"
            await cleanupExecutor()
            if !executorCleanupFailed, generation == lifecycleGeneration { _ = await refreshCuaReadiness() }
        }
        if isStatus {
            guard await refreshStatusReadiness(generation: generation, connectionID: connectionID) else {
                return Self.failure(for: frame, code: "desktop_connection_stale")
            }
            return Self.enrichStatus(response, connected: gatewayConnected, guiReadiness: readiness,
                                     paused: paused, locked: sessionLock.state == .locked,
                                     sessionUnlocked: sessionLock.state == .unlocked,
                                     executionAllowed: !executorCleanupInProgress && !executorCleanupFailed && controlSessionIsUsable)
        }
        guard cleanup || (generation == lifecycleGeneration && controlSessionIsUsable && !paused) else {
            return Self.failure(for: frame, code: "desktop_cua_failure_unknown",
                                message: "Control ended while the command was running. Check the desktop before retrying.")
        }
        return response
    }

    private func refreshStatusReadiness(generation: UUID, connectionID: UUID) async -> Bool {
        guard desktopControlConnectionIntended else {
            return generation == lifecycleGeneration
                && Self.acceptsCommand(connectionID: connectionID, currentConnectionID: gatewayConnectionID,
                                       disconnecting: disconnecting || environmentSwitchPending)
        }
        guard !executorCleanupInProgress, !executorCleanupFailed, controlSessionIsUsable,
              executor.currentLease == nil, !executor.nativeVerificationInProgress else { return true }
        // Busy status must not queue behind a long CUA action. Heartbeats keep
        // checking health independently while an owner holds the lease.
        // Diagnostic checks remain available while paused. They never install,
        // prompt, start CUA, or replay remote work.
        _ = await refreshCuaReadiness()
        guard generation == lifecycleGeneration,
              Self.acceptsCommand(connectionID: connectionID, currentConnectionID: gatewayConnectionID,
                                  disconnecting: disconnecting || environmentSwitchPending) else { return false }
        if !isCuaReady(), executor.currentLease != nil { await cleanupExecutor() }
        await gateway?.setReadiness(paused ? "paused" : readiness)
        return generation == lifecycleGeneration
            && Self.acceptsCommand(connectionID: connectionID, currentConnectionID: gatewayConnectionID,
                                   disconnecting: disconnecting || environmentSwitchPending)
    }

    static func enrichStatus(_ frame: DesktopControlFrame, connected: Bool, guiReadiness: String,
                             paused: Bool, locked: Bool, sessionUnlocked: Bool,
                             executionAllowed: Bool = true) -> DesktopControlFrame {
        guard frame.type == "result", case .object(var result)? = frame.result else { return frame }
        let ready = guiReadiness == "ready"
        let available = executionAllowed && result["available"] == .bool(true) && ready && !paused
        result.removeValue(forKey: "native_executor_ready")
        result["connected"] = .bool(connected)
        result["gui_readiness"] = .string(guiReadiness)
        result["gui_ready"] = .bool(ready)
        result["available"] = .bool(available)
        result["paused"] = .bool(paused)
        result["locked"] = .bool(locked)
        result["session_unlocked"] = .bool(sessionUnlocked)
        result["control_available"] = .bool(connected && available)
        return DesktopControlFrame(version: frame.version, type: frame.type, requestID: frame.requestID, result: .object(result))
    }

    func diagnosticReport() async -> DesktopControlDiagnosticReport {
        DesktopControlDiagnosticReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            driverVersion: CuaDriverCompatibility.version, state: presentationSnapshot().state,
            connected: gatewayConnected, lastConnection: lastSuccessfulConnection,
            guiReady: isCuaReady(), nativeReady: false,
            session: sessionLock.state == .unlocked ? .unlocked : (sessionLock.state == .locked ? .locked : .unavailable),
            login: DesktopLoginItemRegistration.loginStatus() == .enabled ? .enabled : .disabled,
            reconnectPending: reconnectTask != nil, cleanupPending: executorCleanupInProgress,
            resources: nil, accessibilityGranted: cuaPermissions?.accessibility,
            screenCaptureGranted: cuaPermissions?.screenRecording,
            desktopReadiness: readiness, lastCuaCheck: lastCuaCheck, cuaCheckFailure: cuaCheckFailure)
    }

#if DEBUG
    static func makeForTesting(installer: any DesktopControlDriverInstalling,
                               cuaService: any DesktopControlCuaServicing = CuaStandaloneService(),
                               credentials: any DesktopControlCredentialStoring,
                               iMessageProviderFactory: (() -> IMessageSetupProvider)? = nil,
                               gatewaySocketFactory: (() -> any DesktopControlSocket)? = nil,
                               iMessageAuthorizationClient: IMessageConfiguredAuthorizationClient? = nil,
                               executor: DesktopControlCommandExecutor? = nil,
                               proxy: CuaMCPProxy? = nil,
                               proxyFactory: ((CuaDriverInstallation, URL, Int32) -> CuaMCPProxy)? = nil,
                               beforeCuaPublication: (() async -> Void)? = nil,
                               connectionID: UUID? = nil,
                               installation: DesktopControlInstallation? = nil,
                               connected: Bool = false,
                               readiness: String = "unknown", paused: Bool = false,
                               sessionLockState: DesktopControlSessionLock.State? = nil,
                               sessionMonitor: DesktopControlSessionLock? = nil,
                               cleanupInProgress: Bool = false, cleanupFailed: Bool = false,
                               relayStateReader: (any DesktopControlRelayStateReading)? = nil,
                               scheduleReconnect: Bool = true,
                               preferences: UserDefaults = .standard,
                               configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { .production },
                               revokeInstallation: (@Sendable (DesktopControlInstallation, DesktopEnvironmentConfiguration) async throws -> Void)? = nil) -> DesktopControlRuntime {
        let monitor = sessionMonitor ?? DesktopControlSessionLock(observeSystem: false, snapshotReader: { .unknown })
        let runtime = DesktopControlRuntime(installer: installer, cuaService: cuaService, credentials: credentials,
            relayStateReader: relayStateReader, preferences: preferences,
            configurationProvider: configurationProvider, revokeInstallation: revokeInstallation, sessionLock: monitor)
        if let iMessageProviderFactory { runtime.iMessageProviderFactory = iMessageProviderFactory }
        runtime.gatewaySocketFactoryForTesting = gatewaySocketFactory
        if let iMessageAuthorizationClient { runtime.iMessageAuthorizationClient = iMessageAuthorizationClient }
        if let executor { runtime.executor = executor }
        runtime.proxy = proxy
        runtime.proxyFactoryForTesting = proxyFactory
        runtime.beforeCuaPublicationForTesting = beforeCuaPublication
        runtime.scheduleReconnectForTesting = scheduleReconnect
        runtime.gatewayConnectionID = connectionID
        runtime.activeInstallation = installation
        runtime.gatewayConnected = connected
        runtime.readiness = readiness
        runtime.paused = paused
        runtime.executorCleanupInProgress = cleanupInProgress
        runtime.executorCleanupFailed = cleanupFailed
        if let sessionLockState { monitor.receive(sessionLockState) }
        return runtime
    }
    func setRelayClockForTesting(_ now: @escaping () -> Date) { relayNow = now }
    func setRelayConnectionAttemptForTesting(_ attempt: @escaping () async throws -> Void) {
        reconnectAttemptForTesting = attempt
    }
    func reconcileRelayForTesting() async throws { try await reconcileRelayIntent(generation: lifecycleGeneration) }
    func reconnectRelayForTesting() async -> Bool {
        guard let installation = activeInstallation else { return false }
        return await reconnectIfNeeded(installation, loopID: reconnectLoopID)
    }
    var hasIMessageSetupIntentForTesting: Bool { iMessageSetupIntent.map { $0.expiresAt > relayNow() } == true }
    var hasDesktopControlIntentForTesting: Bool { desktopControlConnectionIntended }
    func startReconnectLoopForTesting(installation: DesktopControlInstallation,
                                      allowUnconfigured: Bool = true,
                                      attempt: @escaping () async throws -> Void) {
        desktopControlSetupGeneration = allowUnconfigured ? lifecycleGeneration : nil
        reconnectAttemptForTesting = attempt
        beginReconnectLoop(for: installation)
    }
    var reconnectDelayPendingForTesting: Bool { reconnectDelayTask != nil }
    func requestConnectionRecoveryForTesting() { sessionLock.onRecovery?() }

    func handleForTesting(_ frame: DesktopControlFrame, connectionID: UUID) async -> DesktopControlFrame {
        await handle(frame, connectionID: connectionID, onChunk: { _ in })
    }
    func savedInstallationForTesting() async throws -> DesktopControlInstallation? {
        let saved = try await readSavedInstallation()
        activeInstallation = saved
        return saved
    }
    func replaceExecutorForTesting(_ replacement: DesktopControlCommandExecutor) { executor = replacement }
    var executorCleanupFailedForTesting: Bool { executorCleanupFailed }
    var hasPendingRelayReconnectForTesting: Bool { reconnectTask != nil }
    func waitForLockCleanupForTesting() async { await lockCleanupTask?.value }
    func waitForSessionLockChangeForTesting() async { await sessionLockChangeTask?.value }
    func receiveSessionLockForTesting(_ state: DesktopControlSessionLock.State) { sessionLock.receive(state) }
    func signalLifecycleLossForTesting() { sessionLock.onLifecycleLoss?() }
    func heartbeatReadinessForTesting() async -> String? { await heartbeatReadiness() }
#endif
}
