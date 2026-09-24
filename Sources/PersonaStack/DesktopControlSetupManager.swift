import AppKit
import OSLog
import ServiceManagement
import PersonaStackCore
import WebKit

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

    private final class Page {
        let appURL: URL
        var scope = ""
        var generation = UUID()

        init(appURL: URL) { self.appURL = appURL }
    }

    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "desktop-control-setup")
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let enrollment = DesktopControlEnrollmentClient()
    private let runtime: DesktopControlRuntime

    init(runtime: DesktopControlRuntime = .shared) {
        self.runtime = runtime
        super.init()
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
        guard let command = try? DesktopControlSetupCommand.parse(message.body) else {
            replyHandler(nil, DesktopControlEnrollmentError.invalidRequest.localizedDescription)
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

    private func apply(_ command: DesktopControlSetupCommand, page: Page) async throws -> [String: Any] {
        switch command {
        case .sync(let scope):
            if page.scope != scope {
                page.scope = scope
                page.generation = UUID()
            }
            return ["ok": true, "version": "1"]
        case .state(let scope):
            try requireCurrentScope(scope, page: page)
            let installation = try KeychainDesktopControlCredentialStore().load()
            return [
                "ok": true,
                "installation_id": installation?.installationID as Any? ?? NSNull(),
                "cua_ready": runtime.isCuaReady(),
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
            ]
        case .prepare(let scope, let ticket):
            try requireCurrentScope(scope, page: page)
            let generation = page.generation
            var runtimeGeneration = try runtime.beginResume()
            do {
                try await runtime.resume(generation: runtimeGeneration)
            } catch {
                try requireCurrentScope(scope, generation: generation, page: page)
                try requireCurrentLifecycle(runtimeGeneration)
                guard DesktopControlRuntime.shouldForceRepair(after: error) else { throw error }
                runtimeGeneration = try await runtime.repair(resumeRelay: true, expectedGeneration: runtimeGeneration)
            }
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
            do { try SMAppService.mainApp.register() }
            catch { throw DesktopControlEnrollmentError.serviceRegistrationFailed }
            try requireCurrentScope(scope, generation: generation, page: page)
            try requireCurrentLifecycle(runtimeGeneration)
            let saved = try KeychainDesktopControlCredentialStore().load()
            let installation: DesktopControlInstallation
            if let saved {
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
                        try KeychainDesktopControlCredentialStore().save(installation)
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
            UserDefaults.standard.set(true, forKey: "desktopControlRelayEnabled")
            UserDefaults.standard.set(false, forKey: "desktopControlRelayPaused")
            return [
                "ok": true,
                "installation_id": installation.installationID,
                "cua_ready": runtime.isCuaReady(),
                "gateway_connected": runtime.gatewayConnected,
                "relay_paused": runtime.paused,
            ]
        }
    }

    private func requireCurrentScope(_ scope: String, page: Page) throws {
        try requireCurrentScope(scope, generation: page.generation, page: page)
    }

    private func requireCurrentScope(_ scope: String, generation: UUID, page: Page) throws {
        guard page.scope == scope, page.generation == generation else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
    }

    private func requireCurrentLifecycle(_ generation: UUID) throws {
        guard runtime.isCurrentLifecycle(generation) else { throw CancellationError() }
    }
}
