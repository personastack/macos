import AppKit
import CryptoKit
import Foundation
import PersonaStackCore
import WebKit

@MainActor
final class AgentBridgeSetupManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = AgentBridgeSetupManager()
    @MainActor private final class Page {
        let configuration: DesktopEnvironmentConfiguration
        var authority = AgentBridgeDocumentScope()
        var profiles: [String: AgentBridgeProfile] = [:]
        var preparedPersonas: [UUID: String] = [:]
        var migrations: [UUID: (AgentBridgeMigrationCoordinator, AgentBridgeMigrationCoordinator.Cutover)] = [:]
        var migrating = false
        var pendingMigration: (persona: String, profile: String, coordinator: AgentBridgeMigrationCoordinator, cutover: AgentBridgeMigrationCoordinator.Cutover)?
        var cookiesFingerprint: Data?
        var retired = false
        init(_ configuration: DesktopEnvironmentConfiguration) { self.configuration = configuration }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let service: AgentBridgeService
    private let client: AgentBridgeControlClient
    private let hosted: AgentBridgeHostedAuthority
    private let configuration: @MainActor (URL) throws -> DesktopEnvironmentConfiguration
    private let approveEnvironment: @MainActor (DesktopEnvironmentConfiguration) throws -> Void
    private let prepareBackgroundEnable: @MainActor () throws -> Void
    private let cookieReader: @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String
    private let confirmRuntimeStart: @MainActor (String) -> Bool
    private let csrfReader: @MainActor (WKWebView) async throws -> String

    init(service: AgentBridgeService = .shared, client: AgentBridgeControlClient = AgentBridgeControlClient(),
         hosted: AgentBridgeHostedAuthority = AgentBridgeHostedAuthority(),
         configuration: @escaping @MainActor (URL) throws -> DesktopEnvironmentConfiguration = {
             try DesktopEnvironmentConfigurationStore.shared.environment(for: $0)
         }, approveEnvironment: @escaping @MainActor (DesktopEnvironmentConfiguration) throws -> Void = { try AgentBridgeEnvironments.approve($0) },
         prepareBackgroundEnable: @escaping @MainActor () throws -> Void = { try DesktopUpdater.shared.prepareToEnableBackgroundAgents() },
         cookieReader: @escaping @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = AgentBridgeSetupManager.readCookies,
         confirmRuntimeStart: @escaping @MainActor (String) -> Bool = AgentBridgeSetupManager.confirmStart,
         csrfReader: @escaping @MainActor (WKWebView) async throws -> String = AgentBridgeSetupManager.readCSRF) {
        self.service = service; self.client = client; self.hosted = hosted; self.configuration = configuration
        self.approveEnvironment = approveEnvironment; self.prepareBackgroundEnable = prepareBackgroundEnable; self.cookieReader = cookieReader
        self.confirmRuntimeStart = confirmRuntimeStart
        self.csrfReader = csrfReader
    }
    func register(_ view: WKWebView, appURL: URL) {
        guard let configuration = try? configuration(appURL) else { return }
        pages.setObject(Page(configuration), forKey: view)
    }
    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        page.authority.invalidate(); page.profiles.removeAll(); page.preparedPersonas.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
    }
    func unregister(_ view: WKWebView) {
        pages.object(forKey: view)?.retired = true
        invalidate(view); pages.removeObject(forKey: view)
    }
    func invalidateSession() {
        for page in pages.objectEnumerator()?.allObjects as? [Page] ?? [] {
            page.authority.invalidate(); page.profiles.removeAll(); page.preparedPersonas.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
        }
    }
    func apply(_ command: AgentBridgePageCommand, view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view), !page.retired else { throw AgentBridgeFailure.invalidRequest }
        return try await apply(command, page: page, view: view)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view),
              !page.retired, ChatWindowManager.trusted(message, base: page.configuration.appURL) else {
            replyHandler(nil, AgentBridgeFailure.invalidRequest.rawValue); return
        }
        do {
            let command = try AgentBridgePageCommand.parse(message.body)
            Task {
                do { replyHandler(try await apply(command, page: page, view: view), nil) }
                catch {
                    let failure: AgentBridgeFailure = page.pendingMigration == nil ? (error as? AgentBridgeFailure ?? .serviceUnavailable) : .migrationIncomplete
                    replyHandler(nil, failure.rawValue)
                }
            }
        } catch { replyHandler(nil, AgentBridgeFailure.invalidRequest.rawValue) }
    }

    private func apply(_ command: AgentBridgePageCommand, page: Page, view: WKWebView) async throws -> [String: Any] {
        if command.action == "state" {
            guard command.scope.isEmpty || command.scope == page.authority.scope else { throw AgentBridgeFailure.scopeChanged }
            if page.authority.scope.isEmpty { page.authority.synchronize(UUID().uuidString.lowercased()) }
            return ["ok": true, "capability": ["version": "1", "runtime_kinds": ["hermes", "openclaw"],
                                                   "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"],
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                    "scope": page.authority.scope, "background_status": backgroundStatus]
        }
        let document = page.authority.documentID
        try page.authority.requireCurrent(scope: command.scope, documentID: document)
        let cookies = try await cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        switch command.action {
        case "discover": return try await discover(command, page: page, document: document)
        case "migration_prepare": return try await migrate(command, page: page, cookies: cookies, document: document, view: view)
        case "prepare": return try await prepare(command, page: page, cookies: cookies, document: document, view: view)
        case "enroll": return try await enroll(command, page: page, document: document)
        case "connections": return try await connections(page: page, cookies: cookies, scope: command.scope, document: document)
        default: return try await manage(command, page: page, cookies: cookies, document: document, view: view)
        }
    }

    private var backgroundStatus: String {
        switch service.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires_approval"
        case .notRegistered, .notFound: "disabled"
        @unknown default: "unavailable"
        }
    }

    private func ready(_ page: Page, scope: String, document: UUID) async throws {
        try prepareBackgroundEnable()
        try approveEnvironment(page.configuration)
        try await service.ensureEnabled()
        try current(page, scope: scope, document: document)
    }

    private func discover(_ command: AgentBridgePageCommand, page: Page, document: UUID) async throws -> [String: Any] {
        try await ready(page, scope: command.scope, document: document)
        let request = try AgentBridgeRequest(operation: "discover", payload: [
            "environment_id": .string(page.configuration.appOrigin), "runtime_kind": .string(command.runtime!.rawValue)
        ])
        let result = try await client.send(request, returning: AgentBridgeDiscovery.self)
        try current(page, scope: command.scope, document: document)
        guard Set(result.profiles.map(\.profileCandidateID)).count == result.profiles.count,
              result.profiles.allSatisfy({ $0.runtimeKind == command.runtime }) else { throw AgentBridgeFailure.invalidRequest }
        page.profiles = Dictionary(uniqueKeysWithValues: result.profiles.map { ($0.profileCandidateID, $0) })
        return ["ok": true, "discovery_status": result.discoveryStatus, "profiles": result.profiles.map { profile in
            var value: [String: Any] = ["profile_candidate_id": profile.profileCandidateID,
                                        "account_candidate_id": profile.accountCandidateID, "label": profile.label,
                                        "runtime_kind": profile.runtimeKind.rawValue, "available": profile.conflictCode == nil]
            if let conflict = profile.conflictCode { value["conflict_code"] = conflict }
            return value
        }]
    }

    private func prepare(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView, canRecoverMigration: Bool = true) async throws -> [String: Any] {
        guard let profile = command.profileCandidateID, let candidate = page.profiles[profile],
              candidate.runtimeKind == command.runtime else { throw AgentBridgeFailure.scopeChanged }
        if let pending = page.pendingMigration {
            guard pending.persona == command.personaID, pending.profile == profile else { throw AgentBridgeFailure.scopeChanged }
            try await pending.coordinator.ensureRevoked()
        }
        try await ready(page, scope: command.scope, document: document)
        let request = try AgentBridgeRequest(operation: "prepare", payload: [
            "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(command.workspaceID!),
            "persona_id": .string(command.personaID!), "runtime_kind": .string(command.runtime!.rawValue),
            "profile_candidate_id": .string(profile), "document_id": .string(document.uuidString.lowercased())
        ])
        let result = try await client.send(request, returning: AgentBridgePreparation.self)
        try current(page, scope: command.scope, document: document)
        if result.migrationPending == true {
            guard canRecoverMigration else { throw AgentBridgeFailure.migrationIncomplete }
            try await recoverMigration(command, page: page, cookies: cookies, document: document, view: view)
            return try await prepare(command, page: page, cookies: cookies, document: document, view: view, canRecoverMigration: false)
        }
        if let existing = result.existingBindingKey {
            guard existing.environmentID == page.configuration.appOrigin else { throw AgentBridgeFailure.scopeChanged }
            return ["ok": true, "existing_connection_id": existing.connectionID]
        }
        guard let preparation = result.preparationID, let publicKey = result.devicePublicKey, let expires = result.expiresAt,
              result.profileCandidateID == profile, Data(base64Encoded: publicKey)?.count == 32 else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.retain(preparation)
        page.preparedPersonas[preparation] = command.personaID!
        if let pending = page.pendingMigration {
            guard pending.persona == command.personaID, pending.profile == profile else { throw AgentBridgeFailure.scopeChanged }
            page.migrations[preparation] = (pending.coordinator, pending.cutover)
        }
        var response: [String: Any] = ["ok": true, "desktop_preparation": [
            "preparation_id": preparation.uuidString.lowercased(), "device_public_key": publicKey,
            "profile_candidate_id": profile], "expires_at": expires]
        if let pending = page.pendingMigration {
            response["migration_started"] = true
            response["was_paused"] = pending.cutover.wasPaused
        }
        return response
    }

    private func enroll(_ command: AgentBridgePageCommand, page: Page, document: UUID) async throws -> [String: Any] {
        guard let persona = page.preparedPersonas.removeValue(forKey: command.preparationID!) else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.consume(command.preparationID!, scope: command.scope, documentID: document)
        var payload: [String: AgentBridgeValue] = [
            "preparation_id": .string(command.preparationID!.uuidString.lowercased()), "code": .string(command.code!),
            "document_id": .string(document.uuidString.lowercased())]
        let migration = page.migrations.removeValue(forKey: command.preparationID!)
        if let migration { payload["migration_id"] = .string(migration.1.capture.migrationID.uuidString.lowercased()) }
        let request = try AgentBridgeRequest(operation: "enroll", payload: payload)
        let result = try await client.send(request, returning: AgentBridgeEnrollment.self)
        try current(page, scope: command.scope, document: document)
        guard result.bindingKey.environmentID == page.configuration.appOrigin, result.personaID == persona else { throw AgentBridgeFailure.scopeChanged }
        var response: [String: Any] = ["ok": true, "connection_id": result.bindingKey.connectionID, "persona_id": result.personaID]
        if let migration {
            response["test_dispatched"] = try await migration.0.finish(migration.1, binding: result.bindingKey)
            response["test_deferred_until_resume"] = migration.1.wasPaused
            page.pendingMigration = nil
        }
        return response
    }

    private func migrate(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws -> [String: Any] {
        guard !page.migrating, page.migrations.isEmpty, let profile = command.profileCandidateID,
              page.profiles[profile]?.runtimeKind == command.runtime else { throw AgentBridgeFailure.scopeChanged }
        page.migrating = true
        defer { page.migrating = false }
        let csrf = try await csrfReader(view)
        let authority = AgentBridgeMigrationAuthority(transport: hosted.transport)
        let persona = command.personaID!, workspace = command.workspaceID!
        let validate: @MainActor @Sendable () async throws -> Void = { [self] in
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
        }
        let coordinator = AgentBridgeMigrationCoordinator(.init(
            verifyReplacement: { [self] in
                try await ready(page, scope: command.scope, document: document)
                let old = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
                try old.require(workspace: workspace, persona: persona, connection: command.connectionID!,
                                generation: command.connectionGeneration!, clientKind: "standalone_connector")
            },
            readState: { try await validate(); return try await authority.state(configuration: page.configuration, cookies: cookies, persona: persona) },
            stopAssignedRun: { try await validate(); try await authority.stop(configuration: page.configuration, cookies: cookies, csrf: csrf, persona: persona) },
            confirmWork: AgentBridgeMigrationCoordinator.confirmWork,
            confirmCutover: AgentBridgeMigrationCoordinator.confirmCutover,
            setPause: { paused, version in
                try await validate()
                return try await authority.pause(configuration: page.configuration, cookies: cookies, csrf: csrf, persona: persona, paused: paused, expectedVersion: version)
            },
            capture: { [self] wasPaused, pauseVersion in
                try await validate()
                let old = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
                try old.require(workspace: workspace, persona: persona, connection: command.connectionID!,
                                generation: command.connectionGeneration!, clientKind: "standalone_connector")
                return try await client.send(AgentBridgeRequest(operation: "migration_prepare", payload: [
                    "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                    "persona_id": .string(persona), "connection_id": .string(command.connectionID!),
                    "connection_generation": .integer(command.connectionGeneration!), "runtime_kind": .string(command.runtime!.rawValue),
                    "profile_candidate_id": .string(profile), "document_id": .string(document.uuidString.lowercased()),
                    "was_paused": .bool(wasPaused), "pause_version": .integer(pauseVersion)
                ]), returning: AgentBridgeMigrationCapture.self)
            },
            stopSupervisor: { scope in try await validate(); try AgentBridgeLegacySupervisor.stop(scope: scope) },
            revoke: { [self] in
                try await hosted.revoke(configuration: page.configuration, cookies: cookies, workspace: workspace, persona: persona,
                    connection: command.connectionID!, generation: command.connectionGeneration!, csrfToken: csrf,
                    clientKind: "standalone_connector", validateScope: validate)
            },
            validateScope: validate,
            readiness: { [self] binding in
                try await awaitMigrationReadiness(page: page, cookies: cookies, persona: persona, workspace: workspace,
                    binding: binding, validate: validate)
            },
            test: { try await validate(); try await authority.test(configuration: page.configuration, cookies: cookies, csrf: csrf, persona: persona) }
        ))
        let cutover: AgentBridgeMigrationCoordinator.Cutover
        do { cutover = try await coordinator.begin() }
        catch {
            if coordinator.revoked, let pending = coordinator.preparedCutover {
                page.pendingMigration = (persona, profile, coordinator, pending)
                throw AgentBridgeFailure.migrationIncomplete
            }
            throw error
        }
        guard cutover.capture.profileCandidateID == profile else { throw AgentBridgeFailure.scopeChanged }
        page.pendingMigration = (persona, profile, coordinator, cutover)
        let preparation = try await prepare(command, page: page, cookies: cookies, document: document, view: view)
        guard let value = preparation["desktop_preparation"] as? [String: String],
              let rawID = value["preparation_id"], let id = UUID(uuidString: rawID) else { throw AgentBridgeFailure.scopeChanged }
        page.migrations[id] = (coordinator, cutover)
        var result = preparation
        result["migration_started"] = true
        result["was_paused"] = cutover.wasPaused
        return result
    }

    private func recoverMigration(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws {
        let persona = command.personaID!, workspace = command.workspaceID!, profile = command.profileCandidateID!
        let validate: @MainActor @Sendable () async throws -> Void = { [self] in
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
        }
        let absent = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
        guard absent.workspaceID == workspace, absent.personaID == persona,
              absent.connectionID == nil || absent.connectionID == "" else { throw AgentBridgeFailure.scopeChanged }
        let authority = AgentBridgeMigrationAuthority(transport: hosted.transport)
        let state = try await authority.state(configuration: page.configuration, cookies: cookies, persona: persona)
        guard state.userPaused, state.laneIdle else { throw AgentBridgeFailure.busy }
        try await validate()
        guard Self.confirmMigrationResume() else { throw AgentBridgeFailure.migrationIncomplete }
        let csrf = try await csrfReader(view)
        try await validate()
        // Repeat absence after the dialog. A replacement binding blocks takeover.
        let afterDialog = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
        guard afterDialog.workspaceID == workspace, afterDialog.personaID == persona,
              afterDialog.connectionID == nil || afterDialog.connectionID == "" else { throw AgentBridgeFailure.scopeChanged }
        try await validate()
        let capture = try await client.send(AgentBridgeRequest(operation: "migration_repair", payload: [
            "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace), "persona_id": .string(persona),
            "runtime_kind": .string(command.runtime!.rawValue), "profile_candidate_id": .string(profile),
            "document_id": .string(document.uuidString.lowercased()), "pause_version": .integer(state.pauseVersion), "revocation_readback": .object([
                "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                "persona_id": .string(persona), "binding_absent": .bool(true)
            ])
        ]), returning: AgentBridgeMigrationCapture.self)
        try await validate()
        guard capture.profileCandidateID == profile, let wasPaused = capture.wasPaused,
              let pauseVersion = capture.pauseVersion else { throw AgentBridgeFailure.migrationIncomplete }
        let currentState = try await authority.state(configuration: page.configuration, cookies: cookies, persona: persona)
        guard currentState.userPaused, currentState.laneIdle, currentState.pauseVersion == pauseVersion else {
            throw AgentBridgeFailure.scopeChanged
        }
        let coordinator = AgentBridgeMigrationCoordinator(.init(
            setPause: { paused, version in
                try await validate()
                return try await authority.pause(configuration: page.configuration, cookies: cookies, csrf: csrf,
                    persona: persona, paused: paused, expectedVersion: version)
            },
            validateScope: validate,
            readiness: { [self] binding in
                try await awaitMigrationReadiness(page: page, cookies: cookies, persona: persona, workspace: workspace,
                    binding: binding, validate: validate)
            },
            test: { try await validate(); try await authority.test(configuration: page.configuration, cookies: cookies, csrf: csrf, persona: persona) }
        ))
        let cutover = try coordinator.recover(capture, wasPaused: wasPaused, pauseVersion: pauseVersion)
        page.pendingMigration = (persona, profile, coordinator, cutover)
    }

    private func awaitMigrationReadiness(page: Page, cookies: String, persona: String, workspace: String,
                                        binding: AgentBridgeBindingKey, validate: @MainActor @Sendable () async throws -> Void) async throws {
        for _ in 0..<120 {
            try await validate()
            let remote = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
            guard remote.workspaceID == workspace, remote.personaID == persona,
                  remote.connectionID == binding.connectionID, remote.clientKind == "macos_app" else { throw AgentBridgeFailure.scopeChanged }
            let local = try await client.send(AgentBridgeRequest(operation: "check", payload: ["binding_key": bindingValue(binding)]), returning: AgentBridgeConnections.self)
            if remote.readinessStatus == "wakeable", local.connections.contains(where: { $0.bindingKey == binding && $0.readinessState == "ready" }) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AgentBridgeFailure.runtimeConflict
    }

    private func connections(page: Page, cookies: String, scope: String, document: UUID) async throws -> [String: Any] {
        let authorized = try await hosted.connections(configuration: page.configuration, cookies: cookies)
        try current(page, scope: scope, document: document)
        let result = try await client.send(AgentBridgeRequest(operation: "status", payload: [:]), returning: AgentBridgeConnections.self)
        try current(page, scope: scope, document: document)
        let visible = result.connections.filter { local in
            local.bindingKey.environmentID == page.configuration.appOrigin && authorized.contains {
                $0.connectionID == local.bindingKey.connectionID && $0.personaID == local.personaID && $0.clientKind == "macos_app"
            }
        }
        return ["ok": true, "connections": visible.map(connectionValue)]
    }

    private func manage(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws -> [String: Any] {
        let key = AgentBridgeBindingKey(environmentID: page.configuration.appOrigin, connectionID: command.connectionID!)
        if command.action == "disconnect" {
            let csrf = try await csrfReader(view)
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            try await hosted.revoke(configuration: page.configuration, cookies: cookies, workspace: command.workspaceID!,
                                    persona: command.personaID!, connection: key.connectionID, generation: command.connectionGeneration!,
                                    csrfToken: csrf, validateScope: { [self] in
                _ = try await self.cookies(view: view, page: page)
                try current(page, scope: command.scope, document: document)
            })
            try current(page, scope: command.scope, document: document)
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            let claims: [String: AgentBridgeValue] = ["environment_id": .string(key.environmentID),
                "workspace_id": .string(command.workspaceID!), "persona_id": .string(command.personaID!),
                "connection_id": .string(key.connectionID), "connection_generation": .integer(command.connectionGeneration!),
                "binding_absent": .bool(true)]
            let result = try await client.send(AgentBridgeRequest(operation: "disconnect", payload: [
                "binding_key": bindingValue(key), "workspace_id": .string(command.workspaceID!), "persona_id": .string(command.personaID!),
                "connection_generation": .integer(command.connectionGeneration!), "revocation_readback": .object(claims)
            ]), returning: AgentBridgeAcknowledgement.self)
            guard result.disconnected == true else { throw AgentBridgeFailure.cleanupRequired }
            return ["ok": true]
        }
        let binding = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: command.personaID!)
        try binding.require(workspace: command.workspaceID!, persona: command.personaID!, connection: key.connectionID,
                            generation: command.connectionGeneration!)
        try current(page, scope: command.scope, document: document)
        var payload: [String: AgentBridgeValue] = ["binding_key": bindingValue(key)]
        if command.action == "repair" {
            let check = try await client.send(AgentBridgeRequest(operation: "check", payload: payload), returning: AgentBridgeConnections.self)
            try current(page, scope: command.scope, document: document)
            guard let selected = check.connections.first(where: { $0.bindingKey == key }), selected.personaID == command.personaID else {
                throw AgentBridgeFailure.scopeChanged
            }
            guard selected.activeRunID == nil || selected.activeRunID == "" else { throw AgentBridgeFailure.busy }
            let needsStart = selected.readinessState != "ready"
            if needsStart && !confirmRuntimeStart(command.personaID!) { throw AgentBridgeFailure.runtimeConflict }
            // A native dialog never grants a changed account/profile authority.
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            let currentBinding = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: command.personaID!)
            try currentBinding.require(workspace: command.workspaceID!, persona: command.personaID!, connection: key.connectionID,
                                       generation: command.connectionGeneration!)
            try current(page, scope: command.scope, document: document)
            payload["restart_confirmed"] = .bool(needsStart)
        }
        let result = try await client.send(AgentBridgeRequest(operation: command.action, payload: payload), returning: AgentBridgeConnections.self)
        try current(page, scope: command.scope, document: document)
        var response: [String: Any] = ["ok": true, "connections": result.connections.filter { $0.bindingKey == key }.map(connectionValue)]
        if command.action == "repair", let pending = page.pendingMigration, pending.persona == command.personaID {
            response["test_dispatched"] = try await pending.coordinator.finish(pending.cutover, binding: key)
            response["test_deferred_until_resume"] = pending.cutover.wasPaused
            page.pendingMigration = nil
        }
        return response
    }

    private func bindingValue(_ key: AgentBridgeBindingKey) -> AgentBridgeValue {
        .object(["environment_id": .string(key.environmentID), "connection_id": .string(key.connectionID)])
    }
    private func connectionValue(_ value: AgentBridgeConnection) -> [String: Any] {
        var result: [String: Any] = ["connection_id": value.bindingKey.connectionID, "persona_id": value.personaID,
                                   "runtime_kind": value.runtimeKind.rawValue, "readiness_state": value.readinessState]
        if let run = value.activeRunID, !run.isEmpty { result["active_run_id"] = run }
        if let diagnostic = value.diagnosticCode { result["diagnostic_code"] = diagnostic }
        // Runtime diagnostic text may contain local paths. The hosted API owns safe explanations.
        return result
    }
    private func current(_ page: Page, scope: String, document: UUID) throws {
        guard !page.retired else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.requireCurrent(scope: scope, documentID: document)
    }
    private func cookies(view: WKWebView, page: Page) async throws -> String {
        let cookieHeader = try await cookieReader(view, page.configuration)
        guard !cookieHeader.isEmpty else { throw AgentBridgeFailure.credentialUnavailable }
        let fingerprint = Data(SHA256.hash(data: Data(cookieHeader.utf8)))
        if let previous = page.cookiesFingerprint, previous != fingerprint {
            page.authority.invalidate(); page.profiles.removeAll(); page.preparedPersonas.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
            throw AgentBridgeFailure.scopeChanged
        }
        page.cookiesFingerprint = fingerprint
        return cookieHeader
    }
    private static func readCookies(view: WKWebView, configuration: DesktopEnvironmentConfiguration) async throws -> String {
        let all = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        let applicable = all.filter { cookie in
            let host = configuration.appURL.host?.lowercased() ?? ""
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && (!cookie.isSecure || configuration.appURL.scheme == "https")
                && cookie.expiresDate.map({ $0 > Date() }) != false && cookie.name.hasPrefix("personastack")
        }.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        guard !applicable.isEmpty else { throw AgentBridgeFailure.credentialUnavailable }
        return HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? ""
    }
    private static func confirmStart(persona: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start the native gateway for this profile?"
        alert.informativeText = "Repair \(persona) may start or restart its selected Hermes or OpenClaw gateway. Other profiles remain connected. Cancel preserves the current setup."
        alert.addButton(withTitle: "Allow Gateway Repair")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func confirmMigrationResume() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Resume this interrupted migration?"
        alert.informativeText = "The old binding is revoked and this persona is paused. Background Agents still hold the verified profile capture. Resume uses that capture to finish setup. The original pause setting returns after readiness. A previously paused persona stays paused."
        alert.addButton(withTitle: "Resume Migration")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func readCSRF(view: WKWebView) async throws -> String {
        let result = try await view.evaluateJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || ''")
        guard let token = result as? String, !token.isEmpty, token.utf8.count <= 512,
              !token.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.credentialUnavailable }
        return token
    }
}
