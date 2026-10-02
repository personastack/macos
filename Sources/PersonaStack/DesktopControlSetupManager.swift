import AppKit
import OSLog
import SystemConfiguration
import PersonaStackCore
import WebKit

@MainActor
protocol DesktopControlSetupRuntime: AnyObject {
    var gatewayConnected: Bool { get }
    var paused: Bool { get }
    var nativeExecutorReady: Bool { get }
    func isCuaReady() -> Bool
    func probeNativeCapabilities(generation: UUID) async throws
    func beginResume() throws -> UUID
    func resume(generation: UUID) async throws
    func resumeForSetup(generation: UUID) async throws
    func finishSetupIfIdle() async throws
    func disconnect() async throws
    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID
    func isCurrentLifecycle(_ generation: UUID) -> Bool
    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async
    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation?
}

protocol DesktopControlSetupEnrollment: DesktopControlRelayStateReading {
    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?
    ) async throws -> DesktopControlInstallation
    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws
    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws
    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState
}

extension DesktopControlEnrollmentClient: DesktopControlSetupEnrollment {}

struct DesktopControlSetupScope {
    private(set) var value = ""
    private(set) var generation = UUID()

    mutating func synchronize(_ value: String) {
        guard self.value != value else { return }
        self.value = value
        generation = UUID()
    }

    func require(_ value: String, generation expectedGeneration: UUID? = nil) throws {
        guard self.value == value, expectedGeneration == nil || generation == expectedGeneration else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
    }
}

enum DesktopControlSetupCommand: Equatable {
    enum PermissionPhase: String {
        case open, completed, failed, repair
    }

    case sync(scope: String)
    case state(scope: String)
    case permissions(scope: String, phase: PermissionPhase, message: String?)
    case prepare(scope: String, enrollmentTicket: String)

    static func parse(_ body: Any) throws -> DesktopControlSetupCommand {
        guard let object = body as? [String: Any], object["version"] as? String == "1",
              let action = object["action"] as? String,
              let scope = object["scope"] as? String, scope.utf8.count <= 512 else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        switch action {
        case "sync":
            guard Set(object.keys) == ["version", "action", "scope"] else { throw DesktopControlEnrollmentError.invalidRequest }
            return .sync(scope: scope)
        case "state":
            guard Set(object.keys) == ["version", "action", "scope"] else { throw DesktopControlEnrollmentError.invalidRequest }
            return .state(scope: scope)
        case "permissions":
            guard let phaseValue = object["phase"] as? String,
                  let phase = PermissionPhase(rawValue: phaseValue),
                  !scope.isEmpty || phase == .repair else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
            let message = object["message"] as? String
            let expected: Set<String> = phase == .failed && message != nil
                ? ["version", "action", "scope", "phase", "message"]
                : ["version", "action", "scope", "phase"]
            guard Set(object.keys) == expected,
                  message == nil || (phase == .failed && message!.utf8.count <= 512) else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
            return .permissions(scope: scope, phase: phase, message: message)
        case "prepare":
            guard !scope.isEmpty,
                  Set(object.keys) == ["version", "action", "scope", "enrollment_ticket"],
                  let ticket = object["enrollment_ticket"] as? String,
                  ticket.utf8.count == 43,
                  ticket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
            return .prepare(scope: scope, enrollmentTicket: ticket)
        default:
            throw DesktopControlEnrollmentError.invalidRequest
        }
    }

    var actionName: String {
        switch self {
        case .sync: "sync"
        case .state: "state"
        case .permissions: "permissions"
        case .prepare: "prepare"
        }
    }
}

@MainActor
protocol DesktopControlPermissionPresenting: AnyObject {
    var isFinishing: Bool { get }
    func presentForSetup() async throws
    func presentForRepair()
    func completeSetup()
    func failSetup(message: String)
    func cancel()
}

extension DesktopPermissionChecklistWindow: DesktopControlPermissionPresenting {
    var isFinishing: Bool { coordinator.isFinishing }
}

