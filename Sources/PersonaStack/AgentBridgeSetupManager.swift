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
        var agentChoices: [String: String] = [:]
        var preparedTargets: [UUID: AgentBridgePreparedTarget] = [:]
        var pendingEnrollments: [UUID: (AgentBridgePreparedTarget, AgentBridgeEnrollment)] = [:]
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
    private let chooseOpenClawAgent: @MainActor (String, [AgentBridgeNativeAgent]) -> String?
    private let confirmRuntimeStart: @MainActor (String, AgentBridgeRuntime) -> Bool
    private let confirmOpenClawApps: @MainActor (String) -> Bool
    private let confirmHermesHost: @MainActor (String) -> Bool
    private let showProfileScopeHelp: @MainActor () -> Void
    private let showHermesHostHelp: @MainActor () -> Void
    private let confirmDisconnectStop: @MainActor (String) -> Bool
    private let waitForSettlement: @MainActor () async throws -> Void
    private let csrfReader: @MainActor (WKWebView) async throws -> String

    init(service: AgentBridgeService = .shared, client: AgentBridgeControlClient = AgentBridgeControlClient(),
         hosted: AgentBridgeHostedAuthority = AgentBridgeHostedAuthority(),
         configuration: @escaping @MainActor (URL) throws -> DesktopEnvironmentConfiguration = {
             try DesktopEnvironmentConfigurationStore.shared.environment(for: $0)
         }, approveEnvironment: @escaping @MainActor (DesktopEnvironmentConfiguration) throws -> Void = { try AgentBridgeEnvironments.approve($0) },
         prepareBackgroundEnable: @escaping @MainActor () throws -> Void = { try DesktopUpdater.shared.prepareToEnableBackgroundAgents() },
         cookieReader: @escaping @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = AgentBridgeSetupManager.readCookies,
         chooseOpenClawAgent: @escaping @MainActor (String, [AgentBridgeNativeAgent]) -> String? = AgentBridgeSetupManager.chooseAgent,
         confirmRuntimeStart: @escaping @MainActor (String, AgentBridgeRuntime) -> Bool = AgentBridgeSetupManager.confirmStart,
         confirmOpenClawApps: @escaping @MainActor (String) -> Bool = AgentBridgeSetupManager.confirmApps,
         confirmHermesHost: @escaping @MainActor (String) -> Bool = AgentBridgeSetupManager.confirmHost,
         showProfileScopeHelp: @escaping @MainActor () -> Void = AgentBridgeSetupManager.presentProfileScopeHelp,
         showHermesHostHelp: @escaping @MainActor () -> Void = AgentBridgeSetupManager.presentHermesHostHelp,
         confirmDisconnectStop: @escaping @MainActor (String) -> Bool = AgentBridgeSetupManager.confirmStopForDisconnect,
         waitForSettlement: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) },
         csrfReader: @escaping @MainActor (WKWebView) async throws -> String = AgentBridgeSetupManager.readCSRF) {
        self.service = service; self.client = client; self.hosted = hosted; self.configuration = configuration
        self.approveEnvironment = approveEnvironment; self.prepareBackgroundEnable = prepareBackgroundEnable; self.cookieReader = cookieReader
        self.chooseOpenClawAgent = chooseOpenClawAgent
        self.confirmRuntimeStart = confirmRuntimeStart
        self.confirmOpenClawApps = confirmOpenClawApps
        self.confirmHermesHost = confirmHermesHost
        self.showProfileScopeHelp = showProfileScopeHelp
        self.showHermesHostHelp = showHermesHostHelp
        self.csrfReader = csrfReader
        self.confirmDisconnectStop = confirmDisconnectStop; self.waitForSettlement = waitForSettlement
    }
    var hasPendingMigrationCutover: Bool {
        (pages.objectEnumerator()?.allObjects as? [Page] ?? []).contains {
            !$0.retired && ($0.migrating || $0.pendingMigration != nil || !$0.migrations.isEmpty)
        }
    }
    func register(_ view: WKWebView, appURL: URL) {
        guard let configuration = try? configuration(appURL) else { return }
        pages.setObject(Page(configuration), forKey: view)
    }
    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        page.authority.invalidate(); page.profiles.removeAll(); page.agentChoices.removeAll(); page.preparedTargets.removeAll(); page.pendingEnrollments.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
    }
    func unregister(_ view: WKWebView) {
        pages.object(forKey: view)?.retired = true
        invalidate(view); pages.removeObject(forKey: view)
    }
    func invalidateSession() {
        for page in pages.objectEnumerator()?.allObjects as? [Page] ?? [] {
            page.authority.invalidate(); page.profiles.removeAll(); page.agentChoices.removeAll(); page.preparedTargets.removeAll(); page.pendingEnrollments.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
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
        case "enroll": return try await enroll(command, page: page, cookies: cookies, document: document, view: view)
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
        let agent = try selectAgent(candidate, page: page)
        _ = try await self.cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        var payload: [String: AgentBridgeValue] = [
            "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(command.workspaceID!),
            "persona_id": .string(command.personaID!), "runtime_kind": .string(command.runtime!.rawValue),
            "profile_candidate_id": .string(profile), "document_id": .string(document.uuidString.lowercased())
        ]
        if let agent { payload["openclaw_agent_candidate_id"] = .string(agent) }
        let request = try AgentBridgeRequest(operation: "prepare", payload: payload)
        let result: AgentBridgePreparation
        do { result = try await client.send(request, returning: AgentBridgePreparation.self) }
        catch {
            let failure = error as? AgentBridgeFailure
            if [AgentBridgeFailure.cleanupRequired, .profileInUse, .runtimeConflict, .migrationRequired].contains(where: { $0 == failure }),
               try await presentManualHelp(command, page: page, cookies: cookies, document: document, view: view) {
                throw AgentBridgeFailure.migrationRequired
            }
            throw error
        }
        try current(page, scope: command.scope, document: document)
        if result.migrationPending == true {
            guard canRecoverMigration else { throw AgentBridgeFailure.migrationIncomplete }
            try await recoverMigration(command, page: page, cookies: cookies, document: document, view: view)
            return try await prepare(command, page: page, cookies: cookies, document: document, view: view, canRecoverMigration: false)
        }
        if let existing = result.existingBindingKey {
            guard existing.environmentID == page.configuration.appOrigin else { throw AgentBridgeFailure.scopeChanged }
            let target = preparedTarget(command, candidate: candidate)
            var response = try await completeEnrollment(page: page, cookies: cookies, scope: command.scope, document: document,
                view: view, target: target, binding: existing)
            response["existing_connection_id"] = existing.connectionID
            return response
        }
        guard let preparation = result.preparationID, let publicKey = result.devicePublicKey, let expires = result.expiresAt,
              result.profileCandidateID == profile, Data(base64Encoded: publicKey)?.count == 32 else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.retain(preparation)
        page.preparedTargets[preparation] = preparedTarget(command, candidate: candidate)
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

    private func selectAgent(_ profile: AgentBridgeProfile, page: Page) throws -> String? {
        guard profile.runtimeKind == .openclaw else { return nil }
        let agents = profile.openClawAgents ?? []
        guard !agents.isEmpty else { throw AgentBridgeFailure.runtimeConflict }
        if let retained = page.agentChoices[profile.profileCandidateID], agents.contains(where: { $0.agentCandidateID == retained }) { return retained }
        let selected = try Self.selectNativeAgent(profile, picker: chooseOpenClawAgent)
        page.agentChoices[profile.profileCandidateID] = selected
        return selected
    }

    static func selectNativeAgent(_ profile: AgentBridgeProfile, picker: @MainActor (String, [AgentBridgeNativeAgent]) -> String?) throws -> String {
        let agents = profile.openClawAgents ?? []
        if let selected = profile.selectedAgentCandidateID, agents.contains(where: { $0.agentCandidateID == selected }) { return selected }
        if agents.count == 1 { return agents[0].agentCandidateID }
        guard agents.count > 1, let selected = picker(profile.label, agents), agents.contains(where: { $0.agentCandidateID == selected }) else { throw AgentBridgeFailure.runtimeConflict }
        return selected
    }

    static func chooseAgent(profile: String, agents: [AgentBridgeNativeAgent]) -> String? {
        let alert = NSAlert()
        alert.messageText = "Choose an OpenClaw agent"
        alert.informativeText = "PersonaStack will send assigned work to this agent in \(profile). The whole profile connects to one persona."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        picker.addItems(withTitles: agents.map(\.label))
        alert.accessoryView = picker
        alert.addButton(withTitle: "Use agent"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, agents.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return agents[picker.indexOfSelectedItem].agentCandidateID
    }

    private func preparedTarget(_ command: AgentBridgePageCommand, candidate: AgentBridgeProfile) -> AgentBridgePreparedTarget {
        AgentBridgePreparedTarget(workspace: command.workspaceID!, persona: command.personaID!, account: candidate.accountCandidateID,
                                  profile: candidate.profileCandidateID, runtime: candidate.runtimeKind)
    }

    private func enroll(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws -> [String: Any] {
        let preparation = command.preparationID!
        if let pending = page.pendingEnrollments[preparation] {
            let response = try await completeEnrollment(page: page, cookies: cookies, scope: command.scope, document: document,
                view: view, target: pending.0, binding: pending.1.bindingKey)
            page.pendingEnrollments.removeValue(forKey: preparation)
            return response
        }
        guard let target = page.preparedTargets.removeValue(forKey: preparation) else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.consume(preparation, scope: command.scope, documentID: document)
        var payload: [String: AgentBridgeValue] = ["preparation_id": .string(preparation.uuidString.lowercased()),
            "code": .string(command.code!), "document_id": .string(document.uuidString.lowercased())]
        let migration = page.migrations.removeValue(forKey: preparation)
        if let migration { payload["migration_id"] = .string(migration.1.capture.migrationID.uuidString.lowercased()) }
        let result = try await client.send(AgentBridgeRequest(operation: "enroll", payload: payload), returning: AgentBridgeEnrollment.self)
        try current(page, scope: command.scope, document: document)
        guard result.bindingKey.environmentID == page.configuration.appOrigin, result.personaID == target.persona else { throw AgentBridgeFailure.scopeChanged }
        // Pairing is complete. A selection/readiness retry reuses this exact binding.
        page.pendingEnrollments[preparation] = (target, result)
        let response = try await completeEnrollment(page: page, cookies: cookies, scope: command.scope, document: document,
            view: view, target: target, binding: result.bindingKey)
        page.pendingEnrollments.removeValue(forKey: preparation)
        return response
    }

    private func completeEnrollment(page: Page, cookies: String, scope: String, document: UUID, view: WKWebView,
                                    target: AgentBridgePreparedTarget, binding: AgentBridgeBindingKey) async throws -> [String: Any] {
        let validate: @MainActor @Sendable () async throws -> Void = { [self] in
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: scope, document: document)
        }
        let csrf = try await csrfReader(view)
        try await validate()
        try await AgentBridgeTargetSelectionAuthority(hosted: hosted, wait: waitForSettlement).ensureSelected(
            configuration: page.configuration, cookies: cookies, csrf: csrf, binding: binding, target: target, validate: validate)
        try await ensureEnrollmentGateway(binding, target: target, page: page, cookies: cookies, validate: validate)
        var response: [String: Any] = ["ok": true, "connection_id": binding.connectionID, "persona_id": target.persona]
        if let pending = page.pendingMigration {
            guard pending.persona == target.persona, pending.profile == target.profile else { throw AgentBridgeFailure.scopeChanged }
            response["test_dispatched"] = try await pending.coordinator.finish(pending.cutover, binding: binding)
            response["test_deferred_until_resume"] = pending.cutover.wasPaused
            page.pendingMigration = nil
        } else {
            try await awaitMigrationReadiness(page: page, cookies: cookies, persona: target.persona,
                workspace: target.workspace, binding: binding, target: target, validate: validate)
        }
        return response
    }

    private func ensureEnrollmentGateway(_ binding: AgentBridgeBindingKey, target: AgentBridgePreparedTarget, page: Page,
                                         cookies: String, validate: @MainActor @Sendable () async throws -> Void) async throws {
        for _ in 0..<120 {
            try await validate()
            let result = try await client.send(AgentBridgeRequest(operation: "check", payload: ["binding_key": bindingValue(binding)]), returning: AgentBridgeConnections.self)
            try await validate()
            guard let selected = result.connections.first(where: { $0.bindingKey == binding }), selected.personaID == target.persona, selected.runtimeKind == target.runtime else { throw AgentBridgeFailure.scopeChanged }
            guard !selected.requiresReconnect else { throw AgentBridgeFailure.reconnectRequired }
            if Self.hasUnverifiedProfileScope(selected) || Self.hasUnsafeHermesHost(selected) {
                let owner = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: target.persona)
                guard let generation = selected.connectionGeneration, generation > 0 else { throw AgentBridgeFailure.scopeChanged }
                try owner.require(workspace: target.workspace, persona: target.persona, connection: binding.connectionID, generation: generation)
                try await validate()
                try refuseUnverifiedProfileScope(selected)
            }
            if selected.isMCPVerified { return }
            // The helper must receive the API-selected revision before a native Repair can install or launch.
            if selected.readinessState == "target_selection_required" { try await waitForSettlement(); continue }
            guard (selected.activeRunID ?? "").isEmpty else { throw AgentBridgeFailure.busy }
            let payload = try await confirmedRepairPayload(selected, target: target, page: page, cookies: cookies, validate: validate)
            _ = try await client.send(AgentBridgeRequest(operation: "repair", payload: payload), returning: AgentBridgeConnections.self)
            return
        }
        throw AgentBridgeFailure.runtimeConflict
    }

    /// Shared Hermes host, OpenClaw Apps and profile Repair each need their own native authority.
    private func confirmedRepairPayload(_ selected: AgentBridgeConnection, target: AgentBridgePreparedTarget, page: Page,
                                        cookies: String, validate: @MainActor @Sendable () async throws -> Void) async throws -> [String: AgentBridgeValue] {
        guard let generation = selected.connectionGeneration, generation > 0 else { throw AgentBridgeFailure.scopeChanged }
        let key = selected.bindingKey
        @MainActor func owner() async throws -> AgentBridgeHostedBinding {
            try await validate()
            let current = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: target.persona)
            try current.require(workspace: target.workspace, persona: target.persona, connection: key.connectionID, generation: generation)
            guard let inventory = current.targetInventory, inventory.matches(target),
                  current.targetSelection?.isSelected(target, generation: inventory.inventory_generation) == true else { throw AgentBridgeFailure.scopeChanged }
            try await validate()
            return current
        }
        let before = try await owner()
        guard let revision = before.targetSelection?.selection_revision, revision > 0 else { throw AgentBridgeFailure.scopeChanged }
        var appsConfirmed = false
        if selected.runtimeKind == .openclaw && selected.diagnosticCode == "mcp_apps_disabled" {
            guard confirmOpenClawApps(target.persona) else { throw AgentBridgeFailure.runtimeConflict }
            let afterApps = try await owner()
            guard afterApps.targetSelection?.selection_revision == revision else { throw AgentBridgeFailure.scopeChanged }
            appsConfirmed = true
        }
        var hermesHostConfirmed = false
        if selected.runtimeKind == .hermes && selected.diagnosticCode == "hermes_host_consent_required" {
            guard confirmHermesHost(target.persona) else { throw AgentBridgeFailure.hermesHostConsentRequired }
            let afterHost = try await owner()
            guard afterHost.targetSelection?.selection_revision == revision else { throw AgentBridgeFailure.scopeChanged }
            hermesHostConfirmed = true
        }
        guard confirmRuntimeStart(target.persona, selected.runtimeKind) else { throw AgentBridgeFailure.runtimeConflict }
        let afterStart = try await owner()
        guard afterStart.targetSelection?.selection_revision == revision else { throw AgentBridgeFailure.scopeChanged }
        return ["binding_key": bindingValue(key), "connection_generation": .integer(generation),
                "target_selection_revision": .integer(revision), "restart_confirmed": .bool(true), "openclaw_apps_confirmed": .bool(appsConfirmed),
                "hermes_host_confirmed": .bool(hermesHostConfirmed)]
    }

    private func migrate(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws -> [String: Any] {
        guard !page.migrating, page.migrations.isEmpty, let profile = command.profileCandidateID,
              page.profiles[profile]?.runtimeKind == command.runtime else { throw AgentBridgeFailure.scopeChanged }
        let agent = try selectAgent(page.profiles[profile]!, page: page)
        _ = try await self.cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        page.migrating = true
        defer { page.migrating = false }
        let csrf = try await csrfReader(view)
        let authority = AgentBridgeMigrationAuthority(transport: hosted.transport)
        let persona = command.personaID!, workspace = command.workspaceID!
        let target = preparedTarget(command, candidate: page.profiles[profile]!)
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
                    "openclaw_agent_candidate_id": .string(agent ?? ""),
                    "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                    "persona_id": .string(persona), "connection_id": .string(command.connectionID!),
                    "connection_generation": .integer(command.connectionGeneration!), "runtime_kind": .string(command.runtime!.rawValue),
                    "profile_candidate_id": .string(profile), "document_id": .string(document.uuidString.lowercased()),
                    "was_paused": .bool(wasPaused), "pause_version": .integer(pauseVersion)
                ]), returning: AgentBridgeMigrationCapture.self)
            },
            stopSupervisor: { scope in try await validate(); try AgentBridgeLegacySupervisor.stop(scope: scope) },
            cancelCapture: { [self] capture in
                try await validate()
                let old = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
                try old.require(workspace: workspace, persona: persona, connection: command.connectionID!,
                    generation: command.connectionGeneration!, clientKind: "standalone_connector")
                try await validate()
                let reply = try await client.send(AgentBridgeRequest(operation: "migration_cancel", payload: [
                    "migration_id": .string(capture.migrationID.uuidString.lowercased()),
                    "document_id": .string(document.uuidString.lowercased()), "legacy_binding_readback": .object([
                        "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                        "persona_id": .string(persona), "connection_id": .string(command.connectionID!),
                        "connection_generation": .integer(command.connectionGeneration!), "binding_present": .bool(true)
                    ])
                ]), returning: AgentBridgeAcknowledgement.self)
                guard reply.cancelled == true else { throw AgentBridgeFailure.migrationIncomplete }
            },
            revoke: { [self] in
                try await hosted.revoke(configuration: page.configuration, cookies: cookies, workspace: workspace, persona: persona,
                    connection: command.connectionID!, generation: command.connectionGeneration!, csrfToken: csrf,
                    clientKind: "standalone_connector", validateScope: validate)
            },
            validateScope: validate,
            readiness: { [self] binding in
                try await awaitMigrationReadiness(page: page, cookies: cookies, persona: persona, workspace: workspace,
                    binding: binding, target: target, validate: validate)
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

    private func presentManualHelp(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws -> Bool {
        let persona = command.personaID!, workspace = command.workspaceID!
        let absent = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
        guard absent.workspaceID == workspace, absent.personaID == persona,
              absent.connectionID == nil || absent.connectionID == "" else { return false }
        let state = try await AgentBridgeMigrationAuthority(transport: hosted.transport).state(configuration: page.configuration, cookies: cookies, persona: persona)
        guard state.userPaused, state.laneIdle else { return false }
        _ = try await self.cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        let help: AgentBridgeMigrationHelp
        do {
            help = try await client.send(AgentBridgeRequest(operation: "migration_help", payload: [
                "environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                "persona_id": .string(persona), "runtime_kind": .string(command.runtime!.rawValue),
                "profile_candidate_id": .string(command.profileCandidateID!), "document_id": .string(document.uuidString.lowercased()),
                "revocation_readback": .object(["environment_id": .string(page.configuration.appOrigin), "workspace_id": .string(workspace),
                    "persona_id": .string(persona), "binding_absent": .bool(true)])
            ]), returning: AgentBridgeMigrationHelp.self)
        } catch { return false }
        _ = try await self.cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        guard help.backupDirectory == AgentBridgeNativePaths.directory.appendingPathComponent("migration").path,
              help.profileConfigPath.hasPrefix("/"), help.profileConfigPath.utf8.count <= 4096,
              help.profileLabel.utf8.count <= 512, help.legacyEntryKey.utf8.count <= 256,
              !help.legacyEntryKey.isEmpty else { throw AgentBridgeFailure.invalidRequest }
        let alert = NSAlert()
        alert.messageText = "Manual repair is needed for this profile."
        alert.informativeText = "The old binding is absent. This persona is paused. The retained helper capture expired or the helper restarted.\n\nProfile: \(help.profileLabel)\nConfig: \(help.profileConfigPath)\nExact PersonaStack entry: \(help.legacyEntryKey)\nBackups: \(help.backupDirectory)\n\nCompare this exact entry with its retained backup before resetting it locally. Never remove sibling or user entries. Never restart the revoked Connector supervisor. Keep the persona paused. Then select this same profile to set up the new binding. Resume only after Background Agents report readiness."
        alert.addButton(withTitle: "Open Migration Backups")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AgentBridgeNativePaths.directory.appendingPathComponent("migration")])
        }
        return true
    }

    private func recoverMigration(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID, view: WKWebView) async throws {
        let persona = command.personaID!, workspace = command.workspaceID!, profile = command.profileCandidateID!
        guard let candidate = page.profiles[profile] else { throw AgentBridgeFailure.scopeChanged }
        let target = preparedTarget(command, candidate: candidate)
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
        let agent = try selectAgent(page.profiles[profile]!, page: page)
        try await validate()
        let capture = try await client.send(AgentBridgeRequest(operation: "migration_repair", payload: [
            "openclaw_agent_candidate_id": .string(agent ?? ""),
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
                    binding: binding, target: target, validate: validate)
            },
            test: { try await validate(); try await authority.test(configuration: page.configuration, cookies: cookies, csrf: csrf, persona: persona) }
        ))
        let cutover = try coordinator.recover(capture, wasPaused: wasPaused, pauseVersion: pauseVersion)
        page.pendingMigration = (persona, profile, coordinator, cutover)
    }

    private func awaitMigrationReadiness(page: Page, cookies: String, persona: String, workspace: String,
                                        binding: AgentBridgeBindingKey, target: AgentBridgePreparedTarget, validate: @MainActor @Sendable () async throws -> Void) async throws {
        for _ in 0..<120 {
            try await validate()
            let remote = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
            guard remote.workspaceID == workspace, remote.personaID == persona,
                  remote.connectionID == binding.connectionID, remote.clientKind == "macos_app",
                  let inventory = remote.targetInventory, inventory.matches(target),
                  remote.targetSelection?.isSelected(target, generation: inventory.inventory_generation) == true else { throw AgentBridgeFailure.scopeChanged }
            let local = try await client.send(AgentBridgeRequest(operation: "check", payload: ["binding_key": bindingValue(binding)]), returning: AgentBridgeConnections.self)
            if Self.migrationReady(remote: remote, local: local, binding: binding) { return }
            try await waitForSettlement()
        }
        throw AgentBridgeFailure.runtimeConflict
    }

    static func migrationReady(remote: AgentBridgeHostedBinding, local: AgentBridgeConnections, binding: AgentBridgeBindingKey) -> Bool {
        remote.readinessStatus == "wakeable" && local.connections.contains { $0.bindingKey == binding && $0.isMCPVerified }
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
            return try await disconnect(command, page: page, cookies: cookies, document: document, view: view, key: key)
        }
        let binding = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: command.personaID!)
        try binding.require(workspace: command.workspaceID!, persona: command.personaID!, connection: key.connectionID,
                            generation: command.connectionGeneration!)
        try current(page, scope: command.scope, document: document)
        if command.action == "repair", let pending = page.pendingEnrollments.first(where: { $0.value.1.bindingKey == key }) {
            var response = try await completeEnrollment(page: page, cookies: cookies, scope: command.scope, document: document,
                view: view, target: pending.value.0, binding: key)
            page.pendingEnrollments.removeValue(forKey: pending.key)
            response["connections"] = [connectionValue(try await selectedConnection(key, persona: command.personaID!))]
            return response
        }
        var payload: [String: AgentBridgeValue] = ["binding_key": bindingValue(key)]
        if command.action == "repair" {
            let check = try await client.send(AgentBridgeRequest(operation: "check", payload: payload), returning: AgentBridgeConnections.self)
            try current(page, scope: command.scope, document: document)
            guard let selected = check.connections.first(where: { $0.bindingKey == key }), selected.personaID == command.personaID else {
                throw AgentBridgeFailure.scopeChanged
            }
            guard let generation = selected.connectionGeneration, generation > 0, generation == command.connectionGeneration else { throw AgentBridgeFailure.scopeChanged }
            guard selected.activeRunID == nil || selected.activeRunID == "" else { throw AgentBridgeFailure.busy }
            guard !selected.requiresReconnect else { throw AgentBridgeFailure.reconnectRequired }
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            try refuseUnverifiedProfileScope(selected)
            if selected.readinessState == "target_selection_required" || binding.targetSelection?.isUnselected == true {
                guard let retained = selected.preparedTarget, retained.workspaceID == command.workspaceID,
                      retained.runtimeKind == selected.runtimeKind, selected.connectionGeneration == command.connectionGeneration,
                      !retained.accountCandidateID.isEmpty, !retained.profileCandidateID.isEmpty else { throw AgentBridgeFailure.scopeChanged }
                let target = AgentBridgePreparedTarget(workspace: retained.workspaceID, persona: selected.personaID,
                    account: retained.accountCandidateID, profile: retained.profileCandidateID, runtime: retained.runtimeKind)
                var response = try await completeEnrollment(page: page, cookies: cookies, scope: command.scope, document: document,
                    view: view, target: target, binding: key)
                response["connections"] = [connectionValue(try await selectedConnection(key, persona: selected.personaID))]
                return response
            }
            guard let retained = selected.preparedTarget, retained.workspaceID == command.workspaceID,
                  retained.runtimeKind == selected.runtimeKind, !retained.accountCandidateID.isEmpty,
                  !retained.profileCandidateID.isEmpty else { throw AgentBridgeFailure.scopeChanged }
            let target = AgentBridgePreparedTarget(workspace: retained.workspaceID, persona: selected.personaID,
                account: retained.accountCandidateID, profile: retained.profileCandidateID, runtime: retained.runtimeKind)
            payload = try await confirmedRepairPayload(selected, target: target, page: page, cookies: cookies) { [self] in
                _ = try await self.cookies(view: view, page: page)
                try current(page, scope: command.scope, document: document)
            }
        }
        let result = try await client.send(AgentBridgeRequest(operation: command.action, payload: payload), returning: AgentBridgeConnections.self)
        try current(page, scope: command.scope, document: document)
        if command.action == "repair", result.connections.contains(where: { $0.bindingKey == key && $0.requiresReconnect }) {
            throw AgentBridgeFailure.reconnectRequired
        }
        var response: [String: Any] = ["ok": true, "connections": result.connections.filter { $0.bindingKey == key }.map(connectionValue)]
        if command.action == "repair", let pending = page.pendingMigration, pending.persona == command.personaID {
            response["test_dispatched"] = try await pending.coordinator.finish(pending.cutover, binding: key)
            response["test_deferred_until_resume"] = pending.cutover.wasPaused
            page.pendingMigration = nil
        }
        return response
    }

    /// Quiesce admission and settle accepted work before revoking its reporting credential.
    private func disconnect(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID,
                            view: WKWebView, key: AgentBridgeBindingKey) async throws -> [String: Any] {
        let workspace = command.workspaceID!, persona = command.personaID!, generation = command.connectionGeneration!
        let remote = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
        guard remote.workspaceID == workspace, remote.personaID == persona else { throw AgentBridgeFailure.scopeChanged }
        let local = try await selectedConnection(key, persona: persona)
        try current(page, scope: command.scope, document: document)
        if remote.connectionID == nil || remote.connectionID == "" {
            guard (local.activeRunID ?? "").isEmpty else { throw AgentBridgeFailure.busy }
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            return try await cleanupDisconnectedBinding(key, workspace: workspace, persona: persona, generation: generation)
        }
        try remote.require(workspace: workspace, persona: persona, connection: key.connectionID, generation: generation)
        var stopConfirmed = false
        if remote.runLaneStatus != "idle" || !(local.activeRunID ?? "").isEmpty {
            guard confirmDisconnectStop(persona) else { throw AgentBridgeFailure.busy }
            stopConfirmed = true
        }
        let csrf = try await csrfReader(view)
        _ = try await self.cookies(view: view, page: page)
        try current(page, scope: command.scope, document: document)
        let admission = try await client.send(AgentBridgeRequest(operation: "quiesce", payload: ["binding_key": bindingValue(key)]), returning: AgentBridgeAdmission.self)
        guard admission.quiesced else { throw AgentBridgeFailure.busy }
        var revokeStarted = false
        do {
            if !admission.activeRunIDs.isEmpty && !stopConfirmed {
                guard confirmDisconnectStop(persona) else { throw AgentBridgeFailure.busy }
                stopConfirmed = true
            }
            if stopConfirmed {
                _ = try await self.cookies(view: view, page: page)
                try current(page, scope: command.scope, document: document)
                let owner = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: persona)
                try owner.require(workspace: workspace, persona: persona, connection: key.connectionID, generation: generation)
                try await AgentBridgeMigrationAuthority(transport: hosted.transport).stop(configuration: page.configuration,
                    cookies: cookies, csrf: csrf, persona: persona)
            }
            try await awaitDisconnectIdle(command, page: page, cookies: cookies, document: document, view: view, key: key)
            revokeStarted = true
            try await hosted.revoke(configuration: page.configuration, cookies: cookies, workspace: workspace, persona: persona,
                connection: key.connectionID, generation: generation, csrfToken: csrf, requireIdle: true, validateScope: { [self] in
                    _ = try await self.cookies(view: view, page: page)
                    try current(page, scope: command.scope, document: document)
                    let selected = try await selectedConnection(key, persona: persona)
                    guard (selected.activeRunID ?? "").isEmpty else { throw AgentBridgeFailure.busy }
                })
            return try await cleanupDisconnectedBinding(key, workspace: workspace, persona: persona, generation: generation)
        } catch {
            // An attempted revoke may already have removed the cloud credential. Never reopen it.
            if !revokeStarted && local.diagnosticCode != "busy" {
                _ = try? await client.send(AgentBridgeRequest(operation: "resume", payload: ["binding_key": bindingValue(key)]), returning: AgentBridgeAdmission.self)
            }
            throw error
        }
    }

    private func cleanupDisconnectedBinding(_ key: AgentBridgeBindingKey, workspace: String, persona: String, generation: Int) async throws -> [String: Any] {
        let claims: [String: AgentBridgeValue] = ["environment_id": .string(key.environmentID),
            "workspace_id": .string(workspace), "persona_id": .string(persona), "connection_id": .string(key.connectionID),
            "connection_generation": .integer(generation), "binding_absent": .bool(true)]
        let result = try await client.send(AgentBridgeRequest(operation: "disconnect", payload: ["binding_key": bindingValue(key),
            "workspace_id": .string(workspace), "persona_id": .string(persona), "connection_generation": .integer(generation),
            "revocation_readback": .object(claims)]), returning: AgentBridgeAcknowledgement.self)
        guard result.disconnected == true else { throw AgentBridgeFailure.cleanupRequired }
        return ["ok": true]
    }

    private func selectedConnection(_ key: AgentBridgeBindingKey, persona: String) async throws -> AgentBridgeConnection {
        let result = try await client.send(AgentBridgeRequest(operation: "status", payload: ["binding_key": bindingValue(key)]), returning: AgentBridgeConnections.self)
        guard let selected = result.connections.first(where: { $0.bindingKey == key }), selected.personaID == persona else {
            throw AgentBridgeFailure.scopeChanged
        }
        return selected
    }

    private func awaitDisconnectIdle(_ command: AgentBridgePageCommand, page: Page, cookies: String, document: UUID,
                                     view: WKWebView, key: AgentBridgeBindingKey) async throws {
        for _ in 0..<120 {
            _ = try await self.cookies(view: view, page: page)
            try current(page, scope: command.scope, document: document)
            let remote = try await hosted.read(configuration: page.configuration, cookies: cookies, persona: command.personaID!)
            try remote.require(workspace: command.workspaceID!, persona: command.personaID!, connection: key.connectionID,
                               generation: command.connectionGeneration!)
            let local = try await selectedConnection(key, persona: command.personaID!)
            if remote.runLaneStatus == "idle", (local.activeRunID ?? "").isEmpty { return }
            try await waitForSettlement()
        }
        throw AgentBridgeFailure.busy
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
    static let profileScopeHelpMessage = "Gateway profile scope cannot be verified. Stop it manually, then Repair."
    private static func hasUnverifiedProfileScope(_ connection: AgentBridgeConnection) -> Bool {
        connection.runtimeKind == .openclaw && connection.diagnosticCode == "runtime_conflict" &&
            connection.diagnosticMessage == profileScopeHelpMessage
    }
    static let hermesHostHelpMessage = "Hermes shared gateway cannot be attached safely. Enable its loopback API server, then Repair."
    private static func hasUnsafeHermesHost(_ connection: AgentBridgeConnection) -> Bool {
        connection.runtimeKind == .hermes && connection.diagnosticCode == "runtime_conflict" &&
            connection.diagnosticMessage == hermesHostHelpMessage
    }
    private func refuseUnverifiedProfileScope(_ connection: AgentBridgeConnection) throws {
        if Self.hasUnsafeHermesHost(connection) {
            showHermesHostHelp()
            throw AgentBridgeFailure.runtimeConflict
        }
        guard Self.hasUnverifiedProfileScope(connection) else { return }
        showProfileScopeHelp()
        throw AgentBridgeFailure.runtimeConflict
    }
    private static func presentProfileScopeHelp() {
        let alert = NSAlert()
        alert.messageText = "OpenClaw profile scope is unavailable."
        alert.informativeText = profileScopeHelpMessage + "\n\nPersonaStack leaves this gateway untouched. Use OpenClaw to stop the preexisting gateway. Then return to this persona's Repair action and approve starting its selected profile."
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
    private static func presentHermesHostHelp() {
        let alert = NSAlert()
        alert.messageText = "Hermes shared host needs manual setup."
        alert.informativeText = hermesHostHelpMessage + "\n\nPersonaStack leaves the running host untouched. Use Hermes to configure its existing host safely. Then return to this persona's Repair action."
        alert.addButton(withTitle: "Close")
        alert.runModal()
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
            page.authority.invalidate(); page.profiles.removeAll(); page.agentChoices.removeAll(); page.preparedTargets.removeAll(); page.pendingEnrollments.removeAll(); page.migrations.removeAll(); page.pendingMigration = nil; page.cookiesFingerprint = nil
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
    private static func confirmApps(persona: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Enable MCP Apps for this OpenClaw profile?"
        alert.informativeText = "Connecting \(persona) requires OpenClaw MCP Apps. Enabling Apps adds HTML App capability and an extra local sandbox listener. Repair may restart this selected gateway. Apps stays enabled after disconnecting from PersonaStack. Cancel leaves the profile configuration unchanged."
        alert.addButton(withTitle: "Enable MCP Apps")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func confirmHost(persona: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start the shared Hermes host on this Mac?"
        alert.informativeText = "Connecting \(persona) requires enabling the default/shared Hermes gateway API and starting its host. This may activate configured messaging services and scheduled jobs for other profiles. PersonaStack connects only the selected profile. Disconnecting leaves the shared host running. Cancel leaves the host configuration unchanged."
        alert.addButton(withTitle: "Enable API and Start Hermes Host")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func confirmStart(persona: String, runtime: AgentBridgeRuntime) -> Bool {
        let alert = NSAlert()
        alert.messageText = runtime == .hermes ? "Repair this Hermes profile's tools?" : "Start the native gateway for this profile?"
        alert.informativeText = runtime == .hermes
            ? "Repair \(persona) may enable its selected Hermes MCP toolset. Starting the shared Hermes host requires separate approval. Cancel preserves the current setup."
            : "Repair \(persona) may start or restart its selected OpenClaw gateway. Other profiles remain connected. Cancel preserves the current setup."
        alert.addButton(withTitle: runtime == .hermes ? "Allow Profile Repair" : "Allow Gateway Repair")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func confirmStopForDisconnect(persona: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop assigned work before disconnecting?"
        alert.informativeText = "Disconnecting \(persona) stops its PersonaStack-assigned run. Background Agents wait for the API and local runtime to settle before revoking this connection."
        alert.addButton(withTitle: "Stop and Disconnect")
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
