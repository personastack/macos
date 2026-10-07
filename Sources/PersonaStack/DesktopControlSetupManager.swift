import AppKit
import OSLog
import SystemConfiguration
import PersonaStackCore
import WebKit

@MainActor
protocol DesktopControlSetupRuntime: AnyObject {
    func refreshCuaReadiness() async -> Bool
    var gatewayConnected: Bool { get }
    var paused: Bool { get }
    func isCuaReady() -> Bool
    func beginResume() throws -> UUID
    func resume(generation: UUID) async throws
    func resumeForSetup(generation: UUID) async throws
    func finishSetupIfIdle() async throws
    func disconnect() async throws
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
    case cuaSetup(scope: String, phase: PermissionPhase, message: String?)
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
        // The deployed hosted page uses permissions until its next release.
        // Both wire names enter the standalone CUA setup path.
        case "cua_setup", "permissions":
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
            return .cuaSetup(scope: scope, phase: phase, message: message)
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
        case .cuaSetup: "cua_setup"
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

private enum DesktopControlPermissionBridgeError: LocalizedError {
    case busy, preparationPending, outcomeUnknown, scopeChanged, incomplete, timedOut

    var errorDescription: String? {
        switch self {
        case .busy: "CUA setup is already open."
        case .preparationPending: "The previous Desktop Control connection is still finishing. Return to PersonaStack and click Check Again."
        case .outcomeUnknown: "The previous connection result could not be confirmed. Return to PersonaStack and click Check Again before starting another connection."
        case .scopeChanged: "This Desktop Control setup changed. Reopen setup in the current workspace."
        case .incomplete: "Complete CUA setup before connecting this desktop."
        case .timedOut: "The connection result could not be confirmed. Return to PersonaStack and click Check Again."
        }
    }

    var code: String {
        switch self {
        case .busy, .preparationPending: "setup_busy"
        case .scopeChanged: "setup_scope_changed"
        case .incomplete: "permissions_incomplete"
        case .timedOut, .outcomeUnknown: "setup_timeout"
        }
    }
}

@MainActor
final class DesktopControlSetupManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = DesktopControlSetupManager(
        configurationProvider: { try LaunchConfiguration.selectedEnvironment() }
    )

    /// Owns one WebKit reply and its automatic work. Settlement releases the reply
    /// immediately, even when a cancelled dependency takes longer to unwind.
    @MainActor
    fileprivate final class Request {
        let command: DesktopControlSetupCommand
        var task: Task<Void, Never>?
        private var deadline: Task<Void, Never>?
        private var reply: (@MainActor @Sendable (Any?, String?) -> Void)?

        init(command: DesktopControlSetupCommand,
             reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            self.command = command
            self.reply = reply
        }

        func startDeadline(after duration: Duration) {
            guard deadline == nil, reply != nil else { return }
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.cancel(DesktopControlPermissionBridgeError.timedOut)
            }
        }

        func finish(_ response: [String: Any]) { settle(response, nil) }

        func fail(_ error: any Error) {
            if case .cuaSetup = command {
                let code = (error as? DesktopControlPermissionBridgeError)?.code
                    ?? (error is CancellationError ? "setup_cancelled" : "permissions_incomplete")
                settle(["ok": false, "version": "1", "error_code": code], nil)
            } else {
                settle(nil, (error as? LocalizedError)?.errorDescription
                    ?? DesktopControlEnrollmentError.rejected.localizedDescription)
            }
        }

        func cancel(_ error: any Error = CancellationError()) {
            task?.cancel()
            task = nil
            fail(error)
        }

