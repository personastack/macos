import AppKit
import CryptoKit
import Foundation
import PersonaStackCore
import ServiceManagement
import WebKit

/// Owns document authority and the native-only enrollment transport.
@MainActor
final class LocalClusterSetupManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = LocalClusterSetupManager()
    private enum LocalCredentialFailure: Error, Equatable { case key, custody, write }
    private enum Remediation: Equatable {
        case backgroundApprovalRequired, localCredentialsUnavailable, requirementsUnavailable, requirementsTransportUnavailable, unsupportedBudget
        var nativeStatus: [String: Any] {
            switch self {
            case .backgroundApprovalRequired:
                ["state": "failed", "safe_reason": "background_approval_required", "action": "open_settings"]
            case .localCredentialsUnavailable:
                ["state": "failed", "safe_reason": "local_credentials_unavailable", "action": "details"]
            case .requirementsUnavailable:
                ["state": "failed", "safe_reason": "helper_update_required", "action": "update_app"]
            case .requirementsTransportUnavailable:
                ["state": "unavailable", "safe_reason": "status_unavailable", "action": "retry"]
            case .unsupportedBudget:
                ["state": "failed", "safe_reason": "unsupported_host", "action": "details"]
            }
        }
    }
    @MainActor private final class Page {
        let configuration: DesktopEnvironmentConfiguration
        var authority = AgentBridgeDocumentScope()
        var cookiesFingerprint: Data?
        var owner: LocalClusterAuthenticatedScope?
        var attempt: UUID?
        var busy = false
        var continuationCancelled = false
        var lifecycle = LocalClusterLifecycle()
        var remediation: Remediation?
        var credentialRequirement: LocalCredentialFailure?
        var setupRequirements: AgentBridgeLocalClusterRequirements?
        var uncertainEnrollment = false
        var retired = false
        init(_ configuration: DesktopEnvironmentConfiguration) { self.configuration = configuration }
        func invalidate() {
            authority.invalidate(); cookiesFingerprint = nil; owner = nil; attempt = nil; lifecycle = LocalClusterLifecycle(); remediation = nil; credentialRequirement = nil; setupRequirements = nil
            // An in-flight operation retains its busy fence until it returns.
        }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let client: AgentBridgeControlClient
    private let hosted: LocalClusterEnrollmentClient
    private let service: AgentBridgeService
    private let keychain: any DesktopControlKeychainAccess
    private let requireSignature: @MainActor () throws -> Void
    private let prepareBackgroundEnable: @MainActor () throws -> Void
    private let approveEnvironment: @MainActor (DesktopEnvironmentConfiguration) throws -> Void
    private let helperControlVersion: @MainActor () async throws -> Int?
    private let requirementsReader: @MainActor () async throws -> AgentBridgeLocalClusterRequirements
    private let confirmSetupBudget: @MainActor (AgentBridgeLocalClusterRequirements) -> Bool
    private let showSetupBudgetDetails: @MainActor (AgentBridgeLocalClusterRequirements) -> Void
    private let physicalMemory: @MainActor () -> UInt64
    private let processorCount: @MainActor () -> Int
    // Signed VZ execution and native image qualification have not passed.
    // Handler presence and a running process cannot enable this feature.
    private let qualifiedRuntime: Bool
    private let configuration: @MainActor (URL) throws -> DesktopEnvironmentConfiguration
    private let cookieReader: @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String
    private let csrfReader: @MainActor (WKWebView) async throws -> String
    private let openSettings: @MainActor () -> Void
    private let openUpdates: @MainActor () -> Void
    private let showDetails: @MainActor () -> Void
    private let showCredentialDetails: @MainActor () -> Void
    private let confirmRemove: @MainActor () -> Bool
    private let confirmNewSetup: @MainActor () -> Bool
    private let confirmRotation: @MainActor () -> Bool
    private let pause: @MainActor () async throws -> Void

    init(client: AgentBridgeControlClient = AgentBridgeControlClient(),
         hosted: LocalClusterEnrollmentClient = LocalClusterEnrollmentClient(), service: AgentBridgeService = .shared,
         qualifiedRuntime: Bool = false, keychain: any DesktopControlKeychainAccess = SystemDesktopControlKeychainAccess(),
         requireSignature: @escaping @MainActor () throws -> Void = AgentBridgeService.validateHelperIdentity,
         prepareBackgroundEnable: @escaping @MainActor () throws -> Void = { try DesktopUpdater.shared.prepareToEnableBackgroundAgents() },
         approveEnvironment: @escaping @MainActor (DesktopEnvironmentConfiguration) throws -> Void = { try AgentBridgeEnvironments.approve($0) },
         helperControlVersion: (@MainActor () async throws -> Int?)? = nil,
         requirementsReader: (@MainActor () async throws -> AgentBridgeLocalClusterRequirements)? = nil,
         confirmSetupBudget: @escaping @MainActor (AgentBridgeLocalClusterRequirements) -> Bool = LocalClusterSetupManager.presentSetupBudget,
         showSetupBudgetDetails: @escaping @MainActor (AgentBridgeLocalClusterRequirements) -> Void = LocalClusterSetupManager.presentSetupBudgetDetails,
         physicalMemory: @escaping @MainActor () -> UInt64 = { ProcessInfo.processInfo.physicalMemory },
         processorCount: @escaping @MainActor () -> Int = { ProcessInfo.processInfo.activeProcessorCount },
         configuration: @escaping @MainActor (URL) throws -> DesktopEnvironmentConfiguration = { try DesktopEnvironmentConfigurationStore.shared.environment(for: $0) },
         cookieReader: @escaping @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = LocalClusterSetupManager.readCookies,
         csrfReader: @escaping @MainActor (WKWebView) async throws -> String = LocalClusterSetupManager.readCSRF,
         openSettings: @escaping @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() },
         openUpdates: @escaping @MainActor () -> Void = LocalClusterSetupManager.presentUpdates,
         showDetails: @escaping @MainActor () -> Void = LocalClusterSetupManager.presentDetails,
         showCredentialDetails: @escaping @MainActor () -> Void = LocalClusterSetupManager.presentCredentialDetails,
         confirmRemove: @escaping @MainActor () -> Bool = LocalClusterSetupManager.confirmLocalRemoval,
         confirmNewSetup: @escaping @MainActor () -> Bool = LocalClusterSetupManager.confirmBlankSetup,
         confirmRotation: @escaping @MainActor () -> Bool = LocalClusterSetupManager.confirmCredentialRotation,
         pause: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.client = client; self.hosted = hosted; self.service = service; self.qualifiedRuntime = qualifiedRuntime
        self.keychain = keychain; self.requireSignature = requireSignature
        self.prepareBackgroundEnable = prepareBackgroundEnable; self.approveEnvironment = approveEnvironment
        self.helperControlVersion = helperControlVersion ?? { try await service.localClusterControlVersion() }
        self.requirementsReader = requirementsReader ?? { try await service.localClusterRequirements() }
        self.confirmSetupBudget = confirmSetupBudget; self.showSetupBudgetDetails = showSetupBudgetDetails
        self.physicalMemory = physicalMemory; self.processorCount = processorCount
        self.configuration = configuration; self.cookieReader = cookieReader; self.csrfReader = csrfReader; self.pause = pause
        self.openSettings = openSettings; self.openUpdates = openUpdates; self.showDetails = showDetails; self.showCredentialDetails = showCredentialDetails
        self.confirmRemove = confirmRemove; self.confirmNewSetup = confirmNewSetup; self.confirmRotation = confirmRotation
    }
    func register(_ view: WKWebView, appURL: URL) {
        guard let configuration = try? configuration(appURL) else { return }
        pages.setObject(Page(configuration), forKey: view)
    }
    func invalidate(_ view: WKWebView) { pages.object(forKey: view)?.invalidate() }
    func unregister(_ view: WKWebView) {
        pages.object(forKey: view)?.retired = true; invalidate(view); pages.removeObject(forKey: view)
    }
    func invalidateSession() {
        for page in pages.objectEnumerator()?.allObjects as? [Page] ?? [] { page.invalidate() }
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let view = message.webView, let page = pages.object(forKey: view), !page.retired,
              ChatWindowManager.trusted(message, base: page.configuration.appURL),
              let command = try? LocalClusterPageCommand.parse(message.body) else {
            replyHandler(nil, AgentBridgeFailure.invalidRequest.rawValue); return
        }
        Task {
            do { replyHandler(try await apply(command, view: view), nil) }
            catch { replyHandler(nil, (error as? AgentBridgeFailure ?? .serviceUnavailable).rawValue) }
        }
    }
    func apply(_ command: LocalClusterPageCommand, view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view), !page.retired else { throw AgentBridgeFailure.scopeChanged }
        if command.action == .state {
            guard command.scope.isEmpty || command.scope == page.authority.scope else { throw AgentBridgeFailure.scopeChanged }
            if page.authority.scope.isEmpty { page.authority.synchronize(UUID().uuidString.lowercased()) }
        } else {
            try current(page, scope: command.scope, document: page.authority.documentID)
            guard !page.busy || command.action == .cancel else { throw AgentBridgeFailure.busy }
            // A failed helper/transport probe must not retain enrollment permission.
            if command.action == .cancel { page.continuationCancelled = true }
        }
        let document = page.authority.documentID, scope = page.authority.scope
        let (cookies, owner) = try await authorize(page, view: view, scope: scope, document: document)
        let localScope = LocalClusterScope(appOrigin: page.configuration.appOrigin, accountID: owner.userID,
            workspaceID: owner.workspaceID, documentID: document)
        if command.action == .state {
            return try await checkedResponse(try await state(page, localScope: localScope, owner: owner, scope: scope, document: document), page: page, view: view, scope: scope, document: document)
        }
        if performRecovery(command.action, page: page) {
            try current(page, scope: scope, document: document)
            return try await checkedResponse(try await state(page, localScope: localScope, owner: owner, scope: scope, document: document), page: page, view: view, scope: scope, document: document)
        }
        guard qualifiedRuntime else { throw AgentBridgeFailure.runtimeUnsupported }
        if ![.install, .repair, .start, .reconnect, .newSetup].contains(command.action) {
            guard try await helperControlVersion() == 1 else { throw AgentBridgeFailure.runtimeUnsupported }
        }
        try current(page, scope: scope, document: document)
        let ownsBusy = command.action != .cancel
        if ownsBusy {
            guard !page.busy else { throw AgentBridgeFailure.busy }
            page.busy = true
        }
        defer { if ownsBusy { page.busy = false } }
        if command.action != .cancel { page.continuationCancelled = false; page.lifecycle.failure = nil; page.remediation = nil; page.credentialRequirement = nil }
        do {
            try await performAction(command, page: page, view: view, cookies: cookies, owner: owner, localScope: localScope, scope: scope, document: document)
        } catch {
            try current(page, scope: scope, document: document)
            guard retainRemediation(error, page: page) else { throw error }
            _ = try await self.cookies(view, page: page, document: document)
            return try await checkedResponse(try await state(page, localScope: localScope, owner: owner, scope: scope, document: document, apiFresh: false), page: page, view: view, scope: scope, document: document)
        }
        return try await checkedResponse(try await mutationResponse(command.action, page: page, view: view, owner: owner, localScope: localScope, scope: scope, document: document), page: page, view: view, scope: scope, document: document)
    }
    private func checkedResponse(_ response: [String: Any], page: Page, view: WKWebView, scope: String, document: UUID) async throws -> [String: Any] {
        _ = try await cookies(view, page: page, document: document)
        try current(page, scope: scope, document: document)
        return response
    }
    private func performRecovery(_ action: LocalClusterPageCommand.Action, page: Page) -> Bool {
        switch action {
        case .openSettings: openSettings()
        case .openUpdates: openUpdates()
        case .details:
            if page.remediation == .localCredentialsUnavailable {
                showCredentialDetails()
                if page.credentialRequirement == .write {
                    page.remediation = nil; page.credentialRequirement = nil
                    if page.lifecycle.failure == .custodyUnavailable { page.lifecycle.failure = nil }
                }
            } else if page.remediation == .unsupportedBudget, let requirements = page.setupRequirements {
                showSetupBudgetDetails(requirements)
            } else { showDetails() }
        default: return false
        }
        return true
    }
    private func performAction(_ command: LocalClusterPageCommand, page: Page, view: WKWebView, cookies: String,
                               owner: LocalClusterAuthenticatedScope, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        switch command.action {
        case .install, .repair:
            try await install(command.action, page: page, view: view, localScope: localScope, scope: scope, document: document)
        case .disconnect:
            try await disconnect(page, view: view, localScope: localScope, scope: scope, document: document)
        case .reconnect:
            try await reconnect(page, view: view, localScope: localScope, scope: scope, document: document)
        case .remove:
            try await remove(page, view: view, localScope: localScope, scope: scope, document: document)
        case .newSetup:
            try await newSetup(page, view: view, localScope: localScope, scope: scope, document: document)
        case .cancel:
            page.continuationCancelled = true
            guard let attempt = page.attempt else { throw AgentBridgeFailure.scopeChanged }
            let snapshot = try await control("local_cluster_cancel", scope: localScope, attempt: attempt)
            try snapshot.requireOwner(localScope, attempt: attempt)
        case .continue:
            page.continuationCancelled = false
            try await enroll(page, view: view, cookies: cookies, owner: owner, localScope: localScope, scope: scope, document: document)
        case .start:
            try await enable(page, scope: scope, document: document)
            let snapshot = try await control("local_cluster_runtime_resume", scope: localScope)
            try snapshot.requireOwner(localScope); page.attempt = snapshot.attemptID
        case .stop:
            guard confirmStop() else { throw AgentBridgeFailure.busy }
            try current(page, scope: scope, document: document)
            try await service.stopLocalRuntime()
        case .state, .openSettings, .openUpdates, .details: break
        }
    }
    private func install(_ action: LocalClusterPageCommand.Action, page: Page, view: WKWebView, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        page.lifecycle.action = action == .repair ? .repairing : .none
        defer { if action == .repair { page.lifecycle.action = .none } }
        try await enable(page, scope: scope, document: document)
        let runtime = try await runtimeStatus()
        try current(page, scope: scope, document: document)
        if runtime.verifiedRemoved { page.lifecycle.action = .none; return }
        if action == .repair {
            guard !runtime.installerActive else { throw AgentBridgeFailure.busy }
            guard runtime.installed, runtime.reason == nil || runtime.reason == .setupFailed else { throw AgentBridgeFailure.runtimeConflict }
        } else { try runtime.requireIdleKnownState() }
        if !runtime.installed {
            guard try await reviewFreshSetup(page, view: view, scope: scope, document: document) else { return }
        }
        let key = try installationKey(createIfMissing: runtime.permitsInstallationKeyCreation)
        let retainedBinding = try await bindingStatus(localScope)
        try requireFreshIdentity(retainedBinding, key: key)
        guard !retainedBinding.removed else { throw AgentBridgeFailure.runtimeConflict }
        try continuing(page, scope: scope, document: document)
        let snapshot = try await control("local_cluster_start", scope: localScope)
        try snapshot.requireOwner(localScope); page.attempt = snapshot.attemptID
    }
    private func reviewFreshSetup(_ page: Page, view: WKWebView, scope: String, document: UUID) async throws -> Bool {
        let requirements: AgentBridgeLocalClusterRequirements
        do { requirements = try await requirementsReader() }
        catch {
            try current(page, scope: scope, document: document)
            page.remediation = requirementsRemediation(error)
            return false
        }
        try current(page, scope: scope, document: document)
        page.setupRequirements = requirements
        guard requirements.supportsHost(physicalMemoryBytes: physicalMemory(), activeProcessorCount: processorCount()) else {
            page.remediation = .unsupportedBudget
            return false
        }
        guard confirmSetupBudget(requirements) else { return false }
        _ = try await cookies(view, page: page, document: document)
        try continuing(page, scope: scope, document: document)
        return true
    }
    private func requirementsRemediation(_ error: Error) -> Remediation {
        error as? AgentBridgeFailure == .runtimeUnsupported ? .requirementsUnavailable : .requirementsTransportUnavailable
    }
    private func reobserveSetupRequirements(_ page: Page, scope: String, document: UUID) async throws {
        guard let remediation = page.remediation, [.requirementsUnavailable, .requirementsTransportUnavailable, .unsupportedBudget].contains(remediation) else { return }
        do {
            let requirements = try await requirementsReader()
            try current(page, scope: scope, document: document)
            page.setupRequirements = requirements
            page.remediation = requirements.supportsHost(physicalMemoryBytes: physicalMemory(), activeProcessorCount: processorCount()) ? nil : .unsupportedBudget
        } catch {
            try current(page, scope: scope, document: document)
            page.remediation = requirementsRemediation(error)
        }
    }
    private func mutationResponse(_ action: LocalClusterPageCommand.Action, page: Page, view: WKWebView, owner: LocalClusterAuthenticatedScope,
                                  localScope: LocalClusterScope, scope: String, document: UUID) async throws -> [String: Any] {
        do {
            let (_, latest) = try await authorize(page, view: view, scope: scope, document: document)
            return try await state(page, localScope: localScope, owner: latest, scope: scope, document: document)
        } catch {
            try current(page, scope: scope, document: document)
            guard [.disconnect, .reconnect, .remove, .newSetup].contains(action) else { throw error }
            if error as? AgentBridgeFailure == .scopeChanged && action != .remove { throw error }
            _ = try await self.cookies(view, page: page, document: document)
            return try await state(page, localScope: localScope, owner: owner, scope: scope, document: document, apiFresh: false)
        }
    }
    private func state(_ page: Page, localScope: LocalClusterScope, owner: LocalClusterAuthenticatedScope,
                       scope: String, document: UUID, apiFresh: Bool = true) async throws -> [String: Any] {
        if page.remediation == .backgroundApprovalRequired && service.status == .enabled { page.remediation = nil }
        if !page.busy { try await reobserveSetupRequirements(page, scope: scope, document: document) }
        if qualifiedRuntime { try requireSignature() }
        let version: Int?
        do { version = try await helperControlVersion() }
        catch {
            try current(page, scope: scope, document: document)
            let unsupported = error as? AgentBridgeFailure == .runtimeUnsupported
            return unavailableState(page, scope: scope, updateRequired: unsupported)
        }
        try current(page, scope: scope, document: document)
        guard version == 1 else { return unavailableState(page, scope: scope, updateRequired: true) }
        var helperSupported = false
        var native: [String: Any] = ["state": "unavailable", "action": "none"]
        do {
            let snapshot = try await control("local_cluster_status", scope: localScope)
            try snapshot.requireOwner(localScope); try current(page, scope: scope, document: document)
            helperSupported = true; native = snapshot.pageValue; page.attempt = snapshot.attemptID
        } catch let failure as AgentBridgeFailure where [.serviceUnavailable, .runtimeUnsupported, .operationTimeout, .runtimeOccupied, .busy].contains(failure) {
            try current(page, scope: scope, document: document)
        }
        var observedRuntime: LocalClusterRuntimeStatus?
        do {
            let runtime = try await runtimeStatus()
            try current(page, scope: scope, document: document)
            observedRuntime = runtime; helperSupported = true
            if let reason = runtime.reason {
                native["state"] = runtime.verifiedRemoved ? "completed" : "failed"
                if runtime.verifiedRemoved { native["operation"] = "remove" }
                native["safe_reason"] = reason.rawValue
                native["action"] = runtime.action?.rawValue ?? "none"
            }
        } catch let failure as AgentBridgeFailure where [.serviceUnavailable, .runtimeUnsupported, .operationTimeout].contains(failure) {
            try current(page, scope: scope, document: document)
        }
        let observation = try await observeBinding(page, localScope: localScope, scope: scope, document: document)
        if observation.occupied && observedRuntime?.verifiedRemoved != true {
            return ["ok": true, "scope": scope, "capability": ["version": "1", "supported": qualifiedRuntime],
                    "helper_supported": helperSupported, "native_status": ["state": "unavailable", "safe_reason": "runtime_occupied", "action": "none"],
                    "api_readiness": "unknown", "lifecycle": LocalClusterLifecycle().pageValue]
        }
        let observedBinding = observation.binding
        resolveCredentialRemediation(page, localScope: localScope, binding: observedBinding, owner: owner)
        let (readiness, connectedCluster) = try self.readiness(owner: owner, runtime: observedRuntime, binding: observedBinding, apiFresh: apiFresh, helperSupported: helperSupported)
        var result: [String: Any] = ["ok": true, "scope": scope, "capability": ["version": "1", "supported": qualifiedRuntime],
                "helper_supported": helperSupported, "native_status": native, "api_readiness": readiness]
        try projectLifecycle(page, localScope: localScope, owner: owner, runtime: observedRuntime, binding: observedBinding, apiFresh: apiFresh, scope: scope, document: document)
        if page.remediation == .unsupportedBudget || page.remediation == .requirementsUnavailable || page.remediation == .requirementsTransportUnavailable { page.lifecycle.availableActions = [] }
        result["lifecycle"] = page.lifecycle.pageValue
        if let remediation = page.remediation {
            result["native_status"] = remediation.nativeStatus
            result["api_readiness"] = "unknown"
        } else if let connectedCluster { result["cluster_id"] = connectedCluster }
        return result
    }
    private func observeBinding(_ page: Page, localScope: LocalClusterScope, scope: String, document: UUID) async throws -> (binding: LocalClusterBindingStatus?, occupied: Bool) {
        guard qualifiedRuntime else { return (nil, false) }
        do {
            let binding = try await bindingStatus(localScope)
            try current(page, scope: scope, document: document)
            return (binding, false)
        } catch {
            try current(page, scope: scope, document: document)
            if error as? AgentBridgeFailure == .scopeChanged { throw error }
            return (nil, error as? AgentBridgeFailure == .runtimeOccupied)
        }
    }
    private func resolveCredentialRemediation(_ page: Page, localScope: LocalClusterScope, binding: LocalClusterBindingStatus?, owner: LocalClusterAuthenticatedScope) {
        guard page.remediation == .localCredentialsUnavailable, let requirement = page.credentialRequirement,
              requirement != .write, let binding, let key = try? installationKey(createIfMissing: false) else { return }
        do { try requireFreshIdentity(binding, key: key) }
        catch { return }
        if requirement == .custody {
            guard let custody = try? readCustody(installationID: key.installationID), custody.scope.sameOwner(localScope),
                  let canonical = try? owner.ownedCluster(installationID: key.installationID),
                  custody.clusterID == canonical.clusterID, binding.binding?.integrationID == custody.clusterID else { return }
        }
        page.remediation = nil; page.credentialRequirement = nil
        if page.lifecycle.failure == .custodyUnavailable { page.lifecycle.failure = nil }
    }
    private func readiness(owner: LocalClusterAuthenticatedScope, runtime: LocalClusterRuntimeStatus?, binding: LocalClusterBindingStatus?, apiFresh: Bool, helperSupported: Bool) throws -> (String, String?) {
        guard apiFresh, qualifiedRuntime, helperSupported, let key = try? installationKey(createIfMissing: false),
              let applied = binding?.binding, applied.installationID == key.installationID,
              let cluster = try owner.cluster(binding: applied) else { return ("unknown", nil) }
        guard runtime?.isRunningReady == true, cluster.status == "active", cluster.agentConnected, cluster.capabilitiesReady == true else {
            return ("waiting_on_cluster_to_connect", nil)
        }
        return ("connected", cluster.clusterID)
    }
    private func unavailableState(_ page: Page, scope: String, updateRequired: Bool) -> [String: Any] {
        page.lifecycle.availableActions = []
        if qualifiedRuntime && !updateRequired && page.remediation == nil {
            page.lifecycle.availableActions = page.lifecycle.local == .removed ? ["new_setup"] : ["install"]
        }
        let native: [String: Any] = page.remediation?.nativeStatus ?? ["state": "unavailable",
            "safe_reason": updateRequired ? "helper_update_required" : "status_unavailable", "action": updateRequired ? "update_app" : "retry"]
        return ["ok": true, "scope": scope, "capability": ["version": "1", "supported": qualifiedRuntime], "helper_supported": false,
                "native_status": native,
                "api_readiness": "unknown", "lifecycle": page.lifecycle.pageValue]
    }
    private func projectLifecycle(_ page: Page, localScope: LocalClusterScope, owner: LocalClusterAuthenticatedScope,
                                  runtime: LocalClusterRuntimeStatus?, binding: LocalClusterBindingStatus?, apiFresh: Bool, scope: String, document: UUID) throws {
        page.lifecycle.availableActions = []
        if let runtime, !runtime.installerActive, runtime.reason == nil {
            page.lifecycle.local = runtime.running ? .running : .stopped
        }
        guard qualifiedRuntime else { return }
        if runtime?.verifiedRemoved == true {
            page.lifecycle.local = .removed; page.lifecycle.availableActions = ["new_setup"]
            return
        }
        guard let local = binding else { return }
        try current(page, scope: scope, document: document)
        if local.removed {
            page.lifecycle.local = .removed; page.lifecycle.availableActions = ["new_setup"]
            return
        }
        if let binding = local.binding, apiFresh, let cluster = try owner.cluster(binding: binding), page.lifecycle.cloud != .retirementPending {
            page.lifecycle.cloud = cluster.status == "disabled" ? .disconnected : (cluster.agentConnected ? .connected : .unknown)
        }
        guard let runtime, !runtime.installerActive else { return }
        let actions = try lifecycleActions(local: local, runtime: runtime, owner: owner, apiFresh: apiFresh)
        page.lifecycle.availableActions = actions.values
        if actions.invalidKey {
            page.lifecycle.failure = .custodyUnavailable
            if page.remediation == nil { page.remediation = .localCredentialsUnavailable; page.credentialRequirement = .key }
        }
    }
    private func lifecycleActions(local: LocalClusterBindingStatus, runtime: LocalClusterRuntimeStatus,
                                  owner: LocalClusterAuthenticatedScope, apiFresh: Bool) throws -> (values: [String], invalidKey: Bool) {
        let key = try? installationKey(createIfMissing: false)
        let matchesBinding = key.map { local.binding == nil || local.binding?.installationID == $0.installationID } ?? false
        let freshKey = key.map { local.previousRemovedBinding?.installationID != $0.installationID } ?? false
        let usableKey = matchesBinding && freshKey
        if local.previousRemovedBinding != nil && !runtime.installed && key != nil && !freshKey { return ([], true) }
        if runtime.permitsInstallationKeyCreation && local.binding == nil { return (["install"], false) }
        if runtime.reason == .localDataUnavailable { return (["remove"], false) }
        guard runtime.installed else { return ([], false) }
        if runtime.reason == .stopFailed { return (["stop"], false) }
        guard runtime.reason == nil || runtime.reason == .setupFailed else { return ([], false) }
        var actions = ["remove", runtime.running ? "stop" : "start"]
        if usableKey { actions.append("repair") }
        if let binding = local.binding, apiFresh, let cluster = try owner.cluster(binding: binding) {
            if cluster.status == "disabled", key?.installationID == binding.installationID { actions.append("reconnect") }
            else if cluster.status == "active" { actions.append("disconnect") }
        }
        return (actions, !usableKey)
    }
    private func enroll(_ page: Page, view: WKWebView, cookies: String, owner: LocalClusterAuthenticatedScope,
                        localScope: LocalClusterScope, scope: String, document: UUID, rotationApproved: Bool = false) async throws {
        try requireSignature()
        guard let attempt = page.attempt else { throw AgentBridgeFailure.scopeChanged }
        let prepared = try await control("local_cluster_status", scope: localScope, attempt: attempt)
        try prepared.requireOwner(localScope, attempt: attempt)
        let runtime = try await runtimeStatus()
        guard runtime.isRunningReady else { throw AgentBridgeFailure.runtimeUnsupported }
        let key = try installationKey(createIfMissing: false)
        let retainedBinding = try await bindingStatus(localScope)
        try requireFreshIdentity(retainedBinding, key: key)
        guard !retainedBinding.removed else { throw AgentBridgeFailure.runtimeConflict }
        let (_, freshOwner) = try await authorize(page, view: view, scope: scope, document: document)
        try owner.requireSameOwner(freshOwner)
        let owned = try freshOwner.ownedCluster(installationID: key.installationID)
        let custody: LocalClusterCredentialCustody
        if let retained = try readCustody(installationID: key.installationID) {
            guard retained.scope.sameOwner(localScope), owned?.clusterID == retained.clusterID else { throw AgentBridgeFailure.scopeChanged }
            custody = retained
        } else {
            guard owned != nil || !page.uncertainEnrollment else { throw AgentBridgeFailure.enrollmentUncertain }
            if owned != nil && !rotationApproved {
                guard confirmRotation() else { throw AgentBridgeFailure.enrollmentUncertain }
            }
            guard prepared.state == .installed || prepared.state == .completed else { throw AgentBridgeFailure.busy }
            let operation = owned == nil ? "create" : "rotate"
            let integration = owned?.clusterID
            let configVersion = owned?.configVersion
            let csrf = try await csrfReader(view)
            let name = owned?.name ?? Self.clusterName()
            _ = try await authorize(page, view: view, scope: scope, document: document)
            try continuing(page, scope: scope, document: document)
            let receipt = try await hosted.prepare(configuration: page.configuration, cookies: cookies, workspaceID: freshOwner.workspaceID, csrf: csrf,
                publicKey: key.publicKey, documentID: localScope.documentID, name: name, operation: operation, integrationID: integration, configVersion: configVersion)
            let proof = try receipt.proof(scope: localScope, publicKey: key.publicKey, installation: key.installationID, name: name, operation: operation, integrationID: integration, configVersion: configVersion)
            let (currentCookies, currentOwner) = try await authorize(page, view: view, scope: scope, document: document)
            try owner.requireSameOwner(currentOwner)
            // Sending redeem may create a credential even if its response is lost.
            // No automatic cloud mutation retry is permitted.
            try continuing(page, scope: scope, document: document)
            page.uncertainEnrollment = true
            let enrolled = try await hosted.redeem(configuration: page.configuration, cookies: currentCookies,
                csrf: csrf, receipt: receipt, signature: key.sign(proof))
            custody = LocalClusterCredentialCustody(scope: localScope, enrollment: enrolled)
            try storeCustody(custody, installationID: key.installationID)
            try current(page, scope: scope, document: document)
        }
        _ = try await authorize(page, view: view, scope: scope, document: document)
        try continuing(page, scope: scope, document: document)
        let targetBinding = try LocalClusterTargetBinding(integrationID: custody.clusterID, installationID: key.installationID)
        try retainedBinding.requireFreshTarget(targetBinding)
        let accepted = try await control("local_cluster_apply", scope: localScope, attempt: attempt, manifest: custody.manifest, binding: targetBinding)
        try await awaitLocalTask(accepted, operation: .apply, page: page, localScope: localScope, scope: scope, document: document)
        let (_, readback) = try await authorize(page, view: view, scope: scope, document: document)
        guard try readback.ownedCluster(installationID: key.installationID)?.clusterID == custody.clusterID else { throw AgentBridgeFailure.scopeChanged }
    }
    private func bindingStatus(_ scope: LocalClusterScope) async throws -> LocalClusterBindingStatus {
        let result = try await client.send(AgentBridgeRequest(operation: "local_cluster_binding", payload: ["scope": scope.controlValue]), returning: LocalClusterBindingStatus.self)
        try result.requireConsistent()
        return result
    }
    private func awaitLocalTask(_ accepted: LocalClusterSnapshot, operation: LocalClusterSnapshot.Operation,
                                page: Page, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        try accepted.requireOwner(localScope)
        guard let attempt = accepted.attemptID, accepted.operation == operation else { throw AgentBridgeFailure.scopeChanged }
        page.attempt = attempt
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try current(page, scope: scope, document: document)
            let snapshot = try await control("local_cluster_status", scope: localScope, attempt: attempt)
            try snapshot.requireOwner(localScope, attempt: attempt)
            guard snapshot.operation == operation else { throw AgentBridgeFailure.scopeChanged }
            if snapshot.state == .completed { return }
            guard snapshot.state == .running || snapshot.state == .cancelling else { throw AgentBridgeFailure.serviceUnavailable }
            try await pause()
        }
        throw AgentBridgeFailure.operationTimeout
    }
    private func disconnect(_ page: Page, view: WKWebView, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        page.lifecycle.action = .disconnecting
        defer { page.lifecycle.action = .none }
        let local = try await bindingStatus(localScope)
        try continuing(page, scope: scope, document: document)
        if let binding = local.binding {
            let (_, owner) = try await authorize(page, view: view, scope: scope, document: document)
            guard let cluster = try owner.cluster(binding: binding) else { page.lifecycle.failure = .bindingChanged; return }
            let csrf = try await csrfReader(view)
            if cluster.agentConnected {
                do {
                    let (currentCookies, stopOwner) = try await authorize(page, view: view, scope: scope, document: document)
                    guard try stopOwner.cluster(binding: binding)?.configVersion == cluster.configVersion else { throw AgentBridgeFailure.scopeChanged }
                    try continuing(page, scope: scope, document: document)
                    try await hosted.stop(configuration: page.configuration, cookies: currentCookies, workspaceID: stopOwner.workspaceID,
                        csrf: csrf, binding: binding, configVersion: cluster.configVersion)
                } catch {
                    try current(page, scope: scope, document: document)
                    if error as? AgentBridgeFailure == .scopeChanged { throw error }
                    page.lifecycle.failure = .stopUnconfirmed
                }
            }
            if cluster.status != "disabled" {
                do {
                    let (currentCookies, latest) = try await authorize(page, view: view, scope: scope, document: document)
                    guard let currentCluster = try latest.cluster(binding: binding), currentCluster.configVersion == cluster.configVersion else { throw AgentBridgeFailure.scopeChanged }
                    try continuing(page, scope: scope, document: document)
                    _ = try await hosted.setStatus(configuration: page.configuration, cookies: currentCookies, workspaceID: latest.workspaceID,
                        csrf: csrf, binding: binding, configVersion: currentCluster.configVersion, enabled: false)
                } catch {
                    try current(page, scope: scope, document: document)
                    if error as? AgentBridgeFailure == .scopeChanged { throw error }
                    page.lifecycle.failure = .statusChangeUnconfirmed
                }
            }
            do {
                let (_, readback) = try await authorize(page, view: view, scope: scope, document: document)
                page.lifecycle.cloud = try readback.cluster(binding: binding)?.status == "disabled" ? .disconnected : .unknown
                if page.lifecycle.cloud != .disconnected { page.lifecycle.failure = .statusChangeUnconfirmed }
            } catch {
                try current(page, scope: scope, document: document)
                if error as? AgentBridgeFailure == .scopeChanged { throw error }
                page.lifecycle.cloud = .unknown
                page.lifecycle.failure = .statusChangeUnconfirmed
            }
        } else { page.lifecycle.cloud = .disconnected }
        let latestBinding = try await bindingStatus(localScope)
        guard latestBinding.binding == local.binding, latestBinding.removed == local.removed else { throw AgentBridgeFailure.scopeChanged }
        _ = try await cookies(view, page: page, document: document)
        try continuing(page, scope: scope, document: document)
        do {
            try await service.stopLocalRuntime()
            try current(page, scope: scope, document: document)
            page.lifecycle.local = .stopped
        } catch {
            try current(page, scope: scope, document: document)
            page.lifecycle.failure = .localStopUnconfirmed
        }
    }
    private func reconnect(_ page: Page, view: WKWebView, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        page.lifecycle.action = .reconnecting
        defer { page.lifecycle.action = .none }
        try await enable(page, scope: scope, document: document)
        let local = try await bindingStatus(localScope)
        guard let binding = local.binding, !local.removed else { page.lifecycle.failure = .bindingChanged; return }
        let key: LocalClusterInstallationKey
        let needsCredentialRecovery: Bool
        do {
            key = try installationKey(createIfMissing: false)
            guard key.installationID == binding.installationID else { throw LocalCredentialFailure.key }
            if let custody = try readCustody(installationID: key.installationID) {
                guard custody.scope.sameOwner(localScope), custody.clusterID == binding.integrationID else { throw LocalCredentialFailure.custody }
                needsCredentialRecovery = false
            } else { needsCredentialRecovery = true }
        } catch { page.lifecycle.failure = .custodyUnavailable; _ = retainRemediation(error, page: page); return }
        try requireFreshIdentity(local, key: key)
        if needsCredentialRecovery, !confirmRotation() { page.lifecycle.failure = .custodyUnavailable; page.remediation = .localCredentialsUnavailable; page.credentialRequirement = .custody; return }
        let (_, owner) = try await authorize(page, view: view, scope: scope, document: document)
        guard let cluster = try owner.cluster(binding: binding) else { page.lifecycle.failure = .bindingChanged; return }
        if cluster.status != "active" {
            let csrf = try await csrfReader(view)
            try continuing(page, scope: scope, document: document)
            do {
                let (currentCookies, currentOwner) = try await authorize(page, view: view, scope: scope, document: document)
                guard try currentOwner.cluster(binding: binding)?.configVersion == cluster.configVersion else { throw AgentBridgeFailure.scopeChanged }
                try continuing(page, scope: scope, document: document)
                _ = try await hosted.setStatus(configuration: page.configuration, cookies: currentCookies, workspaceID: currentOwner.workspaceID,
                    csrf: csrf, binding: binding, configVersion: cluster.configVersion, enabled: true)
            } catch {
                try current(page, scope: scope, document: document)
                if error as? AgentBridgeFailure == .scopeChanged { throw error }
                page.lifecycle.failure = .statusChangeUnconfirmed; return
            }
        }
        let (_, readback) = try await authorize(page, view: view, scope: scope, document: document)
        guard try readback.cluster(binding: binding)?.status == "active" else { page.lifecycle.failure = .statusChangeUnconfirmed; return }
        try continuing(page, scope: scope, document: document)
        do {
            let accepted = try await control("local_cluster_runtime_resume", scope: localScope)
            try accepted.requireOwner(localScope); page.attempt = accepted.attemptID
            if needsCredentialRecovery {
                try await awaitLocalTask(accepted, operation: .resume, page: page, localScope: localScope, scope: scope, document: document)
                let (currentCookies, currentOwner) = try await authorize(page, view: view, scope: scope, document: document)
                try await enroll(page, view: view, cookies: currentCookies, owner: currentOwner, localScope: localScope, scope: scope, document: document, rotationApproved: true)
            }
        } catch {
            try current(page, scope: scope, document: document)
            if error as? AgentBridgeFailure == .scopeChanged { throw error }
            page.lifecycle.failure = .localStartUnconfirmed
        }
    }
    private func remove(_ page: Page, view: WKWebView, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        guard confirmRemove() else { throw AgentBridgeFailure.busy }
        _ = try await self.cookies(view, page: page, document: document)
        try continuing(page, scope: scope, document: document)
        page.lifecycle.action = .retiring
        defer { page.lifecycle.action = .none }
        let local = try await bindingStatus(localScope)
        try continuing(page, scope: scope, document: document)
        // Cloud retirement and local erasure have independent outcomes.
        if let binding = local.binding, !local.removed {
            do {
                let (_, owner) = try await authorize(page, view: view, scope: scope, document: document)
                guard let cluster = try owner.cluster(binding: binding) else { throw AgentBridgeFailure.serviceUnavailable }
                let csrf = try await csrfReader(view)
                let (currentCookies, currentOwner) = try await authorize(page, view: view, scope: scope, document: document)
                guard try currentOwner.cluster(binding: binding)?.configVersion == cluster.configVersion else { throw AgentBridgeFailure.scopeChanged }
                try continuing(page, scope: scope, document: document)
                let retirement = try await hosted.retire(configuration: page.configuration, cookies: currentCookies, workspaceID: currentOwner.workspaceID,
                    csrf: csrf, binding: binding, configVersion: cluster.configVersion)
                try current(page, scope: scope, document: document)
                page.lifecycle.cloud = retirement.state == .retired ? .retired : .retirementPending
            } catch {
                try current(page, scope: scope, document: document)
                // Cloud revocation does not revoke the OS owner's explicit
                // local erasure. Document/cookie changes still fence it.
                _ = try await self.cookies(view, page: page, document: document)
                page.lifecycle.cloud = .unknown; page.lifecycle.failure = .retirementUnconfirmed
            }
        }
        page.lifecycle.action = .removing
        try continuing(page, scope: scope, document: document)
        do {
            _ = try await self.cookies(view, page: page, document: document)
            try continuing(page, scope: scope, document: document)
            let accepted = try await control("local_cluster_remove", scope: localScope, binding: local.binding)
            try await awaitLocalTask(accepted, operation: .remove, page: page, localScope: localScope, scope: scope, document: document)
            let removed = try await bindingStatus(localScope)
            guard removed.removed, removed.binding == local.binding else { throw AgentBridgeFailure.scopeChanged }
            page.lifecycle.local = .removed
        } catch {
            try current(page, scope: scope, document: document)
            if error as? AgentBridgeFailure == .scopeChanged { throw error }
            page.lifecycle.failure = .localRemovalUnconfirmed
        }
    }
    private func newSetup(_ page: Page, view: WKWebView, localScope: LocalClusterScope, scope: String, document: UUID) async throws {
        try await enable(page, scope: scope, document: document)
        let runtime = try await runtimeStatus()
        guard runtime.verifiedRemoved else { page.lifecycle.failure = .newSetupUnconfirmed; return }
        guard confirmNewSetup() else { throw AgentBridgeFailure.busy }
        _ = try await self.cookies(view, page: page, document: document)
        try continuing(page, scope: scope, document: document)
        let local: LocalClusterBindingStatus?
        do { local = try await bindingStatus(localScope) }
        catch {
            guard runtime.verifiedRemoved, error as? AgentBridgeFailure == .runtimeOccupied else { throw error }
            local = nil
        }
        try continuing(page, scope: scope, document: document)
        do {
            let previous = local?.binding ?? local?.previousRemovedBinding
            // The disk is already removed. Persist the fresh key first so a
            // failed Keychain write cannot release the helper's reset fence.
            try replaceInstallationKey(previous: previous)
            let accepted = try await control("local_cluster_new_setup", scope: localScope, binding: previous)
            try await awaitLocalTask(accepted, operation: .newSetup, page: page, localScope: localScope, scope: scope, document: document)
            try continuing(page, scope: scope, document: document)
            page.attempt = nil; page.uncertainEnrollment = false
            page.lifecycle.local = .stopped; page.lifecycle.cloud = .unknown; page.lifecycle.failure = nil
        } catch {
            try current(page, scope: scope, document: document)
            if error as? AgentBridgeFailure == .scopeChanged { throw error }
            page.lifecycle.failure = .newSetupUnconfirmed
            _ = retainRemediation(error, page: page)
        }
    }
    private func replaceInstallationKey(previous: LocalClusterTargetBinding?) throws {
        let key = LocalClusterInstallationKey()
        guard key.installationID != previous?.installationID else { throw LocalCredentialFailure.write }
        do {
            try keychain.write(key.rawRepresentation, service: "ai.personastack.desktop.local-cluster-installation",
                account: "installation-ed25519-v1", interaction: .forbidden)
            let stored = try installationKey(createIfMissing: false)
            guard stored.installationID == key.installationID else { throw LocalCredentialFailure.write }
        } catch { throw LocalCredentialFailure.write }
    }
    private func retainRemediation(_ error: Error, page: Page) -> Bool {
        if error as? AgentBridgeFailure == .backgroundApprovalRequired {
            page.remediation = .backgroundApprovalRequired; page.credentialRequirement = nil
            return true
        }
        if let requirement = error as? LocalCredentialFailure {
            page.remediation = .localCredentialsUnavailable
            page.credentialRequirement = requirement
            page.lifecycle.failure = page.lifecycle.failure ?? .custodyUnavailable
            return true
        }
        return false
    }
    private func requireFreshIdentity(_ binding: LocalClusterBindingStatus, key: LocalClusterInstallationKey) throws {
        do {
            try binding.requireFreshIdentity(key.installationID)
            if let applied = binding.binding, applied.installationID != key.installationID { throw LocalCredentialFailure.key }
        } catch { throw LocalCredentialFailure.key }
    }
    private func continuing(_ page: Page, scope: String, document: UUID) throws {
        try current(page, scope: scope, document: document)
        guard !page.continuationCancelled else { throw AgentBridgeFailure.busy }
    }
    private func installationKey(createIfMissing: Bool) throws -> LocalClusterInstallationKey {
        do {
            let service = "ai.personastack.desktop.local-cluster-installation", account = "installation-ed25519-v1"
            if let data = try keychain.read(service: service, account: account, interaction: .forbidden) {
                return try LocalClusterInstallationKey(rawRepresentation: data)
            }
            guard createIfMissing else { throw LocalCredentialFailure.key }
            let key = LocalClusterInstallationKey()
            do { try keychain.write(key.rawRepresentation, service: service, account: account, interaction: .forbidden) }
            catch { throw LocalCredentialFailure.write }
            return key
        } catch let failure as LocalCredentialFailure { throw failure }
        catch { throw LocalCredentialFailure.key }
    }
    private func readCustody(installationID: String) throws -> LocalClusterCredentialCustody? {
        do {
            guard let data = try keychain.read(service: "ai.personastack.desktop.local-cluster-custody", account: installationID, interaction: .forbidden) else { return nil }
            return try JSONDecoder().decode(LocalClusterCredentialCustody.self, from: data)
        } catch { throw LocalCredentialFailure.custody }
    }
    private func storeCustody(_ custody: LocalClusterCredentialCustody, installationID: String) throws {
        // A failed apply keeps custody. Never replace an existing native credential.
        guard try readCustody(installationID: installationID) == nil else { throw LocalCredentialFailure.custody }
        do {
            try keychain.write(JSONEncoder().encode(custody), service: "ai.personastack.desktop.local-cluster-custody", account: installationID, interaction: .forbidden)
        } catch { throw LocalCredentialFailure.custody }
    }
    private func control(_ operation: String, scope: LocalClusterScope, attempt: UUID? = nil,
                         manifest: String? = nil, binding: LocalClusterTargetBinding? = nil) async throws -> LocalClusterSnapshot {
        var payload: [String: AgentBridgeValue] = ["scope": scope.controlValue]
        if let attempt { payload["attempt_id"] = .string(attempt.uuidString.lowercased()) }
        if let manifest { payload["manifest"] = .string(manifest) }
        if let binding { payload["binding"] = binding.controlValue }
        else if ["local_cluster_remove", "local_cluster_new_setup"].contains(operation) { payload["binding"] = .object([:]) }
        return try await client.send(AgentBridgeRequest(operation: operation, payload: payload), returning: LocalClusterControlResult.self).localCluster
    }
    private func runtimeStatus() async throws -> LocalClusterRuntimeStatus {
        try await client.send(AgentBridgeRequest(operation: "local_cluster_runtime_status", payload: [:]), returning: LocalClusterRuntimeStatus.self)
    }
    private func enable(_ page: Page, scope: String, document: UUID) async throws {
        try prepareBackgroundEnable()
        try approveEnvironment(page.configuration)
        try await service.ensureLocalClusterEnabled()
        try current(page, scope: scope, document: document)
    }
    private func authorize(_ page: Page, view: WKWebView, scope: String, document: UUID) async throws -> (String, LocalClusterAuthenticatedScope) {
        try current(page, scope: scope, document: document)
        let cookies = try await cookies(view, page: page, document: document)
        let owner = try await hosted.scope(configuration: page.configuration, cookies: cookies)
        try current(page, scope: scope, document: document)
        if let previous = page.owner {
            do { try previous.requireSameOwner(owner) }
            catch { page.invalidate(); throw error }
        }
        page.owner = owner
        _ = try await self.cookies(view, page: page, document: document)
        try current(page, scope: scope, document: document)
        return (cookies, owner)
    }
    private func cookies(_ view: WKWebView, page: Page, document: UUID) async throws -> String {
        let cookies: String
        do { cookies = try await cookieReader(view, page.configuration) }
        catch {
            if page.authority.documentID == document { page.invalidate() }
            throw error
        }
        guard !page.retired, page.authority.documentID == document else { throw AgentBridgeFailure.scopeChanged }
        guard !cookies.isEmpty else { page.invalidate(); throw AgentBridgeFailure.scopeChanged }
        let fingerprint = Data(SHA256.hash(data: Data(cookies.utf8)))
        if let previous = page.cookiesFingerprint, previous != fingerprint {
            page.invalidate(); throw AgentBridgeFailure.scopeChanged
        }
        page.cookiesFingerprint = fingerprint
        return cookies
    }
    private func current(_ page: Page, scope: String, document: UUID) throws {
        guard !page.retired else { throw AgentBridgeFailure.scopeChanged }
        try page.authority.requireCurrent(scope: scope, documentID: document)
    }
    private static func readCookies(_ view: WKWebView, configuration: DesktopEnvironmentConfiguration) async throws -> String {
        let host = configuration.appURL.host?.lowercased() ?? ""
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && (!cookie.isSecure || configuration.appURL.scheme == "https")
                && cookie.expiresDate.map({ $0 > Date() }) != false && cookie.name.hasPrefix("personastack")
        }.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        guard !cookies.isEmpty else { throw AgentBridgeFailure.scopeChanged }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
    }
    private static func readCSRF(_ view: WKWebView) async throws -> String {
        let result = try await view.evaluateJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || ''")
        guard let token = result as? String, !token.isEmpty, token.utf8.count <= 512,
              !token.contains(where: { $0.isWhitespace }) else { throw AgentBridgeFailure.scopeChanged }
        return token
    }
    private static func clusterName() -> String {
        let candidate = Host.current().localizedName ?? "This Mac"
        var clean = ""
        for scalar in candidate.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            guard clean.utf8.count + String(scalar).utf8.count <= 120 else { break }
            clean.unicodeScalars.append(scalar)
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "This Mac" : trimmed
    }
    private static func confirmLocalRemoval() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove local cluster data?"
        alert.informativeText = "This permanently deletes this Mac's cluster disk and agent files. Cloud connection retirement is separate. PersonaStack will report both results. This cannot be undone."
        alert.addButton(withTitle: "Remove Local Data"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func confirmBlankSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start a new blank setup?"
        alert.informativeText = "The previous cluster data has been removed. This releases its retired local setup so a later Install action can create a new blank cluster. The previous files and cluster identity will not return."
        alert.addButton(withTitle: "New Blank Setup"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    static func setupBudgetMessage(_ requirements: AgentBridgeLocalClusterRequirements) -> String {
        """
        Virtual CPUs: \(requirements.cpus)
        Allocated RAM: \(budgetBytes(requirements.memoryBytes))
        Sparse virtual disk maximum: \(budgetBytes(requirements.diskBytes)) (grows as used)
        Minimum physical RAM: \(budgetBytes(requirements.minimumHostMemoryBytes))
        Initial runtime download: \(budgetBytes(requirements.initialDownloadBytes)). Provider images require additional downloads and disk space.

        These minimums are conservative setup policy. Authorized work continues after you quit PersonaStack or sign out of the app. Your Mac must stay awake, connected to the network, and logged in to macOS. Use Stop in Agents on This Mac to stop local work and retain its files.
        """
    }
    private static func budgetBytes(_ bytes: Int64) -> String {
        let unit: Int64, label: String
        switch bytes {
        case 1_073_741_824...: unit = 1_073_741_824; label = "GiB"
        case 1_048_576...: unit = 1_048_576; label = "MiB"
        case 1_024...: unit = 1_024; label = "KiB"
        default: unit = 1; label = "bytes"
        }
        if bytes % unit == 0 { return "\(bytes / unit) \(label)" }
        return String(format: "%.1f %@", Double(bytes) / Double(unit), label)
    }
    private static func presentSetupBudget(_ requirements: AgentBridgeLocalClusterRequirements) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Set up agents on this Mac?"
        alert.informativeText = setupBudgetMessage(requirements)
        alert.addButton(withTitle: "Set Up This Mac"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func presentSetupBudgetDetails(_ requirements: AgentBridgeLocalClusterRequirements) {
        let alert = NSAlert()
        alert.messageText = "This Mac does not meet the local runtime setup policy."
        alert.informativeText = "Setup needs at least \(requirements.cpus) active CPU cores and \(budgetBytes(requirements.minimumHostMemoryBytes)) of physical RAM. This attempt has not created an installation key or started the VM."
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
    private static func presentUpdates() {
        let updater = DesktopUpdater.shared
        if updater.isReady { updater.restartToInstall() }
        else { updater.checkForUpdates() }
    }
    private static func presentCredentialDetails() {
        let alert = NSAlert()
        alert.messageText = "Local setup credentials are unavailable."
        alert.informativeText = "PersonaStack cannot read this Mac's saved installation key or setup credential. If the login Keychain is locked, unlock it and try the same action again. A missing key needs review before reconnecting. Credential repair does not reset or delete local files. PersonaStack will not automatically create another cluster or replace the saved identity."
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
    private static func presentDetails() {
        let alert = NSAlert()
        alert.messageText = "Existing local cluster files need review."
        alert.informativeText = "PersonaStack could not verify the existing local cluster files. Your files stay on this Mac. Check for an app update before trying again. Setup will not reset or replace the cluster disk."
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
    private static func confirmCredentialRotation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reconnect this Mac's cluster?"
        alert.informativeText = "PersonaStack could not retain the previous setup credential. Reconnecting replaces that credential for this Mac's existing cluster. Local files and cluster identity stay unchanged."
        alert.addButton(withTitle: "Reconnect Cluster"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func confirmStop() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop this Mac's cluster?"
        alert.informativeText = "Running personas will be interrupted. Local files stay on this Mac. Persona Pause and provider choices stay unchanged."
        alert.addButton(withTitle: "Stop Cluster"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
