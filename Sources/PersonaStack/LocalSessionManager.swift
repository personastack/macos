import AppKit
import OSLog
import PersonaStackCore
import WebKit

@MainActor
final class LocalSessionManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = LocalSessionManager(validateMCP: LocalSessionMCPRedirectValidator.validate)
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "local-session")
    private final class Page {
        let appURL: URL
        var pending = LocalSessionPendingRequests()
        var profiles: [LocalSessionHarness: [UUID: LocalSessionProfileTarget]] = [:]
        var selectedProfiles: [LocalSessionHarness: UUID] = [:]
        private(set) var isRetired = false
        init(_ appURL: URL) { self.appURL = appURL }

        func retire() {
            isRetired = true
            pending.sync("")
        }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private var configuringProfiles = Set<String>()
    private var inFlightInstalls: [UUID: Task<LocalSessionInstalledFiles, Error>] = [:]
    private let preferences: UserDefaults
    private let probe: @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe
    private let preflight: @Sendable (LocalSessionHarness, LocalSessionHarnessProbe) throws -> Void
    private let install: @Sendable (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles
    private let storeCredential: @Sendable (LocalSessionBundle, URL) throws -> Void
    private let revokeCredential: @Sendable (String) async throws -> Void
    private let removeFiles: @Sendable (String, LocalSessionHarness, LocalSessionHarnessProbe, URL) throws -> Void
    private let removeCredential: @Sendable (String) throws -> Void
    private let validateMCP: @Sendable (URL) async throws -> Void

    init(preferences: UserDefaults = .standard,
         probe: @escaping @Sendable (LocalSessionHarness) throws -> LocalSessionHarnessProbe = { try LocalSessionProbe.inspect($0) },
         preflight: @escaping @Sendable (LocalSessionHarness, LocalSessionHarnessProbe) throws -> Void = LocalSessionManager.preflightFiles,
         install: @escaping @Sendable (LocalSessionBundle, URL, UUID, LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles = LocalSessionManager.installFiles,
         validateMCP: @escaping @Sendable (URL) async throws -> Void = { _ in },
         storeCredential: @escaping @Sendable (LocalSessionBundle, URL) throws -> Void = LocalSessionManager.saveCredential,
         revokeCredential: @escaping @Sendable (String) async throws -> Void = LocalSessionManager.revokeConnection,
         removeFiles: @escaping @Sendable (String, LocalSessionHarness, LocalSessionHarnessProbe, URL) throws -> Void = { id, harness, probe, appURL in
             try LocalSessionFiles().remove(id, harness: harness, probe: probe, appURL: appURL)
         },
         removeCredential: @escaping @Sendable (String) throws -> Void = { try HarnessActivityKeychain().remove($0) }) {
        self.storeCredential = storeCredential; self.revokeCredential = revokeCredential
        self.removeFiles = removeFiles; self.removeCredential = removeCredential
        self.preferences = preferences; self.probe = probe; self.preflight = preflight; self.install = install; self.validateMCP = validateMCP
        super.init()
    }

    func apply(_ command: LocalSessionCommand, view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view) else { throw LocalSessionError.invalidRequest }
        return try await apply(command, page: page)
    }

    func register(_ view: WKWebView, appURL: URL) { pages.setObject(Page(appURL), forKey: view) }
    func invalidate(_ view: WKWebView) {
        pages.object(forKey: view)?.retire()
        pages.removeObject(forKey: view)
    }

    func invalidateAndWait(_ view: WKWebView) async {
        invalidate(view)
        let installs = Array(inFlightInstalls.values)
        for install in installs { _ = try? await install.value }
    }
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
            logger.notice("local session \(Self.actionName(command), privacy: .public) started")
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
            logger.error("local session bridge rejected \(Self.actionName(message.body), privacy: .public) request: invalidRequest")
            replyHandler(nil, LocalSessionError.invalidRequest.rawValue)
        }
    }

    private func apply(_ command: LocalSessionCommand, page: Page) async throws -> [String: Any] {
        guard !page.isRetired else { throw LocalSessionError.staleRequest }
        let key = preferenceKey(page.appURL)
        switch command {
        case .state(let scope):
            page.pending.sync(scope)
            var response: [String: Any] = ["ok": true, "version": "2"]
            if let raw = preferences.string(forKey: key), let harness = LocalSessionHarness(rawValue: raw) {
                response["harness"] = harness.rawValue
            }
            return response
        case .select(let scope, let harness):
            guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
            preferences.set(harness.rawValue, forKey: key)
            return ["ok": true]
        case .profiles(let scope, let harness):
            return try await listProfiles(scope: scope, harness: harness, page: page)
        case .selectProfile(let scope, let harness, let id):
            return try await selectProfile(scope: scope, harness: harness, id: id, page: page)
        case .connections(let scope, let harness):
            guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
            let installation = try await installation(harness, page: page)
            let appURL = page.appURL
            let records = try await Task.detached { try LocalSessionFiles().connections(harness, probe: installation, appURL: appURL) }.value
            let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
            return ["ok": true, "connections": values]
        case .remove(let scope, let harness, let id):
            return try await remove(scope: scope, harness: harness, id: id, page: page)
        case .check(let scope, let harness, let id), .reconnect(let scope, let harness, let id):
            guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
            let reconnect: Bool
            if case .reconnect = command { reconnect = true } else { reconnect = false }
            let installation = try await installation(harness, page: page)
            let appURL = page.appURL
            try await Task.detached { try LocalSessionFiles().check(id.uuidString.lowercased(), harness: harness, probe: installation, appURL: appURL, reconnect: reconnect) }.value
            return ["ok": true, "message": "MCP configuration and hook files verified. Live hook dispatch requires a trusted harness session."]
        case .prepare(let scope, let persona, let harness, let workspace):
            return try await prepare(scope: scope, persona: persona, harness: harness, workspace: workspace, page: page)
        case .configure(let scope, let id, let data):
            return try await configure(scope: scope, id: id, data: data, page: page)
        }
    }

    private func listProfiles(scope: String, harness: LocalSessionHarness, page: Page) async throws -> [String: Any] {
        guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
        let generation = page.pending.generation
        let probe = self.probe
        let targets = try await Task.detached { LocalSessionProbe.profiles(harness, current: try probe(harness)) }.value
        try requireCurrent(page, scope: scope, generation: generation)
        let previous = page.profiles[harness] ?? [:]
        var choices: [UUID: LocalSessionProfileTarget] = [:]
        var values: [[String: String]] = []
        for target in targets {
            let id = previous.first { Self.sameProfile($0.value, target) }?.key ?? UUID()
            choices[id] = target
            values.append(["profile_id": id.uuidString.lowercased(), "label": target.label])
        }
        if let selected = page.selectedProfiles[harness], choices[selected] == nil {
            page.pending.invalidate()
            page.selectedProfiles[harness] = nil
        }
        page.profiles[harness] = choices
        if page.selectedProfiles[harness] == nil {
            page.selectedProfiles[harness] = values.first.flatMap { UUID(uuidString: $0["profile_id"] ?? "") }
        }
        return ["ok": true, "profiles": values, "profile_id": page.selectedProfiles[harness]!.uuidString.lowercased()]
    }

    private func selectProfile(scope: String, harness: LocalSessionHarness, id: UUID, page: Page) async throws -> [String: Any] {
        guard page.pending.scope == scope, let target = page.profiles[harness]?[id] else { throw LocalSessionError.staleRequest }
        _ = try await installation(harness, page: page, target: target)
        guard page.profiles[harness]?[id].map({ Self.sameProfile($0, target) }) == true else { throw LocalSessionError.staleRequest }
        page.pending.invalidate()
        page.selectedProfiles[harness] = id
        return ["ok": true]
    }

    private func remove(scope: String, harness: LocalSessionHarness, id: UUID, page: Page) async throws -> [String: Any] {
        guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
        let generation = page.pending.generation
        let appURL = page.appURL
        let installation = try await installation(harness, page: page)
        let profileKey = installation.profile.resolvingSymlinksInPath().path
        guard configuringProfiles.insert(profileKey).inserted else { throw LocalSessionError.staleRequest }
        defer { configuringProfiles.remove(profileKey) }
        try await Task.detached { try LocalSessionFiles().validateRemoval(id.uuidString.lowercased(), harness: harness, probe: installation, appURL: appURL) }.value
        try requireCurrent(page, scope: scope, generation: generation)
        if let legacy = try await Task.detached(operation: { try LocalSessionFiles().legacyCredential(id.uuidString.lowercased(), harness: harness, probe: installation, appURL: appURL) }).value {
            try await HarnessActivityReporter.revoke(legacy)
        } else { try await revokeCredential(id.uuidString.lowercased()) }
        try requireCurrent(page, scope: scope, generation: generation)
        let current = try await self.installation(harness, page: page)
        guard current.profile == installation.profile, current.executable == installation.executable else { throw LocalSessionError.staleRequest }
        let removeFiles = self.removeFiles
        try await Task.detached { try removeFiles(id.uuidString.lowercased(), harness, installation, appURL) }.value
        try removeCredential(id.uuidString.lowercased())
        return ["ok": true]
    }

    private func prepare(scope: String, persona: String, harness: LocalSessionHarness, workspace: String, page: Page) async throws -> [String: Any] {
        guard page.pending.scope == scope else { throw LocalSessionError.staleRequest }
        let generation = page.pending.generation
        logger.notice("local session prepare CLI probe started")
        let installation = try await installation(harness, page: page)
        logger.notice("local session prepare CLI probe completed")
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
        let preflight = self.preflight
        logger.notice("local session prepare plugin preflight started")
        _ = try await Task.detached { try preflight(harness, installation) }.value
        logger.notice("local session prepare plugin preflight completed")
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
        let appURL = page.appURL
        let existing = try await Task.detached { try LocalSessionFiles().connections(harness, probe: installation, appURL: appURL).first { $0.personaID == persona && $0.workspaceID == workspace } }.value
        try requireCurrent(page, scope: scope, generation: generation)
        if let existing { try await revokeCredential(existing.connectionID) }
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
        let id = try page.pending.prepare(persona: persona, harness: harness, workspace: workspace, profile: installation.profile.resolvingSymlinksInPath().path, id: existing.flatMap { UUID(uuidString: $0.connectionID) })
        return ["ok": true, "pending_id": id.uuidString, "connection_id": id.uuidString.lowercased()]
    }

    private func configure(scope: String, id: UUID, data: Data, page: Page) async throws -> [String: Any] {
        logger.notice("local session configure bundle validation started")
        let bundle = try LocalSessionBundle.decode(data, appURL: page.appURL)
        logger.notice("local session configure bundle validation completed")
        let preparation = try page.pending.consume(id, scope: scope, bundle: bundle)
        guard let mcpURL = URL(string: bundle.mcpURL) else { throw LocalSessionError.invalidBundle }
        let generation = page.pending.generation
        try await validateMCP(mcpURL)
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
        logger.notice("local session configure CLI probe started")
        let installation = try await installation(bundle.harness, page: page)
        logger.notice("local session configure CLI probe completed")
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
        let profileKey = installation.profile.resolvingSymlinksInPath().standardizedFileURL.path
        guard profileKey == preparation.profile else { throw LocalSessionError.staleRequest }
        guard configuringProfiles.insert(profileKey).inserted else { throw LocalSessionError.staleRequest }
        defer { configuringProfiles.remove(profileKey) }
        let install = self.install
        let appURL = page.appURL
        logger.notice("local session configure plugin installation started")
        let credentialStore = self.storeCredential
        let installTask = Task.detached {
            try credentialStore(bundle, appURL)
            return try install(bundle, appURL, UUID(), installation)
        }
        let installID = UUID()
        inFlightInstalls[installID] = installTask
        defer { inFlightInstalls.removeValue(forKey: installID) }
        _ = try await installTask.value
        logger.notice("local session configure plugin installation completed")
        return ["ok": true]
    }

    nonisolated private static func saveCredential(_ bundle: LocalSessionBundle, appURL: URL) throws {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("PersonaStackHarnessHook")
        try HarnessActivityKeychain().store(.init(bundle: bundle, appURL: appURL), helperURL: helper)
    }

    nonisolated private static func revokeConnection(_ id: String) async throws {
        let credential = try HarnessActivityKeychain().read(id)
        try await HarnessActivityReporter.revoke(credential)
    }

    nonisolated private static func installFiles(_ bundle: LocalSessionBundle, appURL: URL, id: UUID, installation: LocalSessionHarnessProbe) throws -> LocalSessionInstalledFiles {
        return try LocalSessionFiles().configure(bundle: bundle, appURL: appURL, home: installation.home,
            profile: installation.profile, sessionID: id, executable: installation.executable, loginShell: installation.shell, harnessEnvironment: installation.environment)
    }

    nonisolated private static func preflightFiles(_ harness: LocalSessionHarness, installation: LocalSessionHarnessProbe) throws {
        try LocalSessionFiles().preflight(harness, probe: installation)
    }

    private func installation(_ harness: LocalSessionHarness, page: Page,
                              target: LocalSessionProfileTarget? = nil) async throws -> LocalSessionHarnessProbe {
        let scope = page.pending.scope
        let generation = page.pending.generation
        let selected = target ?? page.selectedProfiles[harness].flatMap { page.profiles[harness]?[$0] }
        let probe = self.probe
        let targets = try await Task.detached { LocalSessionProbe.profiles(harness, current: try probe(harness)) }.value
        try requireCurrent(page, scope: scope, generation: generation)
        guard let selected else { return targets[0].installation }
        guard let current = targets.first(where: { Self.sameProfile($0, selected) && (!selected.directoryExists || $0.directoryExists) }) else { throw LocalSessionError.staleRequest }
        return current.installation
    }

    private func requireCurrent(_ page: Page, scope: String, generation: UUID) throws {
        guard !page.isRetired, page.pending.scope == scope, page.pending.generation == generation else { throw LocalSessionError.staleRequest }
    }

    private static func sameProfile(_ first: LocalSessionProfileTarget, _ second: LocalSessionProfileTarget) -> Bool {
        first.source == second.source && first.installation.profile == second.installation.profile &&
            first.installation.executable == second.installation.executable
    }

    private func preferenceKey(_ url: URL) -> String {
        "localSession.harness." + (url.scheme ?? "") + "://" + (url.host ?? "") + ":" + String(url.port ?? (url.scheme == "http" ? 80 : 443))
    }

    private static func actionName(_ command: LocalSessionCommand) -> String {
        switch command {
        case .state: return "state"
        case .select: return "select_harness"
        case .profiles: return "profiles"
        case .selectProfile: return "select_profile"
        case .prepare: return "prepare"
        case .configure: return "configure"
        case .connections: return "connections"
        case .remove: return "remove"
        case .check: return "check"
        case .reconnect: return "reconnect"
        }
    }

    private static func actionName(_ body: Any) -> String {
        guard let object = body as? [String: Any], let action = object["action"] as? String else { return "unknown" }
        switch action {
        case "state", "select_harness", "prepare", "configure": return action
        case "launch": return "legacy_launch"
        default: return "unknown"
        }
    }
}

enum LocalSessionMCPRedirectValidator {
    static func validate(_ url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        let session = DesktopControlNetworkSession.makeWithoutRedirects()
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LocalSessionError.mcpUnavailable }
            guard !(300..<400).contains(response.statusCode) else { throw LocalSessionError.mcpRedirect }
        } catch let error as LocalSessionError {
            throw error
        } catch {
            throw LocalSessionError.mcpUnavailable
        }
    }
}
