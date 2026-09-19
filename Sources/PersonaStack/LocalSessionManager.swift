import AppKit
import OSLog
import PersonaStackCore
import WebKit

@MainActor
final class LocalSessionManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = LocalSessionManager()
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "local-session")
    private final class Page {
        let appURL: URL
        var pending = LocalSessionPendingRequests()
        init(_ appURL: URL) { self.appURL = appURL }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let preferences: UserDefaults
    private let probe: @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe
    private let install: @MainActor (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles
    private let terminal: @MainActor (URL) async throws -> Void

    init(preferences: UserDefaults = .standard,
         probe: @escaping @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe = { try LocalSessionProbe.inspect($0) },
         install: @escaping @MainActor (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles = LocalSessionManager.installFiles,
         terminal: @escaping @MainActor (URL) async throws -> Void = LocalSessionManager.openTerminal) {
        self.preferences = preferences; self.probe = probe; self.install = install; self.terminal = terminal
        super.init()
    }

    func apply(_ command: LocalSessionCommand, view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view) else { throw LocalSessionError.invalidRequest }
        return try await apply(command, page: page)
    }

    func register(_ view: WKWebView, appURL: URL) { pages.setObject(Page(appURL), forKey: view) }
    func invalidateSession() {
        for page in pages.objectEnumerator()?.allObjects as? [Page] ?? [] { page.pending.sync("") }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view),
              ChatWindowManager.trusted(message, base: page.appURL) else {
            logger.error("local session bridge rejected an untrusted request")
            replyHandler(nil, LocalSessionError.invalidRequest.rawValue); return
        }
        do {
            let command = try LocalSessionCommand.parse(message.body)
            Task {
                do { replyHandler(try await apply(command, page: page), nil) }
                catch {
                    let failure = error as? LocalSessionError ?? .invalidRequest
                    logger.error("local session \(Self.actionName(command), privacy: .public) failed: \(failure.rawValue, privacy: .public)")
                    replyHandler(nil, failure.rawValue)
                }
            }
        } catch {
            logger.error("local session bridge rejected an invalid request")
            replyHandler(nil, LocalSessionError.invalidRequest.rawValue)
        }
    }

    private func apply(_ command: LocalSessionCommand, page: Page) async throws -> [String: Any] {
        let key = preferenceKey(page.appURL)
        switch command {
        case .state(let scope):
            page.pending.sync(scope)
            var response: [String: Any] = ["ok": true, "version": "1"]
            if let raw = preferences.string(forKey: key), let harness = LocalSessionHarness(rawValue: raw) {
                response["harness"] = harness.rawValue
            }
            return response
        case .select(let scope, let harness):
            guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
            preferences.set(harness.rawValue, forKey: key)
            return ["ok": true]
        case .prepare(let scope, let persona, let harness):
            guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
            let generation = page.pending.generation
            let probe = self.probe
            _ = try await Task.detached { try probe(harness) }.value
            guard page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
            let id = try page.pending.prepare(persona: persona, harness: harness)
            return ["ok": true, "pending_id": id.uuidString]
        case .launch(let scope, let id, let data):
            let bundle = try LocalSessionBundle.decode(data, appURL: page.appURL)
            try page.pending.consume(id, scope: scope, bundle: bundle)
            let generation = page.pending.generation
            let probe = self.probe
            let installation = try await Task.detached { try probe(bundle.harness) }.value
            guard page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
            let files = try install(bundle, page.appURL, id, installation)
            try await terminal(files.launcher)
            return ["ok": true]
        }
    }

    private static func installFiles(_ bundle: LocalSessionBundle, appURL: URL, id: UUID, installation: LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PersonaStackLocalSession"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw LocalSessionError.terminalUnavailable }
        return try LocalSessionFiles().install(bundle: bundle, appURL: appURL, home: installation.home,
            profile: installation.profile, sessionID: id, executable: installation.executable, helper: helper, loginShell: installation.shell)
    }

    private static func openTerminal(_ command: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw LocalSessionError.terminalUnavailable
        }
        do {
            _ = try await NSWorkspace.shared.open([command], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch { throw LocalSessionError.terminalUnavailable }
    }

    private func preferenceKey(_ url: URL) -> String {
        "localSession.harness." + (url.scheme ?? "") + "://" + (url.host ?? "") + ":" + String(url.port ?? 443)
    }

    private static func actionName(_ command: LocalSessionCommand) -> String {
        switch command {
        case .state: return "state"
        case .select: return "select_harness"
        case .prepare: return "prepare"
        case .launch: return "launch"
        }
    }
}