        private func settle(_ response: Any?, _ error: String?) {
            let callback = reply
            reply = nil
            deadline?.cancel()
            deadline = nil
            callback?(response, error)
        }
    }

    @MainActor
    final class Page {
        let appURL: URL
        var setupScope = DesktopControlSetupScope()
        fileprivate var permissionGeneration: UUID?
        fileprivate var didPrepare = false
        fileprivate var requiresExplicitPermissions = false
        fileprivate struct Preparation {
            let ticket: String
            let generation: UUID
            var installation: DesktopControlInstallation?
        }
        fileprivate var preparation: Preparation?
        private(set) var isRetired = false
        fileprivate var requests: [UUID: Request] = [:]

        fileprivate func cancelRequests(_ error: any Error = CancellationError()) {
            let pending = requests.values
            requests.removeAll()
            for request in pending { request.cancel(error) }
        }

        init(appURL: URL) { self.appURL = appURL }

        func retire() {
            isRetired = true
            setupScope.synchronize("")
            preparation = nil
            cancelRequests(DesktopControlPermissionBridgeError.scopeChanged)
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
        let presenter = CuaSetupWindow.shared
        presenter.onCancel = { [weak self] in
            guard let self, let page = self.permissionPage else { return }
            self.cancelPermissions(for: page)
            page.cancelRequests()
            page.setupScope.synchronize("")
        }
        cachedPermissionPresenter = presenter
        return presenter
    }
    private weak var permissionPage: Page?
    private var permissionRequest: UUID?
    private var activePrepare: UUID?
    private var completionDeadline: Task<Void, Never>?
    private let automaticRequestTimeout: Duration

    init(
        runtime: any DesktopControlSetupRuntime = DesktopControlRuntime.shared,
        enrollment: any DesktopControlSetupEnrollment = DesktopControlEnrollmentClient(),
        credentials: (any DesktopControlCredentialStoring)? = nil,
        preferences: UserDefaults = .standard,
        configurationProvider: @escaping () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() },
        permissionPresenter: (any DesktopControlPermissionPresenting)? = nil,
        automaticRequestTimeout: Duration = .seconds(60)
    ) {
        self.runtime = runtime
        self.enrollment = enrollment
        self.credentials = credentials
        self.preferences = preferences
        self.configurationProvider = configurationProvider
        self.cachedPermissionPresenter = permissionPresenter
        self.automaticRequestTimeout = automaticRequestTimeout
        super.init()
    }

    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        cancelPermissions(for: page)
        page.cancelRequests()
        page.setupScope.synchronize("")
    }

    func unregister(_ view: WKWebView) {
        if let page = pages.object(forKey: view) { cancelPermissions(for: page) }
        pages.object(forKey: view)?.retire()
        pages.removeObject(forKey: view)
    }

    func registeredPage(for view: WKWebView) -> Page? { pages.object(forKey: view) }

    func register(_ view: WKWebView, appURL: URL) {
        unregister(view)
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
        if case .sync(let scope) = command {
            if scope.isEmpty || page.setupScope.value != scope {
                cancelPermissions(for: page)
                page.cancelRequests()
            }
            page.setupScope.synchronize(scope)
            if !scope.isEmpty {
                replyHandler(Self.scopeReply, nil)
                return
            }
        }
        logger.notice("desktop control setup \(command.actionName, privacy: .public)")
        let id = UUID()
        let request = Request(command: command, reply: replyHandler)
        page.requests[id] = request
        switch command {
        case .cuaSetup(_, .open, _), .prepare: break // Human consent has no transport deadline.
        default: request.startDeadline(after: automaticRequestTimeout)
        }
        request.task = Task { @MainActor in
            defer { page.requests.removeValue(forKey: id); request.task = nil }
            do {
                try Task.checkCancellation()
                let response = try await apply(command, page: page, beginAutomaticWork: {
                    request.startDeadline(after: self.automaticRequestTimeout)
                })
                try Task.checkCancellation()
                request.finish(response)
            } catch {
                logger.error("desktop control setup \(command.actionName, privacy: .public) failed")
                request.fail(error)
            }
        }
    }

    func apply(_ command: DesktopControlSetupCommand, page: Page,
               beginAutomaticWork: (() -> Void)? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !page.isRetired else { throw DesktopControlEnrollmentError.invalidRequest }
        let credentials = credentials ?? FileDesktopControlCredentialStore(appURL: page.appURL)
        switch command {
        case .sync(let scope):
            if scope.isEmpty || page.setupScope.value != scope { cancelPermissions(for: page) }
            page.setupScope.synchronize(scope)
            let generation = page.setupScope.generation
            if scope.isEmpty {
                try await runtime.finishSetupIfIdle()
                try requireCurrentScope(scope, generation: generation, page: page)
            }
            return Self.scopeReply
        case .state(let scope):
            let generation = page.setupScope.generation
            try requireCurrentScope(scope, generation: generation, page: page)
            let installation = try await savedInstallation(credentials: credentials, appURL: page.appURL)
            try requireCurrentScope(scope, generation: generation, page: page)
            var configurationInUse = false
            if let installation {
                configurationInUse = try await enrollment.configurationState(installation: installation, appURL: page.appURL).hasConfig
                try requireCurrentScope(scope, generation: generation, page: page)
            }
            return [
                "ok": true,
                "operating_system": "macos",
                "cua_setup_version": "1",
                "setup_recovery_version": "1",
                "permissions_checklist_version": "1",
                "installation_id": installation?.installationID as Any? ?? NSNull(),
                "configuration_in_use": configurationInUse,
                "cua_ready": runtime.isCuaReady(),
                // Compatibility with the hosted page before its CUA-only release.
                // This mirrors CUA readiness and does not advertise native file/shell tools.
                "native_executor_ready": runtime.isCuaReady(),
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
            ]
        case .cuaSetup(let scope, let phase, let message):
            if phase != .repair { page.requiresExplicitPermissions = true }
            return try await permissions(scope: scope, phase: phase, message: message, page: page)
        case .prepare(let scope, let ticket):
            guard activePrepare == nil else { throw DesktopControlPermissionBridgeError.preparationPending }
            let preparation = UUID()
            activePrepare = preparation
            // Cancellation rejects the bridge reply immediately, but cannot prove a
            // remote mutation stopped. Keep exclusion until its actual await settles.
            defer { if activePrepare == preparation { activePrepare = nil } }
            let legacy = page.preparation == nil && !page.requiresExplicitPermissions
                && page.permissionGeneration == nil && permissionPage == nil
            if legacy {
                // Older hosted pages acquire the existing five-minute ticket first.
                // Keep the native Finish gate. The API still owns ticket expiry.
                _ = try await permissions(scope: scope, phase: .open, message: nil, page: page)
            }
            let legacyRequest = legacy ? permissionRequest : nil
            let legacyGeneration = page.setupScope.generation
            beginAutomaticWork?()
            do { return try await prepare(scope: scope, ticket: ticket, page: page, credentials: credentials) }
            catch {
                if legacy, !Task.isCancelled, let legacyRequest, permissionRequest == legacyRequest,
                   permissionPage === page, page.setupScope.generation == legacyGeneration {
                    completionDeadline?.cancel()
                    completionDeadline = nil
                    permissionPresenter.failSetup(message: "Desktop Control could not finish. Return to PersonaStack to check the connection and continue setup.")
                    page.permissionGeneration = nil
                    page.didPrepare = false
                    permissionPage = nil
                    permissionRequest = nil
                }
                if page.preparation != nil, !Task.isCancelled {
                    throw DesktopControlPermissionBridgeError.outcomeUnknown
                }
                throw error
            }
        }
    }

    private func prepare(scope: String, ticket: String, page: Page,
                         credentials: any DesktopControlCredentialStoring) async throws -> [String: Any] {
        let generation = page.setupScope.generation
        try requireCurrentScope(scope, generation: generation, page: page)
        let recovery = page.preparation
        if let recovery {
            guard recovery.ticket == ticket, recovery.generation == generation, recovery.installation != nil else {
                throw DesktopControlPermissionBridgeError.outcomeUnknown
            }
        } else {
            try requireFinishedPermissions(page: page, generation: generation)
        }
        let saved = try await savedInstallation(credentials: credentials, appURL: page.appURL)
        try requireCurrentScope(scope, generation: generation, page: page)
        if let recovery {
            guard saved == recovery.installation else { throw DesktopControlPermissionBridgeError.outcomeUnknown }
        } else {
            try requireFinishedPermissions(page: page, generation: generation)
            if let saved {
                try await runtime.disconnect()
                try requireCurrentScope(scope, generation: generation, page: page)
                page.preparation = .init(ticket: ticket, generation: generation)
                try await enrollment.attach(ticket: ticket, installation: saved, appURL: page.appURL)
                try confirmPreparation(saved, ticket: ticket, scope: scope, generation: generation, page: page)
                try requireCurrentScope(scope, generation: generation, page: page)
            }
        }
        let runtimeGeneration = try runtime.beginResume()
        try await runtime.resumeForSetup(generation: runtimeGeneration)
        try requireCurrentScope(scope, generation: generation, page: page)
        try requireCurrentLifecycle(runtimeGeneration)
        guard await runtime.refreshCuaReadiness() else {
            throw DesktopControlPermissionBridgeError.incomplete
        }
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
            page.preparation = .init(ticket: ticket, generation: generation)
            installation = try await enrollment.enroll(
                ticket: ticket,
                appURL: page.appURL,
                commitCredential: { [weak self] installation in
                    guard let self else { throw CancellationError() }
                    // Preserve an API-issued credential after a transport deadline
                    // only while its original page and runtime still own the attempt.
                    guard !page.isRetired else { throw CancellationError() }
                    try page.setupScope.require(scope, generation: generation)
                    try self.requireCurrentLifecycle(enrollmentRuntimeGeneration)
                    try credentials.save(installation)
                    try self.confirmPreparation(installation, ticket: ticket, scope: scope, generation: generation, page: page)
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
            // Compatibility with the hosted page before its CUA-only release.
            // This mirrors CUA readiness and does not advertise native file/shell tools.
            "native_executor_ready": runtime.isCuaReady(),
            "gateway_connected": runtime.gatewayConnected,
            "relay_paused": runtime.paused,
            "suggested_name": Self.suggestedComputerName(),
        ]
    }

    private func confirmPreparation(_ installation: DesktopControlInstallation, ticket: String,
                                    scope: String, generation: UUID, page: Page) throws {
        guard !page.isRetired, page.preparation?.ticket == ticket,
              page.preparation?.generation == generation else { throw CancellationError() }
        try page.setupScope.require(scope, generation: generation)
        page.preparation?.installation = installation
    }

    private static var scopeReply: [String: Any] {
        ["ok": true, "version": "1", "operating_system": "macos",
         "cua_setup_version": "1", "setup_recovery_version": "1", "permissions_checklist_version": "1"]
    }

    private func permissions(scope: String, phase: DesktopControlSetupCommand.PermissionPhase,
                             message: String?, page: Page) async throws -> [String: Any] {
        let generation = page.setupScope.generation
        guard !page.isRetired, page.setupScope.value == scope else {
            throw DesktopControlPermissionBridgeError.scopeChanged
        }
        if phase == .repair {
            guard permissionPage == nil, activePrepare == nil else { throw DesktopControlPermissionBridgeError.busy }
            permissionPresenter.presentForRepair()
            return Self.scopeReply
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
                startCompletionDeadline(for: page, request: request)
                return ["ok": true, "cua_setup_version": "1", "permissions_checklist_version": "1", "prerequisites_ready": true]
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
            try await requireCompletionReadiness(page: page)
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireFinishedPermissions(page: page, generation: generation, request: request)
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
            try await requireCompletionReadiness(page: page)
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireFinishedPermissions(page: page, generation: generation, request: request)
            permissionPresenter.completeSetup()
            page.preparation = nil
        } else {
            permissionPresenter.failSetup(message: message ?? "Desktop Control setup could not finish. Check the app connection and retry.")
        }
        completionDeadline?.cancel()
        completionDeadline = nil
        page.permissionGeneration = nil
        page.didPrepare = false
        permissionPage = nil
        permissionRequest = nil
        return Self.scopeReply
    }

    private func requireFinishedPermissions(page: Page, generation: UUID, request: UUID? = nil) throws {
        guard permissionPage === page, page.permissionGeneration == generation, permissionPresenter.isFinishing,
              request == nil || permissionRequest == request else {
            throw DesktopControlPermissionBridgeError.incomplete
        }
    }

    private func requireCompletionReadiness(page: Page) async throws {
        guard await runtime.refreshCuaReadiness(),
              page.didPrepare, runtime.gatewayConnected, runtime.isCuaReady() else {
            throw DesktopControlPermissionBridgeError.incomplete
        }
    }

    private func startCompletionDeadline(for page: Page, request: UUID) {
        completionDeadline?.cancel()
        completionDeadline = Task { @MainActor [weak self, weak page] in
            guard let duration = self?.automaticRequestTimeout else { return }
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, let page, self.permissionRequest == request,
                  self.permissionPage === page else { return }
            // A missing hosted callback must not strand the window in Connecting.
            // The web page retains the setup reference and reconciles API state.
            for pending in page.requests.values {
                switch pending.command {
                case .prepare, .cuaSetup(_, .completed, _):
                    pending.cancel(DesktopControlPermissionBridgeError.timedOut)
                default: break
                }
            }
            self.permissionPresenter.failSetup(message: DesktopControlPermissionBridgeError.timedOut.localizedDescription)
            page.permissionGeneration = nil
            page.didPrepare = false
            self.permissionPage = nil
            self.permissionRequest = nil
            self.completionDeadline = nil
        }
    }

    private func cancelPermissions(for page: Page) {
        page.preparation = nil
        page.permissionGeneration = nil
        page.didPrepare = false
        guard permissionPage === page else { return }
        completionDeadline?.cancel()
        completionDeadline = nil
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

    private func requireCurrentScope(_ scope: String, generation: UUID, page: Page) throws {
        try Task.checkCancellation()
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
