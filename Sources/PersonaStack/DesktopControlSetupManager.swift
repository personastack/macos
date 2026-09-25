import AppKit
import OSLog
import ServiceManagement
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
    func finishSetupIfIdle() async
    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID
    func isCurrentLifecycle(_ generation: UUID) -> Bool
    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async
}

protocol DesktopControlSetupEnrollment: DesktopControlRelayStateReading {
    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?
    ) async throws -> DesktopControlInstallation
    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws
    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws
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
    case sync(scope: String)
    case state(scope: String)
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
            guard !scope.isEmpty, Set(object.keys) == ["version", "action", "scope"] else { throw DesktopControlEnrollmentError.invalidRequest }
            return .state(scope: scope)
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
        case .prepare: "prepare"
        }
    }
}

@MainActor
final class DesktopControlSetupManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = DesktopControlSetupManager()

    final class Page {
        let appURL: URL
        var setupScope = DesktopControlSetupScope()

        init(appURL: URL) { self.appURL = appURL }
    }

    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-setup")
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let enrollment: any DesktopControlSetupEnrollment
    private let credentials: (any DesktopControlCredentialStoring)?
    private let registerLoginItem: @MainActor () throws -> Void
    private let loginItemStatus: @MainActor () -> SMAppService.Status
    private let preferences: UserDefaults
    private let runtime: any DesktopControlSetupRuntime

    init(
        runtime: any DesktopControlSetupRuntime = DesktopControlRuntime.shared,
        enrollment: any DesktopControlSetupEnrollment = DesktopControlEnrollmentClient(),
        credentials: (any DesktopControlCredentialStoring)? = nil,
        preferences: UserDefaults = .standard,
        registerLoginItem: @escaping @MainActor () throws -> Void = { try SMAppService.mainApp.register() },
        loginItemStatus: @escaping @MainActor () -> SMAppService.Status = { SMAppService.mainApp.status }
    ) {
        self.runtime = runtime
        self.enrollment = enrollment
        self.credentials = credentials
        self.preferences = preferences
        self.registerLoginItem = registerLoginItem
        self.loginItemStatus = loginItemStatus
        super.init()
    }

    func invalidate(_ view: WKWebView) {
        pages.object(forKey: view)?.setupScope.synchronize("")
    }

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
        guard let command = try? DesktopControlSetupCommand.parse(body) else {
            replyHandler(nil, DesktopControlEnrollmentError.invalidRequest.localizedDescription)
            return
        }
        if case .sync(let scope) = command, !scope.isEmpty {
            page.setupScope.synchronize(scope)
            replyHandler(["ok": true, "version": "1"], nil)
            return
        }
        logger.notice("desktop control setup \(command.actionName, privacy: .public)")
        Task { @MainActor in
            do {
                let response = try await apply(command, page: page)
                replyHandler(response, nil)
            } catch {
                let safeMessage = (error as? LocalizedError)?.errorDescription
                    ?? DesktopControlEnrollmentError.rejected.localizedDescription
                logger.error("desktop control setup \(command.actionName, privacy: .public) failed")
                replyHandler(nil, safeMessage)
            }
        }
    }

    func apply(_ command: DesktopControlSetupCommand, page: Page) async throws -> [String: Any] {
        let credentials = credentials ?? KeychainDesktopControlCredentialStore(appURL: page.appURL)
        switch command {
        case .sync(let scope):
            page.setupScope.synchronize(scope)
            if scope.isEmpty { await runtime.finishSetupIfIdle() }
            return ["ok": true, "version": "1"]
        case .state(let scope):
            try page.setupScope.require(scope)
            let installation = try credentials.load()
            return [
                "ok": true,
                "installation_id": installation?.installationID as Any? ?? NSNull(),
                "cua_ready": runtime.isCuaReady(),
                "native_executor_ready": runtime.nativeExecutorReady,
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
            ]
        case .prepare(let scope, let ticket):
            let generation = page.setupScope.generation
            try page.setupScope.require(scope, generation: generation)
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
            if loginItemStatus() != .enabled {
                do { try registerLoginItem() }
                catch { throw DesktopControlEnrollmentError.serviceRegistrationFailed }
            }
            guard loginItemStatus() == .enabled else {
                throw DesktopControlLoginItemApprovalError()
            }
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
            let saved = try credentials.load()
            let installation: DesktopControlInstallation
            if let saved {
                try saved.requireEnvironment(page.appURL)
                installation = saved
                try await enrollment.reportReady(installation: installation, appURL: page.appURL)
                try requireCurrentScope(scope, generation: generation, page: page)
                try requireCurrentLifecycle(runtimeGeneration)
                try await enrollment.attach(ticket: ticket, installation: installation, appURL: page.appURL)
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
            preferences.set(true, forKey: "desktopControlRelayEnabled")
            preferences.set(false, forKey: "desktopControlRelayPaused")
            return [
                "ok": true,
                "installation_id": installation.installationID,
                "cua_ready": runtime.isCuaReady(),
                "native_executor_ready": runtime.nativeExecutorReady,
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
                "suggested_name": Self.suggestedComputerName(),
            ]
        }
    }

    private func requireCurrentScope(_ scope: String, page: Page) throws {
        try requireCurrentScope(scope, generation: page.setupScope.generation, page: page)
    }

    private func requireCurrentScope(_ scope: String, generation: UUID, page: Page) throws {
        try page.setupScope.require(scope, generation: generation)
    }

    private func requireCurrentLifecycle(_ generation: UUID) throws {
        guard runtime.isCurrentLifecycle(generation) else { throw CancellationError() }
    }

    private static func suggestedComputerName() -> String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(name.prefix(120))
    }
}

private struct DesktopControlLoginItemApprovalError: LocalizedError {
    var errorDescription: String? {
        "Allow PersonaStack Desktop in System Settings → General → Login Items & Extensions, then retry setup."
    }
}