private enum DesktopControlPermissionBridgeError: LocalizedError {
    case busy, scopeChanged, incomplete

    var errorDescription: String? {
        switch self {
        case .busy: "Desktop Control permission setup is already open."
        case .scopeChanged: "This Desktop Control setup changed. Reopen setup in the current workspace."
        case .incomplete: "Finish the native permission checklist before connecting this desktop."
        }
    }

    var code: String {
        switch self {
        case .busy: "setup_busy"
        case .scopeChanged: "setup_scope_changed"
        case .incomplete: "permissions_incomplete"
        }
    }
}

@MainActor
final class DesktopControlSetupManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = DesktopControlSetupManager(
        configurationProvider: { try LaunchConfiguration.selectedEnvironment() }
    )

    final class Page {
        let appURL: URL
        var setupScope = DesktopControlSetupScope()
        fileprivate var permissionGeneration: UUID?
        fileprivate var didPrepare = false
        fileprivate var requiresExplicitPermissions = false
        private(set) var isRetired = false

        init(appURL: URL) { self.appURL = appURL }

        func retire() {
            isRetired = true
            setupScope.synchronize("")
        }
    }

    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-setup")
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let enrollment: any DesktopControlSetupEnrollment
    private let credentials: (any DesktopControlCredentialStoring)?
    private let preferences: UserDefaults
    private let runtime: any DesktopControlSetupRuntime
    private let configurationProvider: () throws -> DesktopEnvironmentConfiguration
    private var cachedPermissionPresenter: (any DesktopControlPermissionPresenting)?
    private var permissionPresenter: any DesktopControlPermissionPresenting {
        if let cachedPermissionPresenter { return cachedPermissionPresenter }
        let presenter = DesktopPermissionChecklist.shared.window
        presenter.onCancel = { [weak self] in
            DesktopPermissionChecklist.shared.cancelVerification()
            guard let self, let page = self.permissionPage else { return }
            self.cancelPermissions(for: page)
            page.setupScope.synchronize("")
        }
        cachedPermissionPresenter = presenter
        return presenter
    }
    private weak var permissionPage: Page?
    private var permissionRequest: UUID?

    init(
        runtime: any DesktopControlSetupRuntime = DesktopControlRuntime.shared,
        enrollment: any DesktopControlSetupEnrollment = DesktopControlEnrollmentClient(),
        credentials: (any DesktopControlCredentialStoring)? = nil,
        preferences: UserDefaults = .standard,
        configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() },
        permissionPresenter: (any DesktopControlPermissionPresenting)? = nil
    ) {
        self.runtime = runtime
        self.enrollment = enrollment
        self.credentials = credentials
        self.preferences = preferences
        self.configurationProvider = configurationProvider
        self.cachedPermissionPresenter = permissionPresenter
        super.init()
    }

    func invalidate(_ view: WKWebView) {
        if let page = pages.object(forKey: view) { cancelPermissions(for: page) }
        pages.object(forKey: view)?.setupScope.synchronize("")
    }

    func unregister(_ view: WKWebView) {
        if let page = pages.object(forKey: view) { cancelPermissions(for: page) }
        pages.object(forKey: view)?.retire()
        pages.removeObject(forKey: view)
    }

    func registeredPage(for view: WKWebView) -> Page? { pages.object(forKey: view) }

    func register(_ view: WKWebView, appURL: URL) {
        pages.setObject(Page(appURL: appURL), forKey: view)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view),
              ChatWindowManager.trusted(message, base: page.appURL) else {
            replyHandler(nil, DesktopControlEnrollmentError.invalidRequest.localizedDescription)
            return
        }
        dispatch(message.body, page: page, replyHandler: replyHandler)
    }

    func dispatch(_ body: Any, page: Page,
                  replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !page.isRetired else {
            replyHandler(nil, DesktopControlEnrollmentError.invalidRequest.localizedDescription)
            return
        }
        guard let command = try? DesktopControlSetupCommand.parse(body) else {
            replyHandler(nil, DesktopControlEnrollmentError.invalidRequest.localizedDescription)
            return
        }
        if case .sync(let scope) = command, !scope.isEmpty {
            if page.setupScope.value != scope { cancelPermissions(for: page) }
            page.setupScope.synchronize(scope)
            replyHandler(Self.scopeReply, nil)
            return
        }
        logger.notice("desktop control setup \(command.actionName, privacy: .public)")
        Task { @MainActor in
            do {
                let response = try await apply(command, page: page)
                replyHandler(response, nil)
            } catch {
                if case .permissions = command {
                    let code = (error as? DesktopControlPermissionBridgeError)?.code
                        ?? (error is CancellationError ? "setup_cancelled" : "permissions_incomplete")
                    replyHandler(["ok": false, "version": "1", "error_code": code], nil)
                    return
                }
                let safeMessage = (error as? LocalizedError)?.errorDescription
                    ?? DesktopControlEnrollmentError.rejected.localizedDescription
                logger.error("desktop control setup \(command.actionName, privacy: .public) failed")
                replyHandler(nil, safeMessage)
            }
        }
    }

    func apply(_ command: DesktopControlSetupCommand, page: Page) async throws -> [String: Any] {
        guard !page.isRetired else { throw DesktopControlEnrollmentError.invalidRequest }
        let credentials = credentials ?? FileDesktopControlCredentialStore(appURL: page.appURL)
        switch command {
        case .sync(let scope):
            if scope.isEmpty || page.setupScope.value != scope { cancelPermissions(for: page) }
            page.setupScope.synchronize(scope)
            if scope.isEmpty {
                try await runtime.finishSetupIfIdle()
                try requireCurrentScope(scope, page: page)
            }
            return Self.scopeReply
        case .state(let scope):
            try requireCurrentScope(scope, page: page)
            let installation = try await savedInstallation(credentials: credentials, appURL: page.appURL)
            try requireCurrentScope(scope, page: page)
            var configurationInUse = false
            if let installation {
                configurationInUse = try await enrollment.configurationState(installation: installation, appURL: page.appURL).hasConfig
                try requireCurrentScope(scope, page: page)
            }
            return [
                "ok": true,
                "operating_system": "macos",
                "permissions_checklist_version": "1",
                "installation_id": installation?.installationID as Any? ?? NSNull(),
                "configuration_in_use": configurationInUse,
                "cua_ready": runtime.isCuaReady(),
                "native_executor_ready": runtime.nativeExecutorReady,
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
            ]
        case .permissions(let scope, let phase, let message):
            if phase != .repair { page.requiresExplicitPermissions = true }
            return try await permissions(scope: scope, phase: phase, message: message, page: page)
        case .prepare(let scope, let ticket):
            let legacy = !page.requiresExplicitPermissions && page.permissionGeneration == nil && permissionPage == nil
            if legacy {
                // Older hosted pages acquire the existing five-minute ticket first.
                // Keep the native Finish gate. The API still owns ticket expiry.
                _ = try await permissions(scope: scope, phase: .open, message: nil, page: page)
            }
            let legacyRequest = legacy ? permissionRequest : nil
            let legacyGeneration = page.setupScope.generation
            do { return try await prepare(scope: scope, ticket: ticket, page: page, credentials: credentials) }
            catch {
                if legacy, let legacyRequest, permissionRequest == legacyRequest,
                   permissionPage === page, page.setupScope.generation == legacyGeneration {
                    permissionPresenter.failSetup(message: "Desktop Control could not finish. Retry setup to obtain a fresh setup reference.")
                    page.permissionGeneration = nil
                    page.didPrepare = false
                    permissionPage = nil
                    permissionRequest = nil
                }
                throw error
            }
        }
    }

    private func prepare(scope: String, ticket: String, page: Page,
                         credentials: any DesktopControlCredentialStoring) async throws -> [String: Any] {
        let generation = page.setupScope.generation
        try page.setupScope.require(scope, generation: generation)
        try requireFinishedPermissions(page: page, generation: generation)
        let saved = try await savedInstallation(credentials: credentials, appURL: page.appURL)
        try requireCurrentScope(scope, generation: generation, page: page)
        try requireFinishedPermissions(page: page, generation: generation)
        if let saved {
            try await runtime.disconnect()
            try requireCurrentScope(scope, generation: generation, page: page)
            try await enrollment.attach(ticket: ticket, installation: saved, appURL: page.appURL)
            try requireCurrentScope(scope, generation: generation, page: page)
        }
        var runtimeGeneration = try runtime.beginResume()
        do {
            try await runtime.resumeForSetup(generation: runtimeGeneration)
        } catch {
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
            guard DesktopControlRuntime.shouldForceRepair(after: error) else { throw error }
            runtimeGeneration = try await runtime.repair(resumeRelay: true, expectedGeneration: runtimeGeneration)
        }
        do { try await runtime.probeNativeCapabilities(generation: runtimeGeneration) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DesktopControlEnrollmentError.nativeCapabilitiesUnavailable }
        try requireCurrentScope(scope, generation: generation, page: page)
        try requireCurrentLifecycle(runtimeGeneration)
        let installation: DesktopControlInstallation
        if let saved {
            try saved.requireEnvironment(page.appURL)
            installation = saved
            try await enrollment.reportReady(installation: installation, appURL: page.appURL)
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
        } else {
            let enrollmentRuntimeGeneration = runtimeGeneration
            installation = try await enrollment.enroll(
                ticket: ticket,
                appURL: page.appURL,
                commitCredential: { [weak self] installation in
                    guard let self else { throw CancellationError() }
                    try self.requireCurrentScope(scope, generation: generation, page: page)
                    try self.requireCurrentLifecycle(enrollmentRuntimeGeneration)
                    try credentials.save(installation)
                }
            )
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
            try await enrollment.reportReady(installation: installation, appURL: page.appURL)
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
        }
        try requireCurrentScope(scope, generation: generation, page: page)
        try requireCurrentLifecycle(runtimeGeneration)
        await runtime.connect(installation: installation, expectedGeneration: runtimeGeneration)
        try requireCurrentScope(scope, generation: generation, page: page)
        try requireCurrentLifecycle(runtimeGeneration)
        let configuration = try configurationProvider()
        guard let pageOrigin = try? DesktopControlEnvironment.origin(page.appURL), pageOrigin == configuration.appOrigin else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        preferences.set(true, forKey: DesktopControlPreferenceKeys.relayEnabled(configuration))
        preferences.set(false, forKey: DesktopControlPreferenceKeys.relayPaused(configuration))
        page.didPrepare = true
        return [
            "ok": true,
            "operating_system": "macos",
            "installation_id": installation.installationID,
            "cua_ready": runtime.isCuaReady(),
            "native_executor_ready": runtime.nativeExecutorReady,
            "gateway_connected": runtime.gatewayConnected,
            "relay_paused": runtime.paused,
            "suggested_name": Self.suggestedComputerName(),
        ]
    }

    private static var scopeReply: [String: Any] {
        ["ok": true, "version": "1", "operating_system": "macos", "permissions_checklist_version": "1"]
    }

    private func permissions(scope: String, phase: DesktopControlSetupCommand.PermissionPhase,
                             message: String?, page: Page) async throws -> [String: Any] {
        let generation = page.setupScope.generation
        guard !page.isRetired, page.setupScope.value == scope else {
            throw DesktopControlPermissionBridgeError.scopeChanged
        }
        if phase == .repair {
            guard permissionPage == nil else { throw DesktopControlPermissionBridgeError.busy }
            permissionPresenter.presentForRepair()
            return ["ok": true, "version": "1"]
        }
        if phase == .open {
            guard permissionPage == nil else { throw DesktopControlPermissionBridgeError.busy }
            let request = UUID()
            permissionRequest = request
            permissionPage = page
            page.permissionGeneration = nil
            page.didPrepare = false
            do {
                try await permissionPresenter.presentForSetup()
                guard permissionRequest == request, permissionPage === page,
                      !page.isRetired, page.setupScope.generation == generation else {
                    throw DesktopControlPermissionBridgeError.scopeChanged
                }
                guard permissionPresenter.isFinishing else { throw DesktopControlPermissionBridgeError.incomplete }
                page.permissionGeneration = generation
                return ["ok": true, "permissions_checklist_version": "1", "prerequisites_ready": true]
            } catch {
                if permissionRequest == request { cancelPermissions(for: page) }
                throw error
            }
        }
        try requireFinishedPermissions(page: page, generation: generation)
        if phase == .completed {
            guard let request = permissionRequest else {
                throw DesktopControlPermissionBridgeError.incomplete
            }
            try requireCompletionReadiness(page: page)
            let credentials = credentials ?? FileDesktopControlCredentialStore(appURL: page.appURL)
            guard let installation = try await savedInstallation(credentials: credentials, appURL: page.appURL) else {
                throw DesktopControlPermissionBridgeError.incomplete
            }
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireFinishedPermissions(page: page, generation: generation, request: request)
            let state = try await enrollment.configurationState(installation: installation, appURL: page.appURL)
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireFinishedPermissions(page: page, generation: generation, request: request)
            guard state.hasConfig, state.hasActiveConfig else {
                throw DesktopControlPermissionBridgeError.incomplete
            }
            try requireCompletionReadiness(page: page)
            permissionPresenter.completeSetup()
        } else {
            permissionPresenter.failSetup(message: message ?? "Desktop Control setup could not finish. Check the app connection and retry.")
        }
        page.permissionGeneration = nil
        page.didPrepare = false
        permissionPage = nil
        permissionRequest = nil
        return ["ok": true, "version": "1"]
    }

    private func requireFinishedPermissions(page: Page, generation: UUID, request: UUID? = nil) throws {
        guard permissionPage === page, page.permissionGeneration == generation, permissionPresenter.isFinishing,
              request == nil || permissionRequest == request else {
            throw DesktopControlPermissionBridgeError.incomplete
        }
    }

    private func requireCompletionReadiness(page: Page) throws {
        guard page.didPrepare, runtime.gatewayConnected, runtime.isCuaReady(), runtime.nativeExecutorReady else {
            throw DesktopControlPermissionBridgeError.incomplete
        }
    }

    private func cancelPermissions(for page: Page) {
        page.permissionGeneration = nil
        page.didPrepare = false
        guard permissionPage === page else { return }
        permissionRequest = nil
        permissionPage = nil
        permissionPresenter.cancel()
    }

    private func savedInstallation(credentials: any DesktopControlCredentialStoring,
                                   appURL: URL) async throws -> DesktopControlInstallation? {
        if self.credentials != nil {
            let store = credentials
            return try await Task.detached(priority: .userInitiated) { try store.load() }.value
        }
        return try await runtime.savedInstallation(for: appURL)
    }

    private func requireCurrentScope(_ scope: String, page: Page) throws {
        try requireCurrentScope(scope, generation: page.setupScope.generation, page: page)
    }

    private func requireCurrentScope(_ scope: String, generation: UUID, page: Page) throws {
        guard !page.isRetired else { throw CancellationError() }
        try page.setupScope.require(scope, generation: generation)
        if page.permissionGeneration != nil { try requireFinishedPermissions(page: page, generation: generation) }
    }

    private func requireCurrentLifecycle(_ generation: UUID) throws {
        guard runtime.isCurrentLifecycle(generation) else { throw CancellationError() }
    }

    private static func suggestedComputerName() -> String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(name.prefix(120))
    }
}
