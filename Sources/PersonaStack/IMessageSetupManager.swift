import AppKit
import Combine
import CryptoKit
import Foundation
import PersonaStackCore
import ServiceManagement
import WebKit

enum IMessageSetupCoordinatorError: Error, Equatable {
    case invalidRequest, scopeChanged, busy, permissionRequired, backgroundRequired, unsupported, unavailable
}

/// One hosted wizard. This owner retains native intention and private custody.
/// Page commands cannot supply identity, credentials, source proof or consent.
@MainActor
final class IMessageSetupManager: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    static let shared = IMessageSetupManager()
    static let bridgeName = "personastackIMessage"
    @Published private(set) var menuState: IMessageMenuState = .setupRequired
    var navigateMainWindow: ((URL) -> Void)?

    struct Review: Equatable {
        let workspaceName: String
        let macName: String
        let accountLabel: String
        let conversations: [IMessageGatewaySetupConversation]
    }
    @MainActor struct Dependencies {
        var configuration: @MainActor (URL) throws -> DesktopEnvironmentConfiguration = { try DesktopEnvironmentConfigurationStore.shared.environment(for: $0) }
        var currentConfiguration: @MainActor () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() }
        var cookies: @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = IMessageSetupManager.readCookies
        var csrf: @MainActor (WKWebView) async throws -> String = IMessageSetupManager.readCSRF
        var store: @MainActor (DesktopEnvironmentConfiguration) -> FileDesktopControlCredentialStore = { config in .init(configurationProvider: { config }) }
        var session: @MainActor () async throws -> IMessageNativeSession = { try await DesktopControlRuntime.shared.iMessageSetupSession() }
        var retainRelay: @MainActor (IMessageRuntimeSetupIntent) async throws -> UUID = { try await DesktopControlRuntime.shared.resumeIMessageSetupRelay(for: $0) }
        var releaseRelay: @MainActor (IMessageRuntimeSetupIntent, UUID) async -> Void = { await DesktopControlRuntime.shared.finishIMessageSetupRelay(for: $0, generation: $1) }
        var permissionState: @MainActor (IMessageNativeSession, Date) async throws -> IMessageSetupPermissionState = { try await $0.provider.setupPermissionState(deadline: $1) }
        var messagesAccess: @MainActor (IMessageNativeSession, Date) async throws -> Void = { try await $0.provider.requestMessagesAccess(deadline: $1) }
        var accountLabel: @MainActor (IMessageNativeSession, IMessageSetupAccount) async throws -> String = { try await $0.provider.displayAccount(for: $1) }
        var evidence: @MainActor (IMessageNativeSession, IMessageSetupFinalConsent, @escaping @Sendable (IMessageSetupFinalConsent) async throws -> Bool) async throws -> IMessageSetupApprovalEvidence = {
            try await $0.provider.approvalEvidence(for: $1, deadline: $1.deadline, validateCurrent: $2)
        }
        var prepareBackground: @MainActor (DesktopEnvironmentConfiguration) async throws -> Void = { try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: $0) }
        var backgroundReady: @MainActor () -> Bool = { IMessageSetupLifetime.backgroundReady }
        var restart: @MainActor (DesktopEnvironmentConfiguration) throws -> Void = { try DesktopApplicationRestart.requestIMessageSetupResume(configuration: $0) }
        var showReview: (@MainActor (Review, NSWindow?) async -> Bool)?
        var showMetadataConsent: (@MainActor (NSWindow?) async -> Bool)?
        var openMessages: @MainActor () -> Void = { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app")) }
        var openSettings: @MainActor (String) -> Void = { section in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section) { NSWorkspace.shared.open(url) }
        }
        var openLoginItems: @MainActor () -> Void = { SMAppService.openSystemSettingsLoginItems() }
        var navigate: @MainActor (URL) -> Void = { MainWebViewHost.shared.navigate(to: $0) }
        var synchronizeReference: @MainActor (WKWebView, String) async throws -> Void = { view, reference in
            _ = try await view.callAsyncJavaScript("history.replaceState(null, '', '/user/imessage?setup_reference=' + reference)",
                arguments: ["reference": reference], in: nil, contentWorld: .page)
        }
        var macName: @MainActor () -> String = { Host.current().localizedName ?? "This Mac" }
        var now: () -> Date = Date.init
        var preferences: UserDefaults = .standard
    }

    private enum Phase: String { case idle, continueSetup = "continue", permissions, background, selecting, review, assignPersonas = "assign_personas", needsAttention = "needs_attention" }
    @MainActor private final class Page {
        let configuration: DesktopEnvironmentConfiguration
        var generation = UUID()
        var scopeToken = UUID().uuidString.lowercased()
        var cookiesFingerprint: Data?
        var scope: IMessageHostedNativeScope?
        var display: IMessageHostedDisplayContext?
        var journey: IMessageHostedJourney?
        var reference: String?
        var session: IMessageNativeSession?
        var ticket: IMessageHostedEnrollmentTicket?
        var mode: IMessageHostedEnrollmentMode?
        var intent: IMessageRuntimeSetupIntent?
        var relayReceipt: UUID?
        var resetReceipt: IMessageEnrollmentResetReceipt?
        var selectedIDs: [String] = []
        var selectedDisplay: [[String: Any]] = []
        var verificationReady = false
        var nextAction = "start_again"
        var journeyUnavailable = false
        var page: IMessageHostedConversationsPage?
        var permissionsReady = false
        var backgroundReady = false
        var phase: Phase = .idle
        var reason: String?
        var configID: String?
        var createAttempted = false
        var busy = false
        var retired = false
        var nativeAlert: NSAlert?
        var operationIDs = Set<UUID>()
        var documentReady = false
        var restartAvailable = false
        init(_ configuration: DesktopEnvironmentConfiguration) { self.configuration = configuration }
    }
    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()
    private let hosted: IMessageHostedSetupClient
    private let machine: IMessageMachineSetupClient
    private let dependencies: Dependencies
    private var pendingHandoff: IMessageSetupHandoff?
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?

    init(hosted: IMessageHostedSetupClient = .init(), machine: IMessageMachineSetupClient = .init(), dependencies: Dependencies = .init()) {
        self.hosted = hosted; self.machine = machine; self.dependencies = dependencies
        super.init()
        if let configuration = try? dependencies.currentConfiguration(), dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)) {
            menuState = dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration)) ? .paused : .offline
        }
    }
    var hasPendingShutdown: Bool {
        cleanupID != nil || !operations.isEmpty || currentPages.contains(where: { $0.busy || $0.intent != nil || $0.session != nil })
    }
    private var currentPages: [Page] { pages.objectEnumerator()?.allObjects as? [Page] ?? [] }

    func register(_ view: WKWebView, appURL: URL) {
        guard let configuration = try? dependencies.configuration(appURL) else { return }
        let page = Page(configuration)
        page.reference = pendingHandoff?.setupReference
        pages.setObject(page, forKey: view)
    }
    func receive(_ handoff: IMessageSetupHandoff) {
        pendingHandoff = handoff
        openSetup()
    }
    func openSetup() {
        guard let configuration = try? dependencies.currentConfiguration() else { return }
        var url = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        url.path = "/user/imessage"; url.fragment = nil
        url.queryItems = pendingHandoff.map { [URLQueryItem(name: "setup_reference", value: $0.setupReference)] }
        if let navigateMainWindow { navigateMainWindow(url.url!) }
        else { dependencies.navigate(url.url!) }
    }
    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        page.generation = UUID(); page.scopeToken = UUID().uuidString.lowercased()
        page.cookiesFingerprint = nil; page.scope = nil; page.display = nil
        page.configID = nil; page.reason = nil; page.phase = page.reference == nil ? .idle : .continueSetup
        page.createAttempted = false
        page.permissionsReady = false; page.backgroundReady = false
        page.restartAvailable = false
        page.verificationReady = false; page.nextAction = page.reference == nil ? "start_again" : "continue"
        page.resetReceipt = nil
        for id in page.operationIDs { operations[id]?.cancel() }
        if let alert = page.nativeAlert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        scheduleWithdrawal(page)
    }
    func unregister(_ view: WKWebView) {
        pages.object(forKey: view)?.retired = true
        invalidate(view); pages.removeObject(forKey: view)
    }
    func documentInvalidated(_ view: WKWebView) {
        pages.object(forKey: view)?.documentReady = false
        invalidate(view)
    }
    func documentCommitted(_ view: WKWebView) { pages.object(forKey: view)?.documentReady = true }
    func invalidateSession() {
        for view in pages.keyEnumerator().allObjects as? [WKWebView] ?? [] { invalidate(view) }
    }
    func shutdown() async {
        for task in operations.values { task.cancel() }
        invalidateSession()
        for task in Array(operations.values) { await task.value }
        await cleanup?.value
    }
    func pause() async {
        if let configuration = try? dependencies.currentConfiguration() {
            dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayPaused(configuration))
        }
        await shutdown(); menuState = .paused
    }
    func resume() async {
        // Active-config runtime operations have no producer in this slice.
        // Opening the canonical hosted flow is the explicit repair path.
        menuState = .needsAttention; openSetup()
    }
    func recheckAfterActivation(_ view: WKWebView) {
        guard let page = pages.object(forKey: view), page.documentReady, !page.busy,
              page.session != nil, [.permissions, .background].contains(page.phase), view.window?.isVisible == true else { return }
        guard let command = try? IMessageSetupPageCommand.parse(["version": "1", "action": "check_permissions", "scope": page.scopeToken]) else { return }
        enqueue(page) { _ = try? await self.apply(command, view: view) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.name == Self.bridgeName, let view = message.webView, let page = pages.object(forKey: view),
              !page.retired, page.documentReady, view.url?.path == "/user/imessage",
              message.frameInfo.request.url?.path == "/user/imessage",
              ChatWindowManager.trusted(message, base: page.configuration.appURL),
              let command = try? IMessageSetupPageCommand.parse(message.body) else {
            replyHandler(nil, "invalid_request"); return
        }
        enqueue(page) {
            do { replyHandler(try await self.apply(command, view: view), nil) }
            catch { replyHandler(nil, Self.safeReason(error)) }
        }
    }
    private func enqueue(_ page: Page, action: @escaping @MainActor () async -> Void) {
        let id = UUID()
        page.operationIDs.insert(id)
        operations[id] = Task {
            defer { operations.removeValue(forKey: id); page.operationIDs.remove(id) }
            await action()
        }
    }

    func apply(_ command: IMessageSetupPageCommand, view: WKWebView) async throws -> [String: Any] {
        guard let page = pages.object(forKey: view), !page.retired else { throw IMessageSetupCoordinatorError.scopeChanged }
        if command.action != .begin && !(command.action == .state && command.scope.isEmpty) {
            guard command.scope == page.scopeToken else { throw IMessageSetupCoordinatorError.scopeChanged }
        }
        if command.action == .cancel {
            invalidate(view)
            return projection(page)
        }
        guard !page.busy else { throw IMessageSetupCoordinatorError.busy }
        page.busy = true
        defer { page.busy = false }
        let generation = page.generation
        do {
            let cookies = try await authorize(page, view: view, generation: generation)
            try await dispatch(command, page: page, view: view, generation: generation, cookies: cookies)
            try await requireCurrent(page, view: view, generation: generation)
            return projection(page)
        } catch {
            if Self.revokesLocalAuthority(error) { invalidate(view) }
            throw error
        }
    }

    private func dispatch(_ command: IMessageSetupPageCommand, page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        switch command.action {
        case .begin:
            guard let handoff = command.handoff else { throw IMessageSetupCoordinatorError.invalidRequest }
            await withdraw(page); try current(page, generation: generation)
            page.reference = handoff.setupReference; page.journey = nil; page.configID = nil; page.journeyUnavailable = false
            page.resetReceipt = nil; page.ticket = nil; page.mode = nil
            page.permissionsReady = false; page.backgroundReady = false; page.restartAvailable = false
            pendingHandoff = handoff
            try await resolveJourney(page, view: view, generation: generation, cookies: cookies)
        case .state:
            if page.reference == nil { try restoreReference(page) }
            if page.reference != nil { try await resolveJourney(page, view: view, generation: generation, cookies: cookies) }
            else { page.phase = .idle; page.nextAction = "start_again"; page.reason = nil }
        case .continueSetup: try await continueSetup(page, view: view, generation: generation, cookies: cookies)
        case .allowMetadata: try await allowMetadata(page, view: view, generation: generation)
        case .list: try await list(command, page: page, view: view, generation: generation, cookies: cookies)
        case .setSelected: try await select(command.conversationIDs, page: page, view: view, generation: generation)
        case .verify: try await verify(page, view: view, generation: generation, cookies: cookies)
        case .confirm: try await confirm(page, view: view, generation: generation, cookies: cookies)
        case .cancel: await withdraw(page); page.phase = .continueSetup
        case .startAgain: try await startAgain(page, view: view, generation: generation, cookies: cookies)
        default: try await localAction(command.action, page: page, view: view, generation: generation)
        }
    }

    private func authorize(_ page: Page, view: WKWebView, generation: UUID) async throws -> String {
        let cookies = try await dependencies.cookies(view, page.configuration)
        try current(page, generation: generation)
        let fingerprint = Data(SHA256.hash(data: Data(cookies.utf8)))
        guard page.cookiesFingerprint == nil || page.cookiesFingerprint == fingerprint else {
            invalidate(view); throw IMessageSetupCoordinatorError.scopeChanged
        }
        page.cookiesFingerprint = fingerprint
        let scope = try await hosted.nativeScope(configuration: page.configuration, cookies: cookies) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        guard page.scope == nil || page.scope == scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        page.scope = scope
        page.display = try await hosted.displayContext(configuration: page.configuration, cookies: cookies, expectedScope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        return cookies
    }
    private func current(_ page: Page, generation: UUID) throws {
        try Task.checkCancellation()
        guard !page.retired, page.generation == generation, try dependencies.currentConfiguration() == page.configuration else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
    }
    private func requireCurrent(_ page: Page, view: WKWebView, generation: UUID) async throws {
        try current(page, generation: generation)
        let cookies = try await dependencies.cookies(view, page.configuration)
        try current(page, generation: generation)
        guard page.cookiesFingerprint == Data(SHA256.hash(data: Data(cookies.utf8))) else { throw IMessageSetupCoordinatorError.scopeChanged }
    }
    private func readJourney(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let reference = page.reference, let scope = page.scope else { throw IMessageSetupCoordinatorError.invalidRequest }
        let locator = try IMessageHostedJourneyLocator(setupReference: reference, generation: 1)
        let journey = try await hosted.readJourney(locator, configuration: page.configuration, cookies: cookies, expectedScope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        guard try IMessageGatewayWire.utcDate(journey.expiresAt) > dependencies.now() else {
            try await unavailableJourney(page, view: view, generation: generation, reason: "setup_unavailable"); return
        }
        if let old = page.journey, (old.generation != journey.generation || old.expiresAt != journey.expiresAt), page.intent != nil {
            await withdraw(page); try current(page, generation: generation)
        }
        page.journey = journey
        page.journeyUnavailable = false; page.reason = nil
        if let configID = journey.integrationConfigID {
            let verified = page.createAttempted && page.intent != nil
            await withdraw(page); try current(page, generation: generation)
            complete(configID, page: page, verifiedLocally: verified)
        }
        else if page.intent == nil { page.phase = .continueSetup; page.nextAction = "continue" }
    }
    private func resolveJourney(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        if try expiredPrivateReference(page) {
            try await unavailableJourney(page, view: view, generation: generation, reason: "setup_unavailable"); return
        }
        do { try await readJourney(page, view: view, generation: generation, cookies: cookies) }
        catch IMessageHostedSetupError.scopeChanged {
            try await requireCurrent(page, view: view, generation: generation)
            try await unavailableJourney(page, view: view, generation: generation, reason: "switch_workspace_or_account")
        }
    }
    private func unavailableJourney(_ page: Page, view: WKWebView, generation: UUID, reason: String) async throws {
        await withdraw(page)
        try await requireCurrent(page, view: view, generation: generation)
        page.journey = nil; page.journeyUnavailable = true; page.phase = .needsAttention
        page.nextAction = "start_again"; page.reason = reason
    }
    private func expiredPrivateReference(_ page: Page) throws -> Bool {
        guard let reference = page.reference, let scope = page.scope,
              let draft = try dependencies.store(page.configuration).loadSetupDraft(), draft.setupReference == reference else { return false }
        guard draft.naturalUserID == scope.naturalUserID, draft.workspaceID == scope.workspaceID,
              draft.environmentIdentity == page.configuration.preferenceIdentity else { throw IMessageSetupCoordinatorError.scopeChanged }
        return draft.expiry <= dependencies.now()
    }
    private func restoreReference(_ page: Page) throws {
        if let reference = pendingHandoff?.setupReference { page.reference = reference; return }
        guard let draft = try dependencies.store(page.configuration).loadSetupDraft() else { return }
        try draft.requireEnvironment(page.configuration.preferenceIdentity)
        guard draft.naturalUserID == page.scope?.naturalUserID, draft.workspaceID == page.scope?.workspaceID else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        page.reference = draft.setupReference
    }

    private func continueSetup(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        try await resolveJourney(page, view: view, generation: generation, cookies: cookies)
        guard !page.journeyUnavailable else { return }
        guard page.configID == nil, let journey = page.journey, let scope = page.scope else { return }
        let csrf = try await dependencies.csrf(view)
        try await requireCurrent(page, view: view, generation: generation)
        let authorized = try await hosted.reauthorizeJourney(journey.locator, configuration: page.configuration,
            cookies: cookies, csrf: csrf, expectedScope: scope) { try await self.requireCurrent(page, view: view, generation: generation) }
        if page.journey != authorized { await withdraw(page) }
        page.journey = authorized
        try await enroll(page, view: view, generation: generation, cookies: cookies, csrf: csrf)
        guard page.resetReceipt == nil else { return }
        let session = try await dependencies.session()
        try await requireCurrent(page, view: view, generation: generation)
        guard session.configuration == page.configuration else { throw IMessageSetupCoordinatorError.scopeChanged }
        page.session = session
        try saveDraft(page)
        page.phase = .permissions; menuState = .connecting
        page.nextAction = "check_permissions"
    }
    private func enroll(_ page: Page, view: WKWebView, generation: UUID, cookies: String, csrf: String) async throws {
        guard let journey = page.journey, let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let store = dependencies.store(page.configuration)
        let installation = try store.load()
        let pending = try installation == nil ? preparePending(store, scope: scope, journey: journey) : nil
        let mode: IMessageHostedEnrollmentMode = installation.map { .attach(installationID: $0.installationID) } ?? .enroll
        let proof = installation?.machineCredential ?? pending!.machineCredential
        let digest = try Self.credentialDigest(proof)
        let ticket = try await hosted.enrollmentTicket(journey.locator, mode: mode, credentialSHA256: digest,
            configuration: page.configuration, cookies: cookies, csrf: csrf, expectedScope: scope) {
                try await self.requireCurrent(page, view: view, generation: generation)
            }
        let validate: IMessageMachineSetupClient.ValidateScope = { expected in
            guard expected == generation else { throw IMessageSetupCoordinatorError.scopeChanged }
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        if let installation {
            let attached = try await machine.attach(configuration: page.configuration, installation: installation,
                verifiedScope: scope, journey: journey, ticket: ticket, coordinatorGeneration: generation, now: dependencies.now(), validateScope: validate)
            try store.save(attached)
            guard try store.load()?.installationID == attached.installationID else { throw IMessageSetupCoordinatorError.unavailable }
        } else if let pending {
            switch try await machine.enroll(configuration: page.configuration, pending: pending, verifiedScope: scope,
                journey: journey, ticket: ticket, coordinatorGeneration: generation, now: dependencies.now(), validateScope: validate) {
            case .enrolled(let installed):
                guard try store.completePendingEnrollment(matching: pending, installation: installed) else { throw IMessageSetupCoordinatorError.unavailable }
            case .resetRequired(let receipt):
                page.resetReceipt = receipt; page.phase = .needsAttention; page.reason = "start_again_required"; page.nextAction = "start_again"
            }
        }
        page.ticket = ticket; page.mode = mode
    }
    private func preparePending(_ store: FileDesktopControlCredentialStore, scope: IMessageHostedNativeScope, journey: IMessageHostedJourney) throws -> IMessagePendingEnrollment {
        if let pending = try store.loadPendingEnrollment() {
            return try store.recoverPendingEnrollment(matching: pending, verifiedScope: scope, journey: journey, now: dependencies.now())
        }
        return try store.preparePendingEnrollment(setupReference: journey.setupReference, naturalUserID: scope.naturalUserID,
            workspaceID: scope.workspaceID, expiresAt: journey.expiresAt, now: dependencies.now())
    }

    private func localAction(_ action: IMessageSetupPageCommand.Action, page: Page, view: WKWebView, generation: UUID) async throws {
        switch action {
        case .openMessages: dependencies.openMessages(); page.nextAction = "check_permissions"
        case .openFullDiskAccess:
            dependencies.openSettings("Privacy_AllFiles"); page.restartAvailable = true; page.nextAction = "check_permissions"
        case .openAutomationSettings: dependencies.openSettings("Privacy_Automation"); page.nextAction = "check_permissions"
        case .openLoginItems: dependencies.openLoginItems(); page.nextAction = "enable_background"
        case .restart:
            await withdraw(page); try await requireCurrent(page, view: view, generation: generation)
            try dependencies.restart(page.configuration)
        case .enableBackground:
            do { try await dependencies.prepareBackground(page.configuration) }
            catch let error as IMessageSetupLifetimeError {
                try await requireCurrent(page, view: view, generation: generation)
                page.reason = Self.lifetimeReason(error)
                page.nextAction = error == .backgroundApprovalRequired ? "open_login_items" : "review_installation"
                return
            }
            try await requireCurrent(page, view: view, generation: generation)
            page.backgroundReady = dependencies.backgroundReady()
            guard page.backgroundReady else { throw IMessageSetupCoordinatorError.backgroundRequired }
            page.nextAction = "allow_metadata"
        case .requestMessagesAccess, .checkPermissions:
            guard let session = page.session else { throw IMessageSetupCoordinatorError.invalidRequest }
            let deadline = dependencies.now().addingTimeInterval(10)
            if action == .requestMessagesAccess { try await dependencies.messagesAccess(session, deadline) }
            let state = try await dependencies.permissionState(session, deadline)
            try await requireCurrent(page, view: view, generation: generation)
            page.permissionsReady = state == .ready
            page.restartAvailable = page.restartAvailable && state == .fullDiskAccessRequired
            page.phase = page.permissionsReady ? .background : .permissions
            page.nextAction = Self.permissionAction(state)
            page.reason = state == .unavailable ? "setup_unavailable" : nil
        default: throw IMessageSetupCoordinatorError.unsupported
        }
    }
    private func allowMetadata(_ page: Page, view: WKWebView, generation: UUID) async throws {
        guard page.permissionsReady else { throw IMessageSetupCoordinatorError.permissionRequired }
        guard page.backgroundReady, dependencies.backgroundReady() else { throw IMessageSetupCoordinatorError.backgroundRequired }
        guard let session = page.session, let scope = page.scope, let journey = page.journey else { throw IMessageSetupCoordinatorError.scopeChanged }
        let accepted: Bool
        if let showConsent = dependencies.showMetadataConsent { accepted = await showConsent(view.window) }
        else { accepted = await presentMetadataConsent(window: view.window, page: page) }
        try await requireCurrent(page, view: view, generation: generation)
        guard accepted else { return }
        let intent = IMessageRuntimeSetupIntent(localGeneration: generation, scope: .init(setupReferenceSHA256: Self.digest(journey.setupReference),
            generation: journey.generation, workspaceID: scope.workspaceID, userID: scope.naturalUserID, expiresAt: journey.expiresAt, enabled: true))
        page.intent = intent
        try await session.runtime.activateLocalSetup(intent)
        try await requireCurrent(page, view: view, generation: generation)
        try await session.runtime.setMetadataConsent(true, for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        let receipt = try await dependencies.retainRelay(intent)
        do { try await requireCurrent(page, view: view, generation: generation) }
        catch { await dependencies.releaseRelay(intent, receipt); throw error }
        page.relayReceipt = receipt
        try await restoreSelection(page, view: view, generation: generation)
        page.phase = .selecting
        page.verificationReady = false; page.nextAction = "list"
    }
    private func restoreSelection(_ page: Page, view: WKWebView, generation: UUID) async throws {
        guard let session = page.session, let intent = page.intent, let journey = page.journey, let scope = page.scope,
              let draft = try dependencies.store(page.configuration).loadSetupDraft(), !draft.selectedConversations.isEmpty else { return }
        try draft.requireJourney(setupReference: journey.setupReference, naturalUserID: scope.naturalUserID, workspaceID: scope.workspaceID,
            environmentIdentity: page.configuration.preferenceIdentity, expiresAt: journey.expiresAt)
        try draft.requireUsable(now: dependencies.now())
        guard let account = draft.expectedAccountID, let source = draft.sourceGeneration else { throw IMessageSetupCoordinatorError.scopeChanged }
        let retained = try await session.runtime.restoreSelection(draft.selectedConversations, account: .init(accountID: account, sourceGeneration: source),
            originalExpiresAt: min(draft.expiry, dependencies.now().addingTimeInterval(300)), for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        page.selectedIDs = retained.conversations.map(\.conversationID)
        page.selectedDisplay = Self.selectedProjection(retained.conversations)
    }
    private func list(_ command: IMessageSetupPageCommand, page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        let response = try await metadata(.setupConversations(.init(query: command.query, snapshotToken: command.snapshotToken,
            pageToken: command.pageToken, limit: 50)), page: page, view: view, generation: generation, cookies: cookies)
        guard case .conversationsPage(let result)? = response.result else { throw IMessageSetupCoordinatorError.unavailable }
        page.page = result; page.phase = .selecting
        page.verificationReady = false
    }
    private func select(_ ids: [String], page: Page, view: WKWebView, generation: UUID) async throws {
        guard let session = page.session, let intent = page.intent else { throw IMessageSetupCoordinatorError.scopeChanged }
        try await session.runtime.setSelectedConversationIDs(ids, for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        page.selectedIDs = ids
        page.verificationReady = false
        page.nextAction = ids.isEmpty ? "list" : "verify"
        try await saveSelectionDraft(page, view: view, generation: generation)
    }
    private func verify(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        let result = try await metadata(.verifyConversations(.init(conversationIDs: page.selectedIDs)), page: page, view: view, generation: generation, cookies: cookies)
        guard case .verification(let verified)? = result.result else { throw IMessageSetupCoordinatorError.unavailable }
        page.selectedDisplay = verified.conversations.map { ["conversation_id": $0.conversationID, "label": $0.label, "available": $0.available] }
        page.verificationReady = verified.verified
        guard verified.verified else { page.reason = "selection_unavailable"; page.phase = .selecting; return }
        page.phase = .review
        page.reason = nil; page.nextAction = "confirm"
    }
    private func metadata(_ input: IMessageGatewayCommandInput, page: Page, view: WKWebView, generation: UUID, cookies: String) async throws -> IMessageHostedMetadataResponse {
        guard page.intent != nil, let scope = page.scope, let journey = page.journey, let ticket = page.ticket else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        let csrf = try await dependencies.csrf(view)
        return try await hosted.executeMetadata(.init(locator: journey.locator, enrollmentTicket: ticket.enrollmentTicket, input: input),
            configuration: page.configuration, cookies: cookies, csrf: csrf, expectedScope: scope) {
                try await self.requireCurrent(page, view: view, generation: generation)
            }
    }

    private func confirm(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard page.phase == .review, page.verificationReady else { throw IMessageSetupCoordinatorError.invalidRequest }
        guard let decision = try await prepareFinalConsent(page, view: view, generation: generation) else { return }
        try await commit(decision.consent, review: decision.review, page: page, view: view, generation: generation, cookies: cookies)
    }
    private func prepareFinalConsent(_ page: Page, view: WKWebView, generation: UUID) async throws -> (consent: IMessageSetupFinalConsent, review: Review)? {
        guard let session = page.session, let intent = page.intent, let display = page.display else { throw IMessageSetupCoordinatorError.scopeChanged }
        let selection = try await session.runtime.retainedSelection(for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        let label = try await dependencies.accountLabel(session, selection.account)
        try await requireCurrent(page, view: view, generation: generation)
        let review = Review(workspaceName: display.workspaceName, macName: dependencies.macName(), accountLabel: label, conversations: selection.conversations)
        let accepted: Bool
        if let showReview = dependencies.showReview { accepted = await showReview(review, view.window) }
        else { accepted = await presentReview(review, window: view.window, page: page) }
        guard accepted else { return nil }
        try await requireCurrent(page, view: view, generation: generation)
        let fresh = try await session.runtime.retainedSelection(for: intent)
        guard fresh.conversations == selection.conversations, fresh.account == selection.account, fresh.expiresAt == selection.expiresAt else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        let now = dependencies.now()
        let consent = try IMessageSetupFinalConsent(intent: intent, installationID: session.installation.installationID,
            environmentIdentity: page.configuration.preferenceIdentity, conversations: selection.conversations, account: selection.account,
            readEnabled: true, sendEnabled: true, selectionAndCapabilitiesConfirmed: true, confirmedAt: now, deadline: now.addingTimeInterval(10))
        return (consent, review)
    }
    private func commit(_ consent: IMessageSetupFinalConsent, review: Review, page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let session = page.session, let scope = page.scope, let journey = page.journey,
              let ticket = page.ticket, let mode = page.mode else { throw IMessageSetupCoordinatorError.scopeChanged }
        let validate: IMessageHostedSetupClient.ValidateFinalConsent = { value in
            try await self.requireFinal(value, page: page, view: view, generation: generation)
        }
        let evidence = try await dependencies.evidence(session, consent) { value in
            try await validate(value); return true
        }
        try await validate(consent)
        let receipt = try await hosted.approve(consent: consent, evidence: evidence, installation: session.installation, journey: journey,
            ticket: ticket, mode: mode, macName: review.macName, accountLabel: review.accountLabel,
            configuration: page.configuration, now: dependencies.now(), validateCurrent: validate)
        let csrf = try await dependencies.csrf(view)
        try await validate(consent)
        page.createAttempted = true
        let configID = try await hosted.createConfiguration(receipt: receipt, consent: consent, configuration: page.configuration,
            cookies: cookies, csrf: csrf, expectedScope: scope, now: dependencies.now(), validateCurrent: validate)
        complete(configID, page: page, verifiedLocally: true)
        await withdraw(page)
    }
    private func requireFinal(_ consent: IMessageSetupFinalConsent, page: Page, view: WKWebView, generation: UUID) async throws {
        try await requireCurrent(page, view: view, generation: generation)
        guard page.phase == .review, page.intent == consent.intent, consent.deadline > dependencies.now(),
              let session = page.session else { throw IMessageSetupCoordinatorError.scopeChanged }
        let retained = try await session.runtime.retainedSelection(for: consent.intent)
        guard retained.conversations == consent.conversations, retained.account == consent.account else { throw IMessageSetupCoordinatorError.scopeChanged }
    }
    private func complete(_ configID: String, page: Page, verifiedLocally: Bool) {
        page.configID = configID; page.phase = .assignPersonas; page.createAttempted = false
        page.nextAction = "assign_personas"
        menuState = verifiedLocally ? .connected : .needsAttention
        if verifiedLocally {
            dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(page.configuration))
            dependencies.preferences.set(false, forKey: IMessagePreferenceKeys.relayPaused(page.configuration))
        }
    }
    private func startAgain(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let store = dependencies.store(page.configuration)
        let pending = try store.loadPendingEnrollment()
        try requireFreshJourneyOwner(page, pending: pending, draft: store.loadSetupDraft())
        if let receipt = page.resetReceipt {
            guard receipt.coordinatorGeneration == generation, receipt.verifiedScope == scope,
                  receipt.environmentIdentity == page.configuration.preferenceIdentity, pending == receipt.pending,
                  try store.load() == nil else { throw IMessageSetupCoordinatorError.scopeChanged }
        }
        let csrf = try await dependencies.csrf(view)
        let journey = try await hosted.createJourney(configuration: page.configuration, cookies: cookies, csrf: csrf, expectedScope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        let expiry = try IMessageGatewayWire.utcDate(journey.expiresAt)
        guard expiry > dependencies.now(), journey.setupReference != page.reference else { throw IMessageHostedSetupError.invalidResponse }
        await withdraw(page); try await requireCurrent(page, view: view, generation: generation)
        if let receipt = page.resetReceipt {
            guard try store.discardPendingEnrollment(matching: receipt, explicitStartAgain: true, currentGeneration: generation) else {
                throw IMessageSetupCoordinatorError.scopeChanged
            }
        } else if let pending {
            _ = try store.recoverPendingEnrollment(matching: pending, verifiedScope: scope, journey: journey, now: dependencies.now())
        }
        page.reference = journey.setupReference; page.journey = journey; page.journeyUnavailable = false
        page.resetReceipt = nil; page.ticket = nil; page.mode = nil; page.configID = nil; page.createAttempted = false
        page.permissionsReady = false; page.backgroundReady = false; page.restartAvailable = false
        page.phase = .continueSetup; page.nextAction = "continue"; page.reason = nil
        pendingHandoff = try IMessageSetupHandoff(setupReference: journey.setupReference)
        try saveDraft(page)
        try await dependencies.synchronizeReference(view, journey.setupReference)
        try await requireCurrent(page, view: view, generation: generation)
    }
    private func requireFreshJourneyOwner(_ page: Page, pending: IMessagePendingEnrollment?, draft: IMessageSetupDraft?) throws {
        guard let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        if let pending {
            guard pending.naturalUserID == scope.naturalUserID, pending.workspaceID == scope.workspaceID,
                  pending.environmentIdentity == page.configuration.preferenceIdentity else { throw IMessageSetupCoordinatorError.scopeChanged }
        }
        if let draft {
            guard draft.naturalUserID == scope.naturalUserID, draft.workspaceID == scope.workspaceID,
                  draft.environmentIdentity == page.configuration.preferenceIdentity else { throw IMessageSetupCoordinatorError.scopeChanged }
        }
    }

    private func saveDraft(_ page: Page, account: IMessageSetupAccount? = nil, selected: [IMessageGatewaySetupConversation] = []) throws {
        guard let journey = page.journey, let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let store = dependencies.store(page.configuration)
        let existing = try store.loadSetupDraft()
        if selected.isEmpty, existing?.setupReference == journey.setupReference { return }
        let selections = try selected.map { try IMessageSetupDraft.Selection(nativeChatRowID: $0.metadata.id.rawValue, expectedGUID: $0.metadata.guid) }
        var carriedAccount = account?.accountID, carriedSource = account?.sourceGeneration, carriedSelections = selections
        if let existing, existing.setupReference != journey.setupReference {
            guard existing.naturalUserID == scope.naturalUserID, existing.workspaceID == scope.workspaceID,
                  existing.environmentIdentity == page.configuration.preferenceIdentity else { throw IMessageSetupCoordinatorError.scopeChanged }
            if selected.isEmpty {
                carriedAccount = existing.expectedAccountID; carriedSource = existing.sourceGeneration; carriedSelections = existing.selectedConversations
            }
            guard try store.clearSetupDraft(matching: existing) else { throw IMessageSetupCoordinatorError.scopeChanged }
        }
        let draft = try IMessageSetupDraft(setupReference: journey.setupReference, naturalUserID: scope.naturalUserID, workspaceID: scope.workspaceID,
            environmentIdentity: page.configuration.preferenceIdentity, expiresAt: journey.expiresAt, expectedAccountID: carriedAccount,
            sourceGeneration: carriedSource, selectedConversations: carriedSelections)
        try store.saveSetupDraft(draft, now: dependencies.now())
    }
    private func saveSelectionDraft(_ page: Page, view: WKWebView, generation: UUID) async throws {
        guard let session = page.session, let intent = page.intent else { throw IMessageSetupCoordinatorError.scopeChanged }
        if page.selectedIDs.isEmpty {
            page.selectedDisplay = []
            guard let draft = try dependencies.store(page.configuration).loadSetupDraft() else { return }
            _ = try dependencies.store(page.configuration).clearSetupDraft(matching: draft)
            try saveDraft(page); return
        }
        let retained = try await session.runtime.retainedSelection(for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        page.selectedDisplay = Self.selectedProjection(retained.conversations)
        try saveDraft(page, account: retained.account, selected: retained.conversations)
    }
    private func scheduleWithdrawal(_ page: Page) {
        let session = page.session, intent = page.intent, receipt = page.relayReceipt
        page.session = nil; page.intent = nil; page.relayReceipt = nil; page.selectedIDs = []; page.page = nil
        page.selectedDisplay = []; page.verificationReady = false
        let previous = cleanup, id = UUID(), release = dependencies.releaseRelay
        cleanupID = id
        cleanup = Task {
            await previous?.value
            if let intent { await session?.runtime.withdrawLocalSetupAndDrain(intent) }
            else { await session?.provider.stop() }
            if let intent, let receipt { await release(intent, receipt) }
            if cleanupID == id { cleanupID = nil }
        }
    }
    private func withdraw(_ page: Page) async { scheduleWithdrawal(page); await cleanup?.value }

    private func projection(_ page: Page) -> [String: Any] {
        var result: [String: Any] = ["version": "1", "scope": page.scopeToken, "state": page.phase.rawValue,
            "selected_conversation_ids": page.selectedIDs, "selected_conversations": page.selectedDisplay,
            "verification_ready": page.verificationReady, "selected_count": page.selectedIDs.count, "next_action": page.nextAction,
            "permissions_ready": page.permissionsReady, "background_ready": page.backgroundReady, "restart_available": page.restartAvailable]
        if let display = page.display { result["workspace_name"] = display.workspaceName }
        if let reference = page.reference { result["setup_reference"] = reference }
        if let configID = page.configID { result["integration_config_id"] = configID }
        if let reason = page.reason { result["reason_code"] = reason }
        if let page = page.page {
            var projected: [String: Any] = ["snapshot_token": page.snapshotToken, "has_more": page.hasMore, "stop_reason": page.stopReason.rawValue,
                "conversations": page.conversations.map { ["conversation_id": $0.conversationID, "label": $0.label, "is_group": $0.isGroup,
                    "participant_count": $0.participantCount, "available": $0.available] as [String: Any] }]
            projected["next_page_token"] = page.nextPageToken
            result["conversations_page"] = projected
        }
        return result
    }
    private static func selectedProjection(_ rows: [IMessageGatewaySetupConversation]) -> [[String: Any]] {
        rows.map { row in
            let text = row.metadata.name.isEmpty ? row.metadata.participants.joined(separator: ", ") : row.metadata.name
            var label = ""
            for scalar in text.unicodeScalars where scalar.properties.generalCategory != .control {
                guard label.utf8.count + String(scalar).utf8.count <= 256 else { break }
                label.unicodeScalars.append(scalar)
            }
            return ["conversation_id": row.conversationID, "label": label, "available": row.metadata.available]
        }
    }
    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func credentialDigest(_ proof: String) throws -> String {
        let standard = proof.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)), data.count == 32 else {
            throw IMessageSetupCoordinatorError.invalidRequest
        }
        return Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func safeReason(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let hosted = error as? IMessageHostedSetupError {
            return hosted == .authenticationRequired ? "authentication_required" : (hosted == .scopeChanged ? "switch_workspace_or_account" : "setup_unavailable")
        }
        if let provider = error as? IMessageSetupProviderError { return provider == .permissionRequired ? "permission_required" : "setup_unavailable" }
        if let machine = error as? IMessageMachineSetupError, [.scopeChanged, .rejected].contains(machine) { return "switch_workspace_or_account" }
        if let local = error as? IMessageSetupCoordinatorError {
            switch local {
            case .invalidRequest: return "invalid_request"
            case .scopeChanged: return "switch_workspace_or_account"
            case .busy: return "busy"
            case .permissionRequired: return "permission_required"
            case .backgroundRequired: return "background_approval_required"
            case .unsupported: return "unsupported"
            case .unavailable: return "setup_unavailable"
            }
        }
        return "setup_unavailable"
    }
    private static func lifetimeReason(_ error: IMessageSetupLifetimeError) -> String {
        switch error {
        case .applicationsRequired: "applications_required"
        case .signatureRequired: "signature_required"
        case .backgroundApprovalRequired: "background_approval_required"
        }
    }
    private static func permissionAction(_ state: IMessageSetupPermissionState) -> String {
        switch state {
        case .ready: "enable_background"
        case .messagesNotRunning: "open_messages"
        case .fullDiskAccessRequired: "open_full_disk_access"
        case .automationRequired: "request_messages_access"
        case .sourceChanged, .unavailable: "check_permissions"
        }
    }
    private static func revokesLocalAuthority(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let hosted = error as? IMessageHostedSetupError { return [.authenticationRequired, .scopeChanged].contains(hosted) }
        if let local = error as? IMessageSetupCoordinatorError { return local == .scopeChanged }
        if let provider = error as? IMessageSetupProviderError { return provider == .accountChanged }
        if let machine = error as? IMessageMachineSetupError { return [.scopeChanged, .rejected].contains(machine) }
        return false
    }
    private static func readCookies(_ view: WKWebView, configuration: DesktopEnvironmentConfiguration) async throws -> String {
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        return try cookieHeader(cookies, configuration: configuration, now: Date())
    }
    static func cookieHeader(_ all: [HTTPCookie], configuration: DesktopEnvironmentConfiguration, now: Date) throws -> String {
        let host = configuration.appURL.host?.lowercased() ?? ""
        let cookies = all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let sameHost = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            return sameHost && (!cookie.isSecure || configuration.appURL.scheme == "https") && cookie.expiresDate.map({ $0 > now }) != false
        }.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
        guard !cookies.isEmpty else { throw IMessageHostedSetupError.authenticationRequired }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
    }
    private static func readCSRF(_ view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript("document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') || ''")
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512, !value.contains(where: \.isWhitespace) else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        return value
    }
    private func presentReview(_ review: Review, window: NSWindow?, page: Page) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Connect iMessage?"
        let names = review.conversations.map { $0.metadata.name.isEmpty ? $0.metadata.participants.joined(separator: ", ") : $0.metadata.name }
        alert.informativeText = "Workspace: \(review.workspaceName)\nMac: \(review.macName)\nMessages account: \(review.accountLabel)\n\nSelected conversations:\n" + names.joined(separator: "\n") +
            "\n\nSelected messages can go to assigned personas and their AI providers. Sends use this Messages account. Reading and sending are enabled. Persona assignments are saved separately."
        alert.addButton(withTitle: "Connect iMessage"); alert.addButton(withTitle: "Cancel")
        return await presentAlert(alert, window: window, page: page)
    }
    private func presentMetadataConsent(window: NSWindow?, page: Page) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Choose iMessage conversations?"
        alert.informativeText = "PersonaStack can read conversation names and participants to show the picker. Message text is not read during this step."
        alert.addButton(withTitle: "Choose Conversations"); alert.addButton(withTitle: "Cancel")
        return await presentAlert(alert, window: window, page: page)
    }
    private func presentAlert(_ alert: NSAlert, window: NSWindow?, page: Page) async -> Bool {
        guard let window, NSApp.isActive else { return false }
        page.nativeAlert = alert
        defer { page.nativeAlert = nil }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) }
        }
    }
}
