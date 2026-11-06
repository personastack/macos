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
    var lifetimeAdmitsOperations: () -> Bool = { true }

    struct Review: Equatable {
        let workspaceName: String
        let macName: String
        let accountLabel: String
        let conversations: [IMessageGatewaySetupConversation]
        var readEnabled = true
        var sendEnabled = true
        var capabilitiesEditable = true
    }
    struct ReviewDecision: Equatable, Sendable {
        let readEnabled: Bool
        let sendEnabled: Bool
    }
    struct HumanChoice: Equatable, Sendable {
        let conversationID: String?
        let text: String?
    }
    @MainActor struct Dependencies {
        var configuration: @MainActor (URL) throws -> DesktopEnvironmentConfiguration = { try DesktopEnvironmentConfigurationStore.shared.environment(for: $0) }
        var currentConfiguration: @MainActor () throws -> DesktopEnvironmentConfiguration = { try LaunchConfiguration.selectedEnvironment() }
        var admitsOperations: @MainActor () -> Bool = { DesktopUpdater.shared.admitsNativeIMessageOperations }
        var nativeRegistration: @MainActor () -> Bool? = { DesktopControlRuntime.shared.currentIMessageRegistration }
        var configuredMenuAvailability: @MainActor () -> IMessageMenuState = { DesktopControlRuntime.shared.configuredIMessageMenuAvailability }
        var pageURL: @MainActor (WKWebView) -> URL? = { $0.url }
        var cookies: @MainActor (WKWebView, DesktopEnvironmentConfiguration) async throws -> String = IMessageSetupManager.readCookies
        var csrf: @MainActor (WKWebView) async throws -> String = IMessageSetupManager.readCSRF
        var store: @MainActor (DesktopEnvironmentConfiguration) -> FileDesktopControlCredentialStore = { config in .init(configurationProvider: { config }) }
        var session: @MainActor () async throws -> IMessageNativeSession = { try await DesktopControlRuntime.shared.iMessageSetupSession() }
        var retainRelay: @MainActor (IMessageRuntimeSetupIntent) async throws -> UUID = { try await DesktopControlRuntime.shared.resumeIMessageSetupRelay(for: $0) }
        var releaseRelay: @MainActor (IMessageRuntimeSetupIntent, UUID) async -> Void = { await DesktopControlRuntime.shared.finishIMessageSetupRelay(for: $0, generation: $1) }
        var permissionState: @MainActor (IMessageNativeSession, Date) async throws -> IMessageSetupPermissionState = { try await $0.provider.setupPermissionState(deadline: $1) }
        var messagesAccess: @MainActor (IMessageNativeSession, Date) async throws -> Void = { try await $0.provider.requestMessagesAccess(deadline: $1) }
        var retryProvider: @MainActor (IMessageNativeSession) async throws -> Void = { try await $0.provider.retryAfterExplicitUserAction() }
        var accountLabel: @MainActor (IMessageNativeSession, IMessageSetupAccount) async throws -> String = { try await $0.provider.displayAccount(for: $1) }
        var evidence: @MainActor (IMessageNativeSession, IMessageSetupFinalConsent, @escaping @Sendable (IMessageSetupFinalConsent) async throws -> Bool) async throws -> IMessageSetupApprovalEvidence = {
            try await $0.provider.approvalEvidence(for: $1, deadline: $1.deadline, validateCurrent: $2)
        }
        var prepareBackground: @MainActor (DesktopEnvironmentConfiguration) async throws -> Void = { try await IMessageSetupLifetime.prepareBackgroundConnection(configuration: $0) }
        var backgroundReady: @MainActor () -> Bool = { IMessageSetupLifetime.backgroundReady }
        var restart: @MainActor (DesktopEnvironmentConfiguration) throws -> Void = { try DesktopApplicationRestart.requestIMessageSetupResume(configuration: $0) }
        var showReview: (@MainActor (Review, NSWindow?) async -> ReviewDecision?)?
        var showHumanReview: (@MainActor (IMessageSavedReadback, IMessageSavedPageCommand.Action, NSWindow?) async -> HumanChoice?)?
        var refreshRelayPolicy: @MainActor () async -> Void = { await DesktopControlRuntime.shared.refreshIMessageRelayPreference() }
        var captureHumanContext: @MainActor () async throws -> IMessageHumanActionContext = { try await DesktopControlRuntime.shared.captureIMessageHumanContext() }
        var validateHumanContext: @MainActor (IMessageHumanActionContext) throws -> Void = { try DesktopControlRuntime.shared.validateIMessageHumanContext($0) }
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
        var savedIntention: IMessageSetupDraft.SavedIntention?
        var savedAction: IMessageSavedPageCommand.Action? { savedIntention?.action }
        var savedConfig: IMessageSavedReadback?
        var savedMutationAttempted = false
        var requiresFreshSelection = false
        var sourceReplacementBlocked = false
        var gapChoices: [(savedID: String, selection: IMessageSetupDraft.Selection, optionID: String)] = []
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
    private let saved: IMessageSavedConfigClient
    private let dependencies: Dependencies
    private var pendingHandoff: IMessageSetupHandoff?
    private var pendingSavedHandoff: IMessageSavedHandoff?
    private var pendingMenuAction: IMessageSavedPageCommand.Action?
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var cleanup: Task<Void, Never>?
    private var cleanupID: UUID?
    private var automaticRecoveryEnabled = true
    private var pauseSyncGeneration: UUID?
    private var configuredObservationID: UUID?
    private var configuredObservationRequested = false

    init(hosted: IMessageHostedSetupClient = .init(), machine: IMessageMachineSetupClient = .init(),
         saved: IMessageSavedConfigClient = .init(), dependencies: Dependencies = .init()) {
        self.hosted = hosted; self.machine = machine; self.saved = saved; self.dependencies = dependencies
        super.init()
        if let configuration = try? dependencies.currentConfiguration(), dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)) {
            if dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration)) {
                let key = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: configuration.preferenceIdentity)
                menuState = dependencies.preferences.bool(forKey: key) ? .paused : .syncPending
            } else { menuState = dependencies.configuredMenuAvailability() }
        }
    }
    var hasPendingShutdown: Bool {
        cleanupID != nil || !operations.isEmpty || currentPages.contains(where: { $0.busy || $0.intent != nil || $0.session != nil })
    }
    private var currentPages: [Page] { pages.objectEnumerator()?.allObjects as? [Page] ?? [] }
    var canPauseMessages: Bool {
        guard let configuration = try? dependencies.currentConfiguration() else { return false }
        return dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)) &&
            !dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration))
    }

    func register(_ view: WKWebView, appURL: URL) {
        guard let configuration = try? dependencies.configuration(appURL) else { return }
        let page = Page(configuration)
        page.reference = pendingHandoff?.setupReference
        pages.setObject(page, forKey: view)
    }
    func receive(_ handoff: IMessageSetupHandoff) {
        pendingSavedHandoff = nil; pendingMenuAction = nil
        pendingHandoff = handoff
        openSetup()
    }
    func receive(_ handoff: IMessageSavedHandoff) {
        pendingHandoff = nil; pendingMenuAction = nil
        pendingSavedHandoff = handoff
        openSetup()
    }
    func openSetup() {
        guard let configuration = try? dependencies.currentConfiguration() else { return }
        var url = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        url.path = "/user/imessage"; url.fragment = nil
        if let saved = pendingSavedHandoff { url.percentEncodedQuery = "config_id=" + IMessageSavedHandoff.queryEscape(saved.configID) }
        else { url.queryItems = pendingHandoff.map { [URLQueryItem(name: "setup_reference", value: $0.setupReference)] } }
        if let navigateMainWindow { navigateMainWindow(url.url!) }
        else { dependencies.navigate(url.url!) }
    }
    func reviewConnection() {
        pendingMenuAction = nil; pendingHandoff = nil
        restoreSavedLocator()
        openSetup()
    }
    func invalidate(_ view: WKWebView) {
        guard let page = pages.object(forKey: view) else { return }
        page.generation = UUID(); page.scopeToken = UUID().uuidString.lowercased()
        page.cookiesFingerprint = nil; page.scope = nil; page.display = nil
        page.configID = page.savedIntention?.configID; page.reason = nil; page.phase = page.reference == nil ? .idle : .continueSetup
        // Cancellation revokes authority, not the immutable saved target.
        if page.savedIntention == nil { page.savedMutationAttempted = false }
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
    func documentCommitted(_ view: WKWebView) {
        pages.object(forKey: view)?.documentReady = true
        recoverPendingPause(view)
    }
    func invalidateSession() {
        for view in pages.keyEnumerator().allObjects as? [WKWebView] ?? [] { invalidate(view) }
    }
    func shutdown() async {
        automaticRecoveryEnabled = false
        for task in operations.values { task.cancel() }
        invalidateSession()
        for task in Array(operations.values) { await task.value }
        await cleanup?.value
    }
    func pause() async {
        guard canPauseMessages, let configuration = try? dependencies.currentConfiguration(),
              let intention = beginLocalPause(configuration: configuration) else { return }
        let configID = intention.configID ?? dependencies.preferences.string(forKey: savedLocatorKey(configuration))
        guard menuPauseIsCurrent(intention, configuration: configuration) else { return }
        await dependencies.refreshRelayPolicy()
        guard menuPauseIsCurrent(intention, configuration: configuration) else { return }
        await shutdown()
        guard menuPauseIsCurrent(intention, configuration: configuration) else { return }
        menuState = .syncPending
        guard dependencies.admitsOperations(), lifetimeAdmitsOperations() else { return }
        automaticRecoveryEnabled = true
        let id = UUID()
        let task = Task { await self.synchronizeMenuPause(configuration: configuration, intention: intention, configID: configID) }
        operations[id] = task
        defer { operations.removeValue(forKey: id) }
        await task.value
    }
    func resume() async {
        if let configuration = try? dependencies.currentConfiguration() { supersedeLocalPause(configuration) }
        pendingMenuAction = .resume
        restoreSavedLocator()
        menuState = .resumePending; openSetup()
    }
    func recheckAfterActivation(_ view: WKWebView) {
        recoverPendingPause(view)
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
              ChatWindowManager.trusted(message, base: page.configuration.appURL) else {
            replyHandler(nil, "invalid_request"); return
        }
        if let command = try? IMessageSavedPageCommand.parse(message.body) {
            enqueue(page) {
                do { replyHandler(try await self.apply(command, view: view), nil) }
                catch { replyHandler(nil, Self.safeReason(error)) }
            }
            return
        }
        guard let command = try? IMessageSetupPageCommand.parse(message.body) else { replyHandler(nil, "invalid_request"); return }
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
        guard dependencies.admitsOperations(), lifetimeAdmitsOperations() else { throw IMessageSetupCoordinatorError.unavailable }
        automaticRecoveryEnabled = true
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
            page.savedIntention = nil; page.savedConfig = nil; page.savedMutationAttempted = false
            page.requiresFreshSelection = false; page.sourceReplacementBlocked = false
            guard let handoff = command.handoff else { throw IMessageSetupCoordinatorError.invalidRequest }
            await withdraw(page); try current(page, generation: generation)
            page.reference = handoff.setupReference; page.journey = nil; page.configID = nil; page.journeyUnavailable = false
            page.resetReceipt = nil; page.ticket = nil; page.mode = nil
            page.permissionsReady = false; page.backgroundReady = false; page.restartAvailable = false
            pendingHandoff = handoff
            try await restoreSavedDraftConfig(page, view: view, generation: generation, cookies: cookies)
            try await resolveJourney(page, view: view, generation: generation, cookies: cookies)
        case .state: try await readPageState(command, page: page, view: view, generation: generation, cookies: cookies)
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

    private func readPageState(_ command: IMessageSetupPageCommand, page: Page, view: WKWebView,
                               generation: UUID, cookies: String) async throws {
        await dependencies.refreshRelayPolicy()
        try await requireCurrent(page, view: view, generation: generation)
        if dependencies.nativeRegistration() == false {
            supersedeLocalPause(page.configuration)
            dependencies.preferences.removeObject(forKey: savedLocatorKey(page.configuration))
            dependencies.preferences.removeObject(forKey: savedOwnerKey(page.configuration))
            dependencies.preferences.removeObject(forKey: pauseAckKey(page.configuration))
            menuState = .setupRequired
        }
        try? await synchronizePendingPause(page, view: view, generation: generation, cookies: cookies)
        try await requireCurrent(page, view: view, generation: generation)
        if isInitialEntry(view) { pendingMenuAction = nil; pendingSavedHandoff = nil }
        if pendingMenuAction != nil, pendingSavedHandoff != nil {
            try await beginPendingMenuAction(page, view: view, generation: generation, cookies: cookies)
            return
        }
        let hasSavedDraft = try dependencies.store(page.configuration).loadSetupDraft()?.savedIntention != nil
        if command.scope.isEmpty, isInitialEntry(view), page.savedAction != nil || hasSavedDraft {
            await withdraw(page); try current(page, generation: generation)
            page.reference = nil; page.journey = nil; page.configID = nil
            page.savedIntention = nil; page.savedConfig = nil; page.savedMutationAttempted = false
            page.requiresFreshSelection = false; page.sourceReplacementBlocked = false
            pendingHandoff = nil; pendingSavedHandoff = nil
            page.phase = .idle; page.nextAction = "start_again"; page.reason = nil
            return
        }
        if command.scope.isEmpty, isSavedLocatorEntry(view) {
            await withdraw(page); try current(page, generation: generation)
            page.reference = nil; page.journey = nil; page.configID = nil; page.savedIntention = nil; page.savedConfig = nil; page.savedMutationAttempted = false
            page.requiresFreshSelection = false; page.sourceReplacementBlocked = false
            page.phase = .idle; page.nextAction = "start_again"; page.reason = nil
            return
        }
        if page.reference == nil { try restoreReference(page) }
        try await restoreSavedDraftConfig(page, view: view, generation: generation, cookies: cookies)
        if page.reference != nil { try await resolveJourney(page, view: view, generation: generation, cookies: cookies) }
        else { page.phase = .idle; page.nextAction = "start_again"; page.reason = nil }
    }

    private func authorize(_ page: Page, view: WKWebView, generation: UUID,
                           validateIntention: (@MainActor @Sendable () throws -> Void)? = nil) async throws -> String {
        try validateIntention?()
        let retainedScope = page.scope
        let retainedSession = page.display?.sessionFingerprint
        let cookies = try await dependencies.cookies(view, page.configuration)
        try current(page, generation: generation)
        let fingerprint = Data(SHA256.hash(data: Data(cookies.utf8)))
        let validateCandidate: IMessageHostedSetupClient.ValidateScope = {
            try self.current(page, generation: generation)
            try validateIntention?()
            let currentCookies = try await self.dependencies.cookies(view, page.configuration)
            try self.current(page, generation: generation)
            guard fingerprint == Data(SHA256.hash(data: Data(currentCookies.utf8))) else {
                throw IMessageSetupCoordinatorError.scopeChanged
            }
            try validateIntention?()
        }
        let scope = try await hosted.nativeScope(configuration: page.configuration, cookies: cookies,
            validateScope: validateCandidate)
        guard retainedScope == nil || retainedScope == scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let display = try await hosted.displayContext(configuration: page.configuration, cookies: cookies,
            expectedScope: scope, validateScope: validateCandidate)
        try await validateCandidate()
        guard page.scope == retainedScope, page.display?.sessionFingerprint == retainedSession,
              retainedSession == nil || retainedSession == display.sessionFingerprint else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        page.cookiesFingerprint = fingerprint
        page.scope = scope
        page.display = display
        return cookies
    }

    private func current(_ page: Page, generation: UUID) throws {
        try Task.checkCancellation()
        guard dependencies.admitsOperations(), lifetimeAdmitsOperations(), !page.retired, page.generation == generation,
              try dependencies.currentConfiguration() == page.configuration else {
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
        try await restoreSavedDraftConfig(page, view: view, generation: generation, cookies: cookies)
        try await resolveJourney(page, view: view, generation: generation, cookies: cookies)
        guard !page.journeyUnavailable else { return }
        guard page.configID == nil || page.savedAction != nil, let journey = page.journey, let scope = page.scope else { return }
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
        case .requestMessagesAccess, .checkPermissions, .retryProvider:
            guard let session = page.session else { throw IMessageSetupCoordinatorError.invalidRequest }
            let deadline = dependencies.now().addingTimeInterval(10)
            if action == .retryProvider {
                await session.runtime.suspendAndDrain()
                await withdraw(page)
                try await requireCurrent(page, view: view, generation: generation)
                try await dependencies.retryProvider(session)
                try await requireCurrent(page, view: view, generation: generation)
                page.session = session
                page.selectedIDs = []; page.selectedDisplay = []; page.verificationReady = false
            }
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
        guard !page.sourceReplacementBlocked else { throw IMessageSetupCoordinatorError.invalidRequest }
        guard page.permissionsReady else { throw IMessageSetupCoordinatorError.permissionRequired }
        guard page.backgroundReady, dependencies.backgroundReady() else { throw IMessageSetupCoordinatorError.backgroundRequired }
        guard let session = page.session, let scope = page.scope, let journey = page.journey else { throw IMessageSetupCoordinatorError.scopeChanged }
        let accepted: Bool
        if let showConsent = dependencies.showMetadataConsent { accepted = await showConsent(view.window) }
        else { accepted = await presentMetadataConsent(window: view.window, page: page) }
        try await requireCurrent(page, view: view, generation: generation)
        guard accepted else { return }
        let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: .init(setupReferenceSHA256: Self.digest(journey.setupReference),
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
        if page.requiresFreshSelection {
            // A new grant plus explicit native consent is required after the
            // old account/source intentions were retired. Never restore them.
            let cookies = try await dependencies.cookies(view, page.configuration)
            try await requireCurrent(page, view: view, generation: generation)
            _ = try await metadata(.prerequisites, page: page, view: view, generation: generation, cookies: cookies)
        } else { try await restoreSelection(page, view: view, generation: generation) }
        guard page.intent != nil else { return }
        page.phase = .selecting
        page.verificationReady = false; page.nextAction = "list"
    }
    private func restoreSelection(_ page: Page, view: WKWebView, generation: UUID) async throws {
        if page.savedConfig != nil {
            try await restoreSavedSelection(page, view: view, generation: generation)
            return
        }
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
        guard !page.sourceReplacementBlocked else { throw IMessageSetupCoordinatorError.invalidRequest }
        if page.savedAction == .resumeFromNow {
            guard command.query.isEmpty, command.pageToken == nil, command.snapshotToken == nil else { throw IMessageSetupCoordinatorError.invalidRequest }
            page.page = nil; page.phase = .selecting; page.nextAction = "verify"
            return
        }
        let response = try await metadata(.setupConversations(.init(query: command.query, snapshotToken: command.snapshotToken,
            pageToken: command.pageToken, limit: 50)), page: page, view: view, generation: generation, cookies: cookies)
        guard case .conversationsPage(let result)? = response.result else { throw IMessageSetupCoordinatorError.unavailable }
        page.page = result; page.phase = .selecting
        page.verificationReady = false
    }
    private func select(_ ids: [String], page: Page, view: WKWebView, generation: UUID) async throws {
        guard let session = page.session, let intent = page.intent else { throw IMessageSetupCoordinatorError.scopeChanged }
        let ordered: [String]
        if page.savedAction == .resumeFromNow {
            let allowed = page.gapChoices.map(\.optionID)
            guard ids.allSatisfy({ allowed.contains($0) }) else { throw IMessageSetupCoordinatorError.invalidRequest }
            ordered = allowed.filter { ids.contains($0) }
        } else { ordered = ids }
        try await session.runtime.setSelectedConversationIDs(ordered, for: intent)
        try await requireCurrent(page, view: view, generation: generation)
        page.selectedIDs = ordered
        page.verificationReady = false
        page.nextAction = ids.isEmpty ? "list" : "verify"
        try await saveSelectionDraft(page, view: view, generation: generation)
    }
    private func verify(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard !page.sourceReplacementBlocked else { throw IMessageSetupCoordinatorError.invalidRequest }
        if let session = page.session, let intent = page.intent {
            let retained = try await session.runtime.retainedSelection(for: intent)
            try await requireCurrent(page, view: view, generation: generation)
            if retained.conversations.contains(where: { !$0.metadata.available }) {
                page.reason = "selection_unavailable"; page.phase = .selecting; page.verificationReady = false
                return
            }
        }
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
        let review = Review(workspaceName: display.workspaceName, macName: dependencies.macName(), accountLabel: label,
            conversations: selection.conversations, readEnabled: page.savedConfig?.config.readEnabled ?? true,
            sendEnabled: page.savedConfig?.config.sendEnabled ?? true, capabilitiesEditable: page.savedAction != .resumeFromNow)
        let decision: ReviewDecision?
        if let showReview = dependencies.showReview { decision = await showReview(review, view.window) }
        else { decision = await presentReview(review, window: view.window, page: page) }
        guard let decision else { return nil }
        guard decision.readEnabled || decision.sendEnabled else { throw IMessageSetupCoordinatorError.invalidRequest }
        if !review.capabilitiesEditable {
            guard decision.readEnabled == review.readEnabled, decision.sendEnabled == review.sendEnabled else { throw IMessageSetupCoordinatorError.invalidRequest }
        }
        try await requireCurrent(page, view: view, generation: generation)
        let fresh = try await session.runtime.retainedSelection(for: intent)
        guard fresh.conversations == selection.conversations, fresh.account == selection.account, fresh.expiresAt == selection.expiresAt else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        let now = dependencies.now()
        let consent = try IMessageSetupFinalConsent(intent: intent, installationID: session.installation.installationID,
            environmentIdentity: page.configuration.preferenceIdentity, conversations: selection.conversations, account: selection.account,
            readEnabled: decision.readEnabled, sendEnabled: decision.sendEnabled, selectionAndCapabilitiesConfirmed: true,
            confirmedAt: now, deadline: now.addingTimeInterval(10))
        return (consent, review)
    }
    private func commit(_ consent: IMessageSetupFinalConsent, review: Review, page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        if page.savedMutationAttempted { throw IMessageSetupCoordinatorError.unavailable }
        guard let session = page.session, let scope = page.scope, let journey = page.journey,
              let ticket = page.ticket, let mode = page.mode else { throw IMessageSetupCoordinatorError.scopeChanged }
        try requireCommitMode(page, journey: journey)
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
        try requireCommitMode(page, journey: journey)
        if let savedConfig = page.savedConfig, let action = page.savedAction {
            page.savedMutationAttempted = true
            let result = try await saved.update(savedConfig, flow: action, receipt: receipt, consent: consent,
                configuration: page.configuration, cookies: cookies, csrf: csrf, scope: scope,
                resumeConversationIDs: try resumeIDs(consent, page: page)) { try await validate(consent) }
            try await validate(consent)
            applySavedPreferences(result, configuration: page.configuration, action: action)
            let store = dependencies.store(page.configuration)
            if let draft = try store.loadSetupDraft(), draft.setupReference == journey.setupReference {
                guard try store.clearSetupDraft(matching: draft) else { throw IMessageSetupCoordinatorError.scopeChanged }
            }
            page.configID = result.integrationConfigID; page.phase = .assignPersonas; page.nextAction = "assign_personas"
            await withdraw(page)
            await dependencies.refreshRelayPolicy()
            return
        }
        page.createAttempted = true
        guard page.savedIntention == nil else { throw IMessageSetupCoordinatorError.scopeChanged }
        try requireCommitMode(page, journey: journey)
        let configID = try await hosted.createConfiguration(receipt: receipt, consent: consent, configuration: page.configuration,
            cookies: cookies, csrf: csrf, expectedScope: scope, now: dependencies.now(), validateCurrent: validate)
        complete(configID, page: page, verifiedLocally: true)
        await withdraw(page)
        await dependencies.refreshRelayPolicy()
    }
    private func requireCommitMode(_ page: Page, journey: IMessageHostedJourney) throws {
        let draft = try dependencies.store(page.configuration).loadSetupDraft()
        let stored = draft?.setupReference == journey.setupReference ? draft?.savedIntention : nil
        guard let intended = page.savedIntention ?? stored else {
            guard page.savedConfig == nil else { throw IMessageSetupCoordinatorError.scopeChanged }
            return
        }
        guard stored == nil || stored == intended else { throw IMessageSetupCoordinatorError.scopeChanged }
        guard page.savedIntention == intended, let config = page.savedConfig, config.integrationConfigID == intended.configID,
              config.configVersion == intended.expectedConfigVersion, page.savedAction == intended.action else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
    }

    private func requireFinal(_ consent: IMessageSetupFinalConsent, page: Page, view: WKWebView, generation: UUID) async throws {
        try await requireCurrent(page, view: view, generation: generation)
        guard page.phase == .review, page.intent == consent.intent, consent.deadline > dependencies.now(),
              let session = page.session else { throw IMessageSetupCoordinatorError.scopeChanged }
        let retained = try await session.runtime.retainedSelection(for: consent.intent)
        guard retained.conversations == consent.conversations, retained.account == consent.account else { throw IMessageSetupCoordinatorError.scopeChanged }
    }
    private func complete(_ configID: String, page: Page, verifiedLocally: Bool) {
        rememberSavedLocator(configID, configuration: page.configuration, scope: page.scope)
        page.configID = configID; page.phase = .assignPersonas; page.createAttempted = false
        page.nextAction = "assign_personas"
        menuState = verifiedLocally ? .connected : .needsAttention
        if verifiedLocally {
            dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(page.configuration))
            dependencies.preferences.set(false, forKey: IMessagePreferenceKeys.relayPaused(page.configuration))
        }
    }
    private func startAgain(_ page: Page, view: WKWebView, generation: UUID, cookies: String, newSavedAction: Bool = false) async throws {
        // An explicit new saved action already has a current canonical target.
        // Continuations must restore the existing immutable journey intention.
        if !newSavedAction { try await restoreSavedDraftConfig(page, view: view, generation: generation, cookies: cookies) }
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
        if let savedConfig = page.savedConfig { page.configID = savedConfig.integrationConfigID }
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

    private func saveDraft(_ page: Page, account: IMessageSetupAccount? = nil, selected: [IMessageGatewaySetupConversation] = [],
                           selectedIntentions: [IMessageSetupDraft.Selection]? = nil) throws {
        guard let journey = page.journey, let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let store = dependencies.store(page.configuration)
        let existing = try store.loadSetupDraft()
        if existing?.setupReference == journey.setupReference, let stored = existing?.savedIntention, page.savedIntention != stored {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        if selected.isEmpty, existing?.setupReference == journey.setupReference { return }
        let selections = try selectedIntentions ?? selected.map { try IMessageSetupDraft.Selection(nativeChatRowID: $0.metadata.id.rawValue, expectedGUID: $0.metadata.guid) }
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
            sourceGeneration: carriedSource, selectedConversations: carriedSelections,
            savedIntention: page.savedIntention)
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
        try saveDraft(page, account: retained.account, selected: retained.conversations, selectedIntentions: retained.expectedSelections)
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
            // The session provider is shared with configured work. A page
            // without a setup intent does not own that provider's lifetime.
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
        if let action = page.savedAction, let config = page.savedConfig {
            result["flow"] = Self.savedFlow(action); result["expected_config_version"] = String(config.configVersion)
        }
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
            return ["conversation_id": row.conversationID, "label": boundedDisplayLabel(text), "available": row.metadata.available]
        }
    }
    private static func boundedDisplayLabel(_ value: String) -> String {
        var label = ""
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            guard label.utf8.count + String(scalar).utf8.count <= 256 else { break }
            label.unicodeScalars.append(scalar)
        }
        return label
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
        case .retryRequired: "retry_provider"
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
    private func presentReview(_ review: Review, window: NSWindow?, page: Page) async -> ReviewDecision? {
        let alert = NSAlert()
        alert.messageText = "Connect iMessage?"
        let names = review.conversations.map { $0.metadata.name.isEmpty ? $0.metadata.participants.joined(separator: ", ") : $0.metadata.name }
        alert.informativeText = "Workspace: \(review.workspaceName)\nMac: \(review.macName)\nMessages account: \(review.accountLabel)\n\nSelected conversations:\n" + names.joined(separator: "\n") +
            "\n\nSelected messages can go to assigned personas and their AI providers. Sends use this Messages account."
        alert.addButton(withTitle: "Connect iMessage"); alert.addButton(withTitle: "Cancel")
        let choices = IMessageReviewCapabilityControls(readEnabled: review.readEnabled, sendEnabled: review.sendEnabled,
            approvalButton: alert.buttons.first!)
        choices.read.isEnabled = review.capabilitiesEditable; choices.send.isEnabled = review.capabilitiesEditable
        alert.accessoryView = choices.view
        guard await presentAlert(alert, window: window, page: page) else { return nil }
        return .init(readEnabled: choices.read.state == .on, sendEnabled: choices.send.state == .on)
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

// Saved controls share the current document, setup coordinator and provider.
// Only these native intentions distinguish update/resume from initial create.
extension IMessageSetupManager {
    func apply(_ command: IMessageSavedPageCommand, view: WKWebView) async throws -> [String: Any] {
        guard dependencies.admitsOperations(), lifetimeAdmitsOperations() else { throw IMessageSetupCoordinatorError.unavailable }
        automaticRecoveryEnabled = true
        guard let page = pages.object(forKey: view), !page.retired, command.scope == page.scopeToken else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        guard !page.busy else { throw IMessageSetupCoordinatorError.busy }
        page.busy = true
        defer { page.busy = false }
        let generation = page.generation
        try current(page, generation: generation)
        let humanContext: IMessageHumanActionContext?
        if command.action == .check || command.action == .sendTest {
            do { humanContext = try await dependencies.captureHumanContext() }
            catch let error as IMessageHumanContextError { return humanNotStartedReply(command, reason: error, page: page) }
            try await requireCurrent(page, view: view, generation: generation)
        } else { humanContext = nil }
        if command.action == .resume || command.action == .resumeFromNow { supersedeLocalPause(page.configuration) }
        let originalPause = captureSavedPause(command, page: page)
        var currentPause = originalPause
        do {
            if let originalPause {
                try requireMenuPause(originalPause, configuration: page.configuration)
                try current(page, generation: generation)
                menuState = .syncPending
                await dependencies.refreshRelayPolicy()
                try await requireSavedPauseContext(originalPause, page: page, view: view, generation: generation)
            }
            let cookies = try await authorize(page, view: view, generation: generation) {
                if let originalPause { try self.requireMenuPause(originalPause, configuration: page.configuration) }
            }
            if let humanContext { try dependencies.validateHumanContext(humanContext) }
            guard let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
            let config = try await saved.read(command.configID, configuration: page.configuration, cookies: cookies, scope: scope) {
                try await self.requireSavedPauseContext(originalPause, page: page, view: view, generation: generation)
                if let humanContext { try self.dependencies.validateHumanContext(humanContext) }
            }
            try await requireSavedPauseContext(originalPause, page: page, view: view, generation: generation)
            guard config.configVersion == command.expectedConfigVersion else { throw IMessageSetupCoordinatorError.scopeChanged }
            currentPause = try resolveSavedPause(command, config: config, page: page, generation: generation, original: originalPause)
            return try await dispatchSaved(command, config: config, humanContext: humanContext, page: page, view: view,
                generation: generation, cookies: cookies, pauseIntention: currentPause)
        } catch {
            if command.action == .pause {
                guard page.generation == generation, !page.retired else { throw error }
                if let currentPause, !menuPauseIsCurrent(currentPause, configuration: page.configuration) { throw error }
            }
            if currentPause != nil, error as? IMessageHostedSetupError == .serviceUnavailable {
                var result = savedReply("control", configID: command.configID, page: page)
                result["state"] = "sync_pending"
                return result
            }
            if Self.revokesLocalAuthority(error) { invalidate(view) }
            throw error
        }
    }

    private func captureSavedPause(_ command: IMessageSavedPageCommand, page: Page) -> IMessageLocalPauseIntent? {
        guard command.action == .pause,
              dependencies.preferences.string(forKey: savedLocatorKey(page.configuration)) == command.configID else { return nil }
        return beginLocalPause(configuration: page.configuration)
    }
    private func requireSavedPauseContext(_ intention: IMessageLocalPauseIntent?, page: Page, view: WKWebView, generation: UUID) async throws {
        if let intention { try requireMenuPause(intention, configuration: page.configuration) }
        try await requireCurrent(page, view: view, generation: generation)
        if let intention { try requireMenuPause(intention, configuration: page.configuration) }
    }
    private func resolveSavedPause(_ command: IMessageSavedPageCommand, config: IMessageSavedReadback, page: Page,
                                   generation: UUID, original: IMessageLocalPauseIntent?) throws -> IMessageLocalPauseIntent? {
        try current(page, generation: generation)
        guard isLocalConfig(config, configuration: page.configuration) else {
            guard original == nil else { throw IMessageSetupCoordinatorError.scopeChanged }
            return nil
        }
        guard command.action == .pause else {
            rememberSavedLocator(config.integrationConfigID, configuration: page.configuration, scope: page.scope)
            return nil
        }
        guard let original else {
            // This read may teach the local locator for a later explicit retry.
            // It cannot create a Pause record after authorization has awaited.
            rememberSavedLocator(config.integrationConfigID, configuration: page.configuration, scope: page.scope)
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        guard let bound = bindMenuPauseOwner(original, config: config, page: page) else { throw IMessageSetupCoordinatorError.scopeChanged }
        return bound
    }

    private func dispatchSaved(_ command: IMessageSavedPageCommand, config: IMessageSavedReadback, humanContext: IMessageHumanActionContext?,
                               page: Page, view: WKWebView, generation: UUID, cookies: String,
                               pauseIntention: IMessageLocalPauseIntent?) async throws -> [String: Any] {
        switch command.action {
        case .pause: return try await pauseSaved(config, page: page, view: view, generation: generation, cookies: cookies, intention: pauseIntention)
        case .check, .sendTest:
            guard let humanContext else { throw IMessageSetupCoordinatorError.scopeChanged }
            return try await humanAction(command, config: config, context: humanContext, page: page, view: view, generation: generation, cookies: cookies)
        case .edit, .resume, .resumeFromNow, .repair:
            try await beginSavedFlow(command.action, config: config, page: page, view: view, generation: generation, cookies: cookies)
            return projection(page)
        }
    }

    private func beginSavedFlow(_ action: IMessageSavedPageCommand.Action, config: IMessageSavedReadback,
                                page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let installed = try dependencies.store(page.configuration).load(), installed.installationID == config.config.installationID else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        if action == .resumeFromNow {
            guard config.config.readEnabled, !config.config.status.continuityGapConversationIDs.isEmpty else { throw IMessageSetupCoordinatorError.invalidRequest }
        }
        // Starting another saved action does not reuse an issued receipt.
        await withdraw(page); try await requireCurrent(page, view: view, generation: generation)
        page.savedIntention = try .init(action: action, configID: config.integrationConfigID, expectedConfigVersion: config.configVersion)
        page.savedConfig = config
        page.requiresFreshSelection = false; page.sourceReplacementBlocked = false
        page.gapChoices = []
        page.savedMutationAttempted = false; page.configID = config.integrationConfigID
        try await startAgain(page, view: view, generation: generation, cookies: cookies, newSavedAction: true)
    }

    private func restoreSavedDraftConfig(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let draft = try dependencies.store(page.configuration).loadSetupDraft()
        let matching = draft?.setupReference == page.reference ? draft : nil
        if let matching {
            try matching.requireEnvironment(page.configuration.preferenceIdentity)
            guard matching.naturalUserID == scope.naturalUserID, matching.workspaceID == scope.workspaceID else { throw IMessageSetupCoordinatorError.scopeChanged }
            // A draft is a locator and intention. resolveJourney rejects its
            // expired authority; explicit Start Again may carry the intention.
        }
        guard let intention = page.savedIntention ?? matching?.savedIntention else { return }
        if let stored = matching?.savedIntention, stored != intention { throw IMessageSetupCoordinatorError.scopeChanged }
        let config = try await saved.read(intention.configID, configuration: page.configuration, cookies: cookies, scope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        guard config.configVersion == intention.expectedConfigVersion else { throw IMessageSetupCoordinatorError.scopeChanged }
        page.savedIntention = intention; page.savedConfig = config; page.configID = config.integrationConfigID
    }

    private func restoreSavedSelection(_ page: Page, view: WKWebView, generation: UUID) async throws {
        guard let config = page.savedConfig, let session = page.session, let intent = page.intent,
              let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        let cookies = try await dependencies.cookies(view, page.configuration)
        try await requireCurrent(page, view: view, generation: generation)
        let current = try await saved.read(config.integrationConfigID, configuration: page.configuration, cookies: cookies, scope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        guard current.configVersion == config.configVersion else { throw IMessageSetupCoordinatorError.scopeChanged }
        // The fresh API setup grant carries private restoration intentions. A
        // prerequisite operation installs it without reading message content.
        _ = try await metadata(.prerequisites, page: page, view: view, generation: generation, cookies: cookies)
        let intentions = try await session.runtime.restorationIntentions(for: intent, configID: config.integrationConfigID,
            expectedConfigVersion: config.configVersion)
        let selected = try restorationSubset(intentions, config: current, flow: page.savedAction)
        try await requireCurrent(page, view: view, generation: generation)
        do {
            let retained = try await session.runtime.restoreSelection(selected.map(\.selection), account: intentions.account,
                originalExpiresAt: min(try IMessageGatewayWire.utcDate(intent.scope.expiresAt), dependencies.now().addingTimeInterval(300)), for: intent)
            try await requireCurrent(page, view: view, generation: generation)
            page.selectedIDs = retained.conversations.map(\.conversationID)
            if page.savedAction == .resumeFromNow {
                page.gapChoices = zip(selected, retained.conversations).map { (savedID: $0.0.savedID, selection: $0.0.selection, optionID: $0.1.conversationID) }
            }
            page.selectedDisplay = Self.selectedProjection(retained.conversations)
            try await saveSelectionDraft(page, view: view, generation: generation)
            for (index, row) in retained.conversations.enumerated() where !row.metadata.available {
                let id = selected[index].savedID
                if let old = config.config.conversations.first(where: { $0.conversationID == id }) {
                    // Last-known label is visual context only. Current native
                    // metadata stays canonical unavailable and contains no GUID.
                    page.selectedDisplay[index]["label"] = Self.boundedDisplayLabel(old.label)
                }
            }
        } catch IMessageSetupProviderError.accountChanged {
            await withdraw(page)
            try await requireCurrent(page, view: view, generation: generation)
            page.session = session
            page.requiresFreshSelection = true
            page.sourceReplacementBlocked = page.savedAction == .resumeFromNow
            try retireSourceIntentions(page)
            page.phase = .needsAttention; page.reason = "selection_unavailable"
            page.nextAction = page.sourceReplacementBlocked ? "start_again" : "allow_metadata"
        }
    }

    private func retireSourceIntentions(_ page: Page) throws {
        guard let reference = page.reference, let intention = page.savedIntention else { throw IMessageSetupCoordinatorError.scopeChanged }
        let store = dependencies.store(page.configuration)
        guard let draft = try store.loadSetupDraft(), draft.setupReference == reference, draft.savedIntention == intention else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        let replacement = try IMessageSetupDraft(setupReference: draft.setupReference, naturalUserID: draft.naturalUserID, workspaceID: draft.workspaceID,
            environmentIdentity: draft.environmentIdentity, expiresAt: draft.expiresAt, savedIntention: intention)
        try store.saveSetupDraft(replacement, now: dependencies.now())
    }

    private func restorationSubset(_ intentions: IMessageRuntimeRestorationIntentions, config: IMessageSavedReadback,
                                   flow: IMessageSavedPageCommand.Action?) throws -> [(savedID: String, selection: IMessageSetupDraft.Selection)] {
        guard intentions.selections.count == intentions.conversationIDs.count else { throw IMessageSetupCoordinatorError.scopeChanged }
        let rows = zip(intentions.conversationIDs, intentions.selections).map { (savedID: $0.0, selection: $0.1) }
        guard flow == .resumeFromNow else { return rows }
        let affected = config.config.status.continuityGapConversationIDs
        guard config.config.readEnabled, !affected.isEmpty else { throw IMessageSetupCoordinatorError.invalidRequest }
        let selected = rows.filter { affected.contains($0.savedID) }
        guard selected.map(\.savedID) == affected else { throw IMessageSetupCoordinatorError.scopeChanged }
        return selected
    }

    private func resumeIDs(_ consent: IMessageSetupFinalConsent, page: Page) throws -> [String] {
        guard page.savedAction == .resumeFromNow else { return [] }
        guard !consent.conversations.isEmpty else { throw IMessageSetupCoordinatorError.invalidRequest }
        var ids: [String] = []
        for row in consent.conversations {
            guard row.metadata.available, let choice = page.gapChoices.first(where: { $0.optionID == row.conversationID }),
                  row.metadata.id.rawValue == choice.selection.nativeChatRowID, row.metadata.guid == choice.selection.expectedGUID else {
                throw IMessageSetupCoordinatorError.scopeChanged
            }
            ids.append(choice.savedID)
        }
        guard page.gapChoices.map(\.savedID).filter({ ids.contains($0) }) == ids else { throw IMessageSetupCoordinatorError.scopeChanged }
        return ids
    }

    private func humanAction(_ command: IMessageSavedPageCommand, config: IMessageSavedReadback, context: IMessageHumanActionContext,
                             page: Page, view: WKWebView, generation: UUID, cookies: String) async throws -> [String: Any] {
        guard let scope = page.scope, isLocalConfig(config, configuration: page.configuration) else { throw IMessageSetupCoordinatorError.scopeChanged }
        try dependencies.validateHumanContext(context)
        let choice: HumanChoice?
        if let review = dependencies.showHumanReview { choice = await review(config, command.action, view.window) }
        else { choice = await presentHumanReview(config, action: command.action, window: view.window, page: page) }
        try await requireHumanCurrent(context, page: page, view: view, generation: generation)
        guard let choice else {
            var result = savedReply("cancelled_before_prepare", configID: config.integrationConfigID, page: page)
            result["client_request_id"] = command.clientRequestID
            return result
        }
        let action: IMessageGatewayHumanAction = command.action == .check ? .check : .testSend
        let input = IMessageHumanActionRequest(expectedConfigVersion: config.configVersion, action: action,
            conversationID: choice.conversationID, clientRequestID: command.clientRequestID, text: choice.text)
        try validateHumanChoice(input, config: config)
        let deadline = dependencies.now().addingTimeInterval(action == .check ? 10 : 45)
        let csrf = try await dependencies.csrf(view)
        do {
        let prepared = try await saved.prepare(input, saved: config, configuration: page.configuration,
            cookies: cookies, csrf: csrf, scope: scope, deadline: deadline) {
                try await self.requireHumanCurrent(context, page: page, view: view, generation: generation)
            }
        let outcome: IMessageHumanActionResponse
        if let issued = prepared.command {
            outcome = try await redeemHuman(issued, input: input, config: config, context: context, page: page, view: view,
                generation: generation, scope: scope, deadline: deadline)
        } else { outcome = prepared }
        try await requireHumanCurrent(context, page: page, view: view, generation: generation)
        return humanReply(outcome, input: input, configID: config.integrationConfigID, page: page)
        } catch {
            // Preparation may have committed even when its response is lost.
            // The page retains this exact opaque key for human status lookup.
            try current(page, generation: generation)
            var result = savedReply(action == .check ? "check" : "send", configID: config.integrationConfigID, page: page)
            if action == .check {
                result["expected_config_version"] = String(config.configVersion); result["state"] = "not_passed"
            } else {
                result["client_request_id"] = input.clientRequestID; result["state"] = "outcome_unknown"
            }
            result["reason_code"] = "status_unavailable"
            return result
        }
    }

    private func redeemHuman(_ command: IMessageGatewayCommand, input: IMessageHumanActionRequest, config: IMessageSavedReadback,
                             context: IMessageHumanActionContext, page: Page, view: WKWebView, generation: UUID, scope: IMessageHostedNativeScope,
                             deadline: Date) async throws -> IMessageHumanActionResponse {
        let session = context.session
        try await requireHumanCurrent(context, page: page, view: view, generation: generation)
        guard session.configuration == page.configuration, session.installation.installationID == config.config.installationID else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
        let localGeneration = UUID()
        let expiry = min(deadline, try IMessageGatewayWire.utcDate(command.deadlineAt))
        try await session.runtime.registerHumanAction(command, localGeneration: localGeneration, confirmed: true, deadline: expiry)
        do {
            try await requireHumanCurrent(context, page: page, view: view, generation: generation)
            let result = try await saved.redeem(command, input: input, saved: config, installation: session.installation,
                configuration: page.configuration, scope: scope, deadline: expiry) {
                    try await self.requireHumanCurrent(context, page: page, view: view, generation: generation)
                }
            await session.runtime.withdrawHumanActions(localGeneration: localGeneration)
            return result
        } catch {
            await session.runtime.withdrawHumanActions(localGeneration: localGeneration)
            throw error
        }
    }

    private func requireHumanCurrent(_ context: IMessageHumanActionContext, page: Page, view: WKWebView, generation: UUID) async throws {
        try dependencies.validateHumanContext(context)
        try await requireCurrent(page, view: view, generation: generation)
        try dependencies.validateHumanContext(context)
    }
    private func humanNotStartedReply(_ command: IMessageSavedPageCommand, reason: IMessageHumanContextError, page: Page) -> [String: Any] {
        var reply = savedReply(command.action == .check ? "check" : "send", configID: command.configID, page: page)
        let code: IMessageGatewayFailureCode
        switch reason { case .paused: code = .macPaused; case .disabled: code = .capabilityDisabled; case .offline: code = .macOffline; case .changed: code = .scopeDenied }
        reply["reason_code"] = code.rawValue
        if command.action == .check {
            reply["state"] = "not_passed"; reply["expected_config_version"] = String(command.expectedConfigVersion)
        } else { reply["state"] = "not_sent"; reply["client_request_id"] = command.clientRequestID }
        return reply
    }
    private func validateHumanChoice(_ input: IMessageHumanActionRequest, config: IMessageSavedReadback) throws {
        if input.action == .check {
            guard input.conversationID == nil, input.text == nil, input.clientRequestID == nil else { throw IMessageSetupCoordinatorError.invalidRequest }
            return
        }
        guard let id = input.conversationID, config.config.conversations.contains(where: { $0.conversationID == id && $0.available }),
              let text = input.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384,
              let key = input.clientRequestID, !key.isEmpty, key.unicodeScalars.count <= 128 else { throw IMessageSetupCoordinatorError.invalidRequest }
    }

    private func humanReply(_ outcome: IMessageHumanActionResponse, input: IMessageHumanActionRequest,
                            configID: String, page: Page) -> [String: Any] {
        var result = savedReply(input.action == .check ? "check" : "send", configID: configID, page: page)
        if input.action == .check {
            result["expected_config_version"] = String(input.expectedConfigVersion)
            result["state"] = outcome.status == nil ? "not_passed" : "passed"
        } else {
            result["client_request_id"] = input.clientRequestID
            if outcome.sendMessage != nil { result["state"] = "local_record_confirmed" }
            else if let failure = outcome.failure {
                switch failure.code {
                case .requestInProgress: result["state"] = "dispatching"
                case .statusUnavailable: result["state"] = "status_unavailable"
                default: result["state"] = failure.retrySafe ? "not_sent" : "outcome_unknown"
                }
            }
            else { result["state"] = "outcome_unknown" }
        }
        result["reason_code"] = outcome.failure?.code.rawValue
        return result
    }

    private func pauseSaved(_ config: IMessageSavedReadback, page: Page, view: WKWebView,
                            generation: UUID, cookies: String, intention: IMessageLocalPauseIntent?) async throws -> [String: Any] {
        guard let scope = page.scope else { throw IMessageSetupCoordinatorError.scopeChanged }
        // The entry record is the only local intention. Canonical metadata may
        // bind its owner, but cannot create a post-await Pause generation.
        let local = isLocalConfig(config, configuration: page.configuration)
        guard !local || intention != nil else { throw IMessageSetupCoordinatorError.scopeChanged }
        try await requireSavedPauseContext(intention, page: page, view: view, generation: generation)
        if local {
            if let intention { try requirePause(intention, page: page) }
            await dependencies.refreshRelayPolicy()
            try await requireSavedPauseContext(intention, page: page, view: view, generation: generation)
            if let intention { try requirePause(intention, page: page) }
            menuState = .syncPending
        }
        var result = savedReply("control", configID: config.integrationConfigID, page: page)
        do {
            try await requireSavedPauseContext(intention, page: page, view: view, generation: generation)
            let csrf = try await dependencies.csrf(view)
            try await requireSavedPauseContext(intention, page: page, view: view, generation: generation)
            let paused = try await saved.pause(config, configuration: page.configuration, cookies: cookies, csrf: csrf, scope: scope) {
                try await self.requireSavedPauseContext(intention, page: page, view: view, generation: generation)
                if let intention { try self.requirePause(intention, page: page) }
            }
            try await requireSavedPauseContext(intention, page: page, view: view, generation: generation)
            guard paused.config.paused else { throw IMessageHostedSetupError.invalidResponse }
            if local {
                try current(page, generation: generation)
                if let intention { try requirePause(intention, page: page) }
                dependencies.preferences.set(true, forKey: pauseAckKey(page.configuration))
                dependencies.preferences.synchronize(); menuState = .paused
            }
            result["state"] = "paused"; result["config_version"] = String(paused.configVersion)
        } catch {
            if error is CancellationError || !local { throw error }
            result["state"] = "sync_pending"
        }
        return result
    }

    private func savedReply(_ kind: String, configID: String, page: Page) -> [String: Any] {
        ["version": "1", "scope": page.scopeToken, "kind": kind, "config_id": configID]
    }
    private static func savedFlow(_ action: IMessageSavedPageCommand.Action) -> String {
        switch action { case .edit: "edit"; case .resume: "resume"; case .resumeFromNow: "resume_from_now"; default: "repair" }
    }
    private func isLocalConfig(_ config: IMessageSavedReadback, configuration: DesktopEnvironmentConfiguration) -> Bool {
        (try? dependencies.store(configuration).load())?.installationID == config.config.installationID
    }
    private func pauseAckKey(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: configuration.preferenceIdentity)
    }
    private func pauseIntentKey(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: configuration.preferenceIdentity)
    }
    private func savedOwnerKey(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigOwner", appOrigin: configuration.preferenceIdentity)
    }
    private func pauseIntent(_ configuration: DesktopEnvironmentConfiguration) -> IMessageLocalPauseIntent? {
        guard let value = dependencies.preferences.object(forKey: pauseIntentKey(configuration)) else { return nil }
        return try? IMessageLocalPauseIntent.parse(value)
    }
    @discardableResult private func beginLocalPause(configuration: DesktopEnvironmentConfiguration) -> IMessageLocalPauseIntent? {
        let owner = dependencies.preferences.object(forKey: savedOwnerKey(configuration)).flatMap { try? IMessageLocalPauseIntent.parse($0) }
        let record = try? IMessageLocalPauseIntent(installationID: owner?.installationID, configID: owner?.configID,
            naturalUserID: owner?.naturalUserID, workspaceID: owner?.workspaceID)
        dependencies.preferences.set(record?.preferences, forKey: pauseIntentKey(configuration))
        dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayPaused(configuration))
        dependencies.preferences.set(false, forKey: pauseAckKey(configuration))
        dependencies.preferences.synchronize()
        return record
    }
    private func supersedeLocalPause(_ configuration: DesktopEnvironmentConfiguration) {
        dependencies.preferences.removeObject(forKey: pauseIntentKey(configuration))
        dependencies.preferences.synchronize()
    }
    private func requirePause(_ intention: IMessageLocalPauseIntent, page: Page) throws {
        guard pauseIntent(page.configuration) == intention, dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(page.configuration)),
              page.scope?.naturalUserID == intention.naturalUserID, page.scope?.workspaceID == intention.workspaceID,
              (try dependencies.store(page.configuration).load())?.installationID == intention.installationID else {
            throw IMessageSetupCoordinatorError.scopeChanged
        }
    }
    private func synchronizePendingPause(_ page: Page, view: WKWebView, generation: UUID, cookies: String,
                                         expectedIntention: IMessageLocalPauseIntent? = nil) async throws {
        guard automaticRecoveryEnabled, !dependencies.preferences.bool(forKey: pauseAckKey(page.configuration)),
              let intention = pauseIntent(page.configuration), let id = intention.configID,
              intention.naturalUserID != nil, pauseSyncGeneration == nil,
              expectedIntention == nil || expectedIntention == intention else { return }
        try requirePause(intention, page: page)
        pauseSyncGeneration = intention.generation
        defer { if pauseSyncGeneration == intention.generation { pauseSyncGeneration = nil } }
        let validate: IMessageSavedConfigClient.ValidateCurrent = {
            try await self.requireCurrent(page, view: view, generation: generation)
            try self.requirePause(intention, page: page)
        }
        guard let scope = page.scope else { return }
        var config = try await saved.read(id, configuration: page.configuration, cookies: cookies, scope: scope, validateCurrent: validate)
        guard config.config.installationID == intention.installationID else { throw IMessageSetupCoordinatorError.scopeChanged }
        if !config.config.paused {
            let csrf = try await dependencies.csrf(view)
            try await validate()
            config = try await saved.pause(config, configuration: page.configuration, cookies: cookies, csrf: csrf, scope: scope, validateCurrent: validate)
        }
        try await validate()
        guard config.config.paused else { throw IMessageHostedSetupError.invalidResponse }
        try current(page, generation: generation)
        try requirePause(intention, page: page)
        dependencies.preferences.set(true, forKey: pauseAckKey(page.configuration))
        dependencies.preferences.synchronize(); menuState = .paused
    }
    func recoverPendingPause(_ preferredView: WKWebView? = nil) {
        guard automaticRecoveryEnabled, dependencies.admitsOperations(), lifetimeAdmitsOperations(),
              let configuration = try? dependencies.currentConfiguration() else { return }
        projectConfiguredAvailability(configuration)
        let pendingPause = pauseIntent(configuration) != nil && !dependencies.preferences.bool(forKey: pauseAckKey(configuration))
        guard canPauseMessages || pendingPause else { return }
        if configuredObservationID != nil { configuredObservationRequested = true; return }
        guard dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)), pauseSyncGeneration == nil,
              let view = preferredView ?? (pages.keyEnumerator().allObjects as? [WKWebView])?.first,
              let page = pages.object(forKey: view), page.configuration == configuration, page.documentReady, !page.busy else { return }
        let generation = page.generation
        let observation = UUID(), originalPause = pauseIntent(configuration)?.generation
        configuredObservationID = observation
        enqueue(page) {
            defer { self.finishConfiguredObservation(observation, view: view) }
            guard !page.busy else { return }
            do {
                let cookies = try await self.authorize(page, view: view, generation: generation)
                try await self.synchronizePendingPause(page, view: view, generation: generation, cookies: cookies)
                try await self.observeConfiguredStatus(page, view: view, generation: generation, cookies: cookies)
            } catch {
                self.configuredObservationFailed(page, generation: generation, originalPause: originalPause)
            }
        }
    }

    private func finishConfiguredObservation(_ id: UUID, view: WKWebView) {
        if configuredObservationID == id { configuredObservationID = nil }
        if configuredObservationRequested {
            configuredObservationRequested = false
            recoverPendingPause(view)
        }
    }

    private func configuredObservationFailed(_ page: Page, generation: UUID, originalPause: UUID?) {
        guard !Task.isCancelled, page.generation == generation, !page.retired,
              pauseIntent(page.configuration)?.generation == originalPause else { return }
        if !canPauseMessages || dependencies.configuredMenuAvailability() != .connected { projectConfiguredAvailability(page.configuration) }
        else { menuState = .needsAttention }
    }

    private func projectConfiguredAvailability(_ configuration: DesktopEnvironmentConfiguration) {
        guard dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(configuration)) else { menuState = .setupRequired; return }
        if dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration)) {
            menuState = dependencies.preferences.bool(forKey: pauseAckKey(configuration)) ? .paused : .syncPending
        } else { menuState = dependencies.configuredMenuAvailability() }
    }

    private func observeConfiguredStatus(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard canPauseMessages, dependencies.configuredMenuAvailability() == .connected,
              let id = dependencies.preferences.string(forKey: savedLocatorKey(page.configuration)), let scope = page.scope else { return }
        let context = try await dependencies.captureHumanContext()
        try await requireHumanCurrent(context, page: page, view: view, generation: generation)
        let config = try await saved.read(id, configuration: page.configuration, cookies: cookies, scope: scope) {
            try await self.requireHumanCurrent(context, page: page, view: view, generation: generation)
        }
        try await requireHumanCurrent(context, page: page, view: view, generation: generation)
        guard canPauseMessages, dependencies.preferences.string(forKey: savedLocatorKey(page.configuration)) == id else {
            projectConfiguredAvailability(page.configuration); return
        }
        guard config.config.installationID == context.session.installation.installationID else { menuState = .needsAttention; return }
        rememberSavedLocator(id, configuration: page.configuration, scope: scope)
        switch config.config.status.state {
        case "connected": menuState = config.config.status.receiveState == "pending" ? .resumePending : .connected
        case "paused": menuState = .paused
        case "offline", "reconnecting": menuState = .offline
        default: menuState = .needsAttention
        }
    }
    private func savedLocatorKey(_ configuration: DesktopEnvironmentConfiguration) -> String {
        DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: configuration.preferenceIdentity)
    }
    private func rememberSavedLocator(_ id: String, configuration: DesktopEnvironmentConfiguration, scope: IMessageHostedNativeScope? = nil) {
        dependencies.preferences.set(id, forKey: savedLocatorKey(configuration))
        if let scope, let installed = try? dependencies.store(configuration).load(),
           let record = try? IMessageLocalPauseIntent(installationID: installed.installationID, configID: id,
                naturalUserID: scope.naturalUserID, workspaceID: scope.workspaceID) {
            dependencies.preferences.set(record.preferences, forKey: savedOwnerKey(configuration))
        }
    }
    private func restoreSavedLocator() {
        pendingSavedHandoff = nil
        guard let configuration = try? dependencies.currentConfiguration(),
              let id = dependencies.preferences.string(forKey: savedLocatorKey(configuration)),
              let handoff = try? IMessageSavedHandoff(configID: id) else { return }
        pendingSavedHandoff = handoff
    }
    private func applySavedPreferences(_ result: IMessageSavedReadback, configuration: DesktopEnvironmentConfiguration,
                                       action: IMessageSavedPageCommand.Action? = nil) {
        rememberSavedLocator(result.integrationConfigID, configuration: configuration)
        if result.config.paused {
            dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayPaused(configuration))
            dependencies.preferences.set(true, forKey: pauseAckKey(configuration))
        }
        if action == .resume || action == .resumeFromNow, !result.config.paused {
            dependencies.preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(configuration))
            dependencies.preferences.set(false, forKey: IMessagePreferenceKeys.relayPaused(configuration))
        }
        if dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration)) {
            menuState = result.config.paused ? .paused : .syncPending
        } else if action == .resume || action == .resumeFromNow, result.config.status.receiveState == "pending" {
            menuState = .resumePending
        } else { menuState = result.config.status.state == "connected" ? .connected : .needsAttention }
        dependencies.preferences.synchronize()
    }
    private func menuPauseIsCurrent(_ intention: IMessageLocalPauseIntent, configuration: DesktopEnvironmentConfiguration) -> Bool {
        !Task.isCancelled && (try? dependencies.currentConfiguration()) == configuration && pauseIntent(configuration) == intention &&
            dependencies.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(configuration))
    }
    private func requireMenuPause(_ intention: IMessageLocalPauseIntent, configuration: DesktopEnvironmentConfiguration) throws {
        guard menuPauseIsCurrent(intention, configuration: configuration) else { throw IMessageSetupCoordinatorError.scopeChanged }
    }
    private func synchronizeMenuPause(configuration: DesktopEnvironmentConfiguration, intention: IMessageLocalPauseIntent, configID: String?) async {
        guard menuPauseIsCurrent(intention, configuration: configuration) else { return }
        guard let id = configID, let handoff = try? IMessageSavedHandoff(configID: id) else {
            pendingSavedHandoff = nil; openSetup(); return
        }
        pendingSavedHandoff = handoff
        guard let view = (pages.keyEnumerator().allObjects as? [WKWebView])?.first(where: {
            pages.object(forKey: $0)?.configuration == configuration && dependencies.pageURL($0)?.host == configuration.appURL.host
        }), let page = pages.object(forKey: view), page.documentReady else { openSetup(); return }
        let generation = page.generation
        var currentIntention = intention
        do {
            let cookies = try await authorize(page, view: view, generation: generation) {
                try self.requireMenuPause(intention, configuration: configuration)
            }
            try requireMenuPause(intention, configuration: configuration)
            guard let scope = page.scope else { return }
            let config = try await saved.read(id, configuration: page.configuration, cookies: cookies, scope: scope) {
                try await self.requireCurrent(page, view: view, generation: generation)
                try self.requireMenuPause(intention, configuration: configuration)
            }
            try requireMenuPause(intention, configuration: configuration)
            guard isLocalConfig(config, configuration: page.configuration) else { return }
            guard let bound = bindMenuPauseOwner(intention, config: config, page: page) else { return }
            currentIntention = bound
            try await synchronizePendingPause(page, view: view, generation: generation, cookies: cookies, expectedIntention: bound)
            try requireMenuPause(bound, configuration: configuration)
        } catch {
            guard !Task.isCancelled, menuPauseIsCurrent(currentIntention, configuration: configuration) else { return }
            menuState = .syncPending; openSetup()
        }
    }
    private func bindMenuPauseOwner(_ intention: IMessageLocalPauseIntent, config: IMessageSavedReadback, page: Page) -> IMessageLocalPauseIntent? {
        guard menuPauseIsCurrent(intention, configuration: page.configuration), let scope = page.scope else { return nil }
        guard intention.naturalUserID == nil else { return intention }
        guard intention.configID == nil || intention.configID == config.integrationConfigID,
              intention.installationID == nil || intention.installationID == config.config.installationID,
              let bound = try? IMessageLocalPauseIntent(generation: intention.generation, installationID: config.config.installationID,
                configID: config.integrationConfigID, naturalUserID: scope.naturalUserID, workspaceID: scope.workspaceID) else { return nil }
        rememberSavedLocator(config.integrationConfigID, configuration: page.configuration, scope: scope)
        dependencies.preferences.set(bound.preferences, forKey: pauseIntentKey(page.configuration))
        dependencies.preferences.synchronize()
        return bound
    }
    private func beginPendingMenuAction(_ page: Page, view: WKWebView, generation: UUID, cookies: String) async throws {
        guard let action = pendingMenuAction, let id = pendingSavedHandoff?.configID, let scope = page.scope else { return }
        let config = try await saved.read(id, configuration: page.configuration, cookies: cookies, scope: scope) {
            try await self.requireCurrent(page, view: view, generation: generation)
        }
        try await beginSavedFlow(action, config: config, page: page, view: view, generation: generation, cookies: cookies)
        pendingMenuAction = nil
    }
    private func isInitialEntry(_ view: WKWebView) -> Bool {
        guard let url = dependencies.pageURL(view), url.path == "/user/imessage" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty != false
    }
    private func isSavedLocatorEntry(_ view: WKWebView) -> Bool {
        guard let url = dependencies.pageURL(view), url.path == "/user/imessage",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.count == 1 && items[0].name == "config_id" && items[0].value != nil
    }
    private func presentHumanReview(_ config: IMessageSavedReadback, action: IMessageSavedPageCommand.Action,
                                    window: NSWindow?, page: Page) async -> HumanChoice? {
        if action == .check {
            let alert = NSAlert(); alert.messageText = "Check Messages connection?"
            alert.informativeText = "Mac: \(config.config.macName)\nMessages account: \(config.config.accountLabel)"
            alert.addButton(withTitle: "Check Connection"); alert.addButton(withTitle: "Cancel")
            return await presentAlert(alert, window: window, page: page) ? .init(conversationID: nil, text: nil) : nil
        }
        let conversations = config.config.conversations.filter(\.available)
        guard !conversations.isEmpty else { return nil }
        let compose = NSAlert(); compose.messageText = "Send a test message"
        compose.addButton(withTitle: "Review Message"); compose.addButton(withTitle: "Cancel")
        let controls = IMessageNativeMessageComposer(conversations: conversations, approvalButton: compose.buttons[0])
        compose.accessoryView = controls.view
        guard await presentAlert(compose, window: window, page: page), conversations.indices.contains(controls.picker.indexOfSelectedItem) else { return nil }
        let selected = conversations[controls.picker.indexOfSelectedItem], body = controls.text.string
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 16384 else { return nil }
        let preview = NSAlert(); preview.messageText = "Send iMessage?"
        preview.accessoryView = IMessageNativeMessageComposer.preview("To: \(selected.label)\n\(selected.participants.joined(separator: ", "))\nMac: \(config.config.macName)\nMessages account: \(config.config.accountLabel)\n\n\(body)")
        preview.addButton(withTitle: "Send iMessage"); preview.addButton(withTitle: "Cancel")
        guard await presentAlert(preview, window: window, page: page) else { return nil }
        return .init(conversationID: selected.conversationID, text: body)
    }
}
