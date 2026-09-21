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
    private var configuringProfiles = Set<String>()
    private let preferences: UserDefaults
    private let probe: @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe
    private let preflight: @Sendable (LocalSessionHarness, LocalSessionHarnessProbe) throws -> Void
    private let install: @Sendable (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles

    init(preferences: UserDefaults = .standard,
         probe: @escaping @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe = { try LocalSessionProbe.inspect($0) },
         preflight: @escaping @Sendable (LocalSessionHarness, LocalSessionHarnessProbe) throws -> Void = LocalSessionManager.preflightFiles,
         install: @escaping @Sendable (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles = LocalSessionManager.installFiles) {
        self.preferences = preferences; self.probe = probe; self.preflight = preflight; self.install = install
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
                do {
                    let response = try await apply(command, page: page)
                    logger.notice("local session \(Self.actionName(command), privacy: .public) completed")
                    replyHandler(response, nil)
                }
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
            let installation = try await Task.detached { try probe(harness) }.value
            let preflight = self.preflight
            _ = try await Task.detached { try preflight(harness, installation) }.value
            guard page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
            let id = try page.pending.prepare(persona: persona, harness: harness)
            return ["ok": true, "pending_id": id.uuidString]
        case .configure(let scope, let id, let data):
            let bundle = try LocalSessionBundle.decode(data, appURL: page.appURL)
            try page.pending.consume(id, scope: scope, bundle: bundle)
            let generation = page.pending.generation
            let probe = self.probe
            let installation = try await Task.detached { try probe(bundle.harness) }.value
            guard page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
            let profileKey = installation.profile.resolvingSymlinksInPath().standardizedFileURL.path
            guard configuringProfiles.insert(profileKey).inserted else { throw LocalSessionError.staleRequest }
            defer { configuringProfiles.remove(profileKey) }
            let install = self.install
            let appURL = page.appURL
            _ = try await Task.detached { try install(bundle, appURL, id, installation) }.value
            return ["ok": true]
        }
    }

    nonisolated private static func installFiles(_ bundle: LocalSessionBundle, appURL: URL, id: UUID, installation: LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles {
        return try LocalSessionFiles().configure(bundle: bundle, appURL: appURL, home: installation.home,
            profile: installation.profile, sessionID: id, executable: installation.executable, loginShell: installation.shell, harnessEnvironment: installation.environment)
    }

    nonisolated private static func preflightFiles(_ harness: LocalSessionHarness, installation: LocalSessionHarnessProbe) throws {
        try LocalSessionFiles().preflight(harness, probe: installation)
    }

    private func preferenceKey(_ url: URL) -> String {
        "localSession.harness." + (url.scheme ?? "") + "://" + (url.host ?? "") + ":" + String(url.port ?? 443)
    }

    private static func actionName(_ command: LocalSessionCommand) -> String {
        switch command {
        case .state: return "state"
        case .select: return "select_harness"
        case .prepare: return "prepare"
        case .configure: return "configure"
        }
    }
}
