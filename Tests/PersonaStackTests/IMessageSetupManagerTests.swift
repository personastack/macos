import Foundation
import Testing
import WebKit
import PersonaStackCore
@testable import PersonaStack

private let coordinatorReference = String(repeating: "A", count: 43)
private let coordinatorNow = Date(timeIntervalSince1970: 1_800_000_000)
private func coordinatorUTC(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func coordinatorJSON(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

private actor IMessageCoordinatorTransport: AgentBridgeHostedTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var mutations: [String] = []
    var workspace = "workspace"
    var bootstrapMismatch = false
    var lostCreate = false
    var revoked = false
    private var lostEnrollment = false
    private var macVerified = false
    private var configID: String?
    private var reference = coordinatorReference
    private var createdJourneys = 0
    private var journeyUnavailable = false
    private var heldPath: String?
    private var waiter: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func mismatchBootstrap() { bootstrapMismatch = true }
    func loseCreateResponse() { lostCreate = true }
    func revokeEnrollment() { revoked = true }
    func loseEnrollmentOnce() { lostEnrollment = true }
    func makeJourneyUnavailable() { journeyUnavailable = true }
    func selectWorkspace(_ value: String) { workspace = value }
    func hold(_ path: String) { heldPath = path }
    func waitUntilHeld() async { if waiter == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { heldPath = nil; waiter?.resume(); waiter = nil }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let path = request.url?.path ?? ""
        if heldPath == path { await withCheckedContinuation { waiter = $0; entered?.resume(); entered = nil } }
        if request.httpMethod == "POST" { mutations.append(path) }
        switch path {
        case "/user/imessage/native-scope":
            #expect(request.httpMethod == "GET")
            return (try coordinatorJSON(["natural_user_id": "human", "workspace_id": workspace, "app_origin": DesktopEnvironmentConfiguration.production.appOrigin]), 200)
        case "/user/mobile/bootstrap": return (try bootstrap(), 200)
        case "/user/imessage/setup": return try journeyRequest(request)
        case "/user/imessage/setup/reauthorize": return (try journey(), 200)
        case "/user/imessage/enrollment-ticket":
            return (try coordinatorJSON(["enrollment_ticket": coordinatorReference, "expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(300))]), 201)
        case "/v1/desktop-control/enroll", "/v1/desktop-control/attach": return try enrollment(path)
        case "/user/imessage/setup/metadata": return (try verification(request), 200)
        case "/user/imessage/approve":
            #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (try coordinatorJSON(["setup_receipt": coordinatorReference, "expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(60))]), 201)
        case "/user/imessage/configs":
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ps_session=fixture")
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "fixture-csrf")
            configID = "canonical-config"
            return (try coordinatorJSON(["integration_config_id": "canonical-config"]), lostCreate ? 503 : 201)
        default: Issue.record("Unplanned coordinator route \(path)"); throw IMessageHostedSetupError.serviceUnavailable
        }
    }
    private func journeyRequest(_ request: URLRequest) throws -> (Data, Int) {
        if request.httpMethod == "POST" {
            #expect(request.httpBody == Data("{}".utf8))
            #expect(request.value(forHTTPHeaderField: "Cookie") == "ps_session=fixture")
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "fixture-csrf")
            #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-imessage-v1")
            #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == workspace)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            createdJourneys += 1
            reference = Data(repeating: UInt8(10 + createdJourneys), count: 32).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            macVerified = false; configID = nil; journeyUnavailable = false; revoked = false
            return (try journey(), 201)
        }
        #expect(request.httpMethod == "GET")
        let requested = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "setup_reference" })?.value
        if journeyUnavailable || requested != reference { return (Data(), 404) }
        return (try journey(), 200)
    }
    private func enrollment(_ path: String) throws -> (Data, Int) {
        if revoked { return (Data(), 410) }
        macVerified = true
        if lostEnrollment { lostEnrollment = false; return (Data(), 503) }
        return (try coordinatorJSON(["installation_id": "mac", "gateway_websocket_url": DesktopEnvironmentConfiguration.production.gatewayWebsocketURL.absoluteString]), path.hasSuffix("enroll") ? 201 : 200)
    }
    private func journey() throws -> Data {
        var object: [String: Any] = ["setup_reference": reference, "generation": 1,
            "expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(3600)), "mac_verified": macVerified]
        object["integration_config_id"] = configID
        return try coordinatorJSON(object)
    }
    private func bootstrap() throws -> Data {
        let active = bootstrapMismatch ? "personal" : workspace
        return try coordinatorJSON(["authenticated": true, "natural_user": ["id": "human", "role": "user"],
            "effective_user": ["id": "human", "role": "user", "display_name": "Human", "email": "", "avatar_url": "", "time_zone": ""],
            "impersonation_active": false, "session_expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(7200)),
            "workspaces": [["id": active, "display_name": "Team workspace", "status": "active", "organization_id": "org", "organization_name": "Team", "personal": false, "workspace_admin": false]],
            "active_workspace_id": active, "no_accessible_workspace": false, "csrf_token": "private-csrf"])
    }
    private func verification(_ request: URLRequest) throws -> Data {
        let body = try #require(request.httpBody)
        try IMessageJSONDocument.validate(data: body, maximumBytes: 16384)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(Set(object.keys) == ["setup_reference", "generation", "enrollment_ticket", "operation", "input"])
        #expect(object["operation"] as? String == "imessage_verify_conversations")
        let input = try #require(object["input"] as? [String: Any])
        #expect(Set(input.keys) == ["verify_conversations"])
        let selection = try #require(input["verify_conversations"] as? [String: Any])
        #expect(Set(selection.keys) == ["conversation_ids"])
        let ids = try #require(selection["conversation_ids"] as? [String])
        let rows: [[String: Any]] = ids.map { ["conversation_id": $0, "label": "Retained conversation", "is_group": false, "participant_count": 1, "available": true] }
        return try coordinatorJSON(["setup_reference": reference, "generation": 1, "operation": "imessage_verify_conversations",
            "result": ["verification": ["conversations": rows, "verified": true]]])
    }
}

private actor IMessageCoordinatorProvider: IMessageSetupProviding {
    private(set) var restores = 0
    private(set) var stops = 0
    func prerequisites(deadline: Date) throws -> IMessageGatewayPrerequisitesResult { throw IMessageSetupProviderError.dependencyInvalid }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int, deadline: Date) throws -> IMessageSetupProviderPage { throw IMessageSetupProviderError.dependencyInvalid }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification { throw IMessageSetupProviderError.dependencyInvalid }
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification {
        restores += 1
        #expect(account == .init(accountID: "native-account", sourceGeneration: "native-source"))
        let rows = try selections.map { selection in
            let data = try coordinatorJSON(["id": selection.nativeChatRowID, "guid": selection.expectedGUID, "name": "Retained conversation",
                "service": "iMessage", "is_group": false, "available": true, "participants": ["participant"]])
            try IMessageJSONDocument.validate(data: data, maximumBytes: 4096)
            return try JSONDecoder().decode(IMessageConversation.self, from: data)
        }
        return .init(conversations: rows, liveAccount: .init(accountID: account.accountID, sourceGeneration: account.sourceGeneration, chatGUIDs: rows.map(\.guid)))
    }
    func stop() { stops += 1 }
}

private actor IMessageCoordinatorNeverTransport: IMessageRPCTransport {
    func launch() throws { Issue.record("Coordinator unexpectedly launched a real provider adapter"); throw IMessageRPCError.dependencyInvalid }
    func read(maximumBytes: Int) throws -> Data { throw IMessageRPCError.notStarted }
    func write(_ data: Data) throws { throw IMessageRPCError.notStarted }
    func terminate() {}
}

private final class IMessageCoordinatorRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Data { lock.withLock { count += 1; return Data(repeating: UInt8(7 + count), count: 32) } }
    var calls: Int { lock.withLock { count } }
}

@MainActor private final class IMessageCoordinatorState {
    var acceptReview = false
    var permissionReady = false
    var automationRequests = 0
    var background = false
    var restartRequests = 0
    var reviews = 0
    var relayRetains = 0
    var relayReleases = 0
    var cookies = "ps_session=fixture"
    var metadataConsent = true
    var metadataConsentRequests = 0
    var settingsOpened: [String] = []
    var synchronizedReferences: [String] = []
    var navigations: [URL] = []
}

@MainActor private final class IMessageCoordinatorFixture {
    let transport = IMessageCoordinatorTransport()
    let provider = IMessageCoordinatorProvider()
    let directory: URL
    let store: FileDesktopControlCredentialStore
    let runtime: IMessageRuntime
    let view = WKWebView()
    let manager: IMessageSetupManager
    let preferences: UserDefaults
    let suite: String
    let random = IMessageCoordinatorRandom()
    let dependencies: IMessageSetupManager.Dependencies
    let state = IMessageCoordinatorState()

    init(restored: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-coordinator-" + UUID().uuidString)
        suite = "imessage-coordinator-" + UUID().uuidString
        preferences = UserDefaults(suiteName: suite)!
        let config = DesktopEnvironmentConfiguration.production
        store = .init(directory: directory, configurationProvider: { config }, legacyLoader: { _ in nil }, randomBytes: { [random] in random.next() })
        let rowProvider = provider
        runtime = .init(installationID: "mac", provider: rowProvider, referenceDigest: IMessageSetupProvider.setupReferenceDigest, now: { coordinatorNow })
        let nativeProvider = IMessageSetupProvider(client: .init(transport: IMessageCoordinatorNeverTransport()))
        var deps = IMessageSetupManager.Dependencies()
        deps.configuration = { _ in config }; deps.currentConfiguration = { config }
        deps.store = { [store] _ in store }; deps.now = { coordinatorNow }; deps.preferences = preferences
        deps.csrf = { _ in "fixture-csrf" }; deps.macName = { "Fixture Mac" }
        deps.cookies = { [state] _, _ in state.cookies }
        deps.session = { [store, runtime] in
            let loaded = try store.load()
            let installation = try #require(loaded)
            return .init(installation: installation, configuration: config, runtime: runtime, provider: nativeProvider)
        }
        deps.retainRelay = { [state] _ in state.relayRetains += 1; return UUID() }
        deps.releaseRelay = { [state] _, _ in state.relayReleases += 1 }
        deps.permissionState = { [state] _, _ in state.permissionReady ? .ready : .fullDiskAccessRequired }
        deps.messagesAccess = { [state] _, _ in state.automationRequests += 1; state.permissionReady = true }
        deps.prepareBackground = { [state] _ in state.background = true }
        deps.backgroundReady = { [state] in state.background }
        deps.restart = { [state] _ in state.restartRequests += 1 }
        deps.showReview = { [state] review, _ in
            state.reviews += 1
            #expect(review.workspaceName == "Team workspace" && review.macName == "Fixture Mac" && review.accountLabel == "Native Messages account")
            #expect(review.conversations.map(\.metadata.guid) == ["native-guid"])
            return state.acceptReview
        }
        deps.accountLabel = { _, _ in "Native Messages account" }
        deps.showMetadataConsent = { [state] _ in state.metadataConsentRequests += 1; return state.metadataConsent }
        deps.evidence = { _, consent, validate in
            #expect(try await validate(consent))
            let checkpoint = try IMessageSetupApprovalCheckpoint(sourceHighWater: IMessageRowID(1), observedAt: coordinatorUTC(coordinatorNow),
                chats: consent.conversations.map { try .init(chatID: $0.metadata.id, guid: $0.metadata.guid, tailRowID: IMessageRowID(1), tailGUID: "tail") })
            return try .init(verification: .init(conversations: consent.conversations, liveAccount: .init(accountID: consent.account.accountID,
                sourceGeneration: consent.account.sourceGeneration, chatGUIDs: consent.conversations.map(\.metadata.guid))), checkpoint: checkpoint,
                readEnabled: true, sendEnabled: true)
        }
        deps.openMessages = { Issue.record("Unplanned Messages launch") }
        deps.openSettings = { [state] section in state.settingsOpened.append(section) }
        deps.openLoginItems = { Issue.record("Unplanned Login Items launch") }
        deps.navigate = { [state] url in state.navigations.append(url) }
        deps.synchronizeReference = { [state] _, reference in state.synchronizedReferences.append(reference) }
        let client = IMessageHostedSetupClient(transport: transport)
        dependencies = deps
        manager = .init(hosted: client, machine: .init(transport: transport), dependencies: deps)
        manager.register(view, appURL: config.appURL)
        if restored {
            let draft = try IMessageSetupDraft(setupReference: coordinatorReference, naturalUserID: "human", workspaceID: "workspace",
                environmentIdentity: config.preferenceIdentity, expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(3600)),
                expectedAccountID: "native-account", sourceGeneration: "native-source",
                selectedConversations: [.init(nativeChatRowID: "1", expectedGUID: "native-guid")])
            try store.saveSetupDraft(draft, now: coordinatorNow)
        }
    }
    func apply(_ action: String, scope: String = "", extra: [String: Any] = [:]) async throws -> [String: Any] {
        var body: [String: Any] = ["version": "1", "action": action, "scope": scope]
        if action == "begin" { body.removeValue(forKey: "scope"); body["setup_reference"] = coordinatorReference }
        body.merge(extra) { _, new in new }
        return try await manager.apply(.parse(body), view: view)
    }
    func prepareSelection() async throws -> String {
        let initial = try await apply("begin")
        let scope = try #require(initial["scope"] as? String)
        _ = try await apply("continue", scope: scope)
        _ = try await apply("request_messages_access", scope: scope)
        _ = try await apply("enable_background", scope: scope)
        let selected = try await apply("allow_metadata", scope: scope)
        let ids = try #require(selected["selected_conversation_ids"] as? [String])
        #expect(ids.count == 1)
        _ = try await apply("set_selected", scope: scope, extra: ["conversation_ids": ids])
        _ = try await apply("verify", scope: scope)
        return scope
    }
    func cleanup() async throws {
        await manager.shutdown()
        preferences.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

@Test @MainActor func iMessageSetupManagerRestoresOnlyFreshNativeSelectionAndFinalCancelCreatesNothing() async throws {
    let fixture = try IMessageCoordinatorFixture(restored: true)
    let scope = try await fixture.prepareSelection()
    let loaded = try fixture.store.loadSetupDraft()
    let before = try #require(loaded)
    let result = try await fixture.apply("confirm", scope: scope)
    #expect(result["state"] as? String == "review")
    #expect(fixture.state.reviews == 1 && fixture.state.automationRequests == 1)
    #expect(await fixture.provider.restores == 1)
    #expect(try fixture.store.loadSetupDraft() == before)
    #expect(await fixture.transport.mutations.allSatisfy { !["/user/imessage/approve", "/user/imessage/configs"].contains($0) })
    #expect(!String(describing: result).contains("native-guid") && !String(describing: result).contains("native-account"))
    try await fixture.cleanup()
}

@Test(arguments: [false, true]) @MainActor
func iMessageSetupManagerCreatesOnceAndRecoversCanonicalIDAfterLostResponse(lostResponse: Bool) async throws {
    let fixture = try IMessageCoordinatorFixture(restored: true)
    fixture.state.acceptReview = true
    let scope = try await fixture.prepareSelection()
    if lostResponse { await fixture.transport.loseCreateResponse() }
    if lostResponse {
        await #expect(throws: IMessageHostedSetupError.serviceUnavailable) { _ = try await fixture.apply("confirm", scope: scope) }
    } else {
        let result = try await fixture.apply("confirm", scope: scope)
        #expect(result["integration_config_id"] as? String == "canonical-config")
    }
    let recovered = try await fixture.apply("state", scope: scope)
    #expect(recovered["integration_config_id"] as? String == "canonical-config")
    let paths = await fixture.transport.mutations
    #expect(paths.filter { $0 == "/user/imessage/approve" }.count == 1)
    #expect(paths.filter { $0 == "/user/imessage/configs" }.count == 1)
    #expect(fixture.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(.production)))
    #expect(fixture.state.relayReleases == 1)
    #expect(!String(describing: recovered).contains("setup_receipt") && !String(describing: recovered).contains("checkpoint"))
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerMismatchedCanonicalWorkspaceMakesNoMutation() async throws {
    let fixture = try IMessageCoordinatorFixture()
    await fixture.transport.mismatchBootstrap()
    await #expect(throws: IMessageHostedSetupError.scopeChanged) { _ = try await fixture.apply("begin") }
    #expect(await fixture.transport.mutations.isEmpty)
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerLateReauthorizationCannotPrepareProofOrEnroll() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    await fixture.transport.hold("/user/imessage/setup/reauthorize")
    let pending = Task { _ = try await fixture.apply("continue", scope: scope) }
    await fixture.transport.waitUntilHeld()
    fixture.manager.invalidate(fixture.view)
    await fixture.transport.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    #expect(await fixture.transport.mutations == ["/user/imessage/setup/reauthorize"])
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerRequiresExplicitPermissionsAndBackgroundBeforeMetadata() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    _ = try await fixture.apply("continue", scope: scope)
    await #expect(throws: IMessageSetupCoordinatorError.permissionRequired) { _ = try await fixture.apply("allow_metadata", scope: scope) }
    #expect(fixture.state.automationRequests == 0 && fixture.state.relayRetains == 0)
    _ = try await fixture.apply("check_permissions", scope: scope)
    #expect(fixture.state.automationRequests == 0)
    _ = try await fixture.apply("request_messages_access", scope: scope)
    await #expect(throws: IMessageSetupCoordinatorError.backgroundRequired) { _ = try await fixture.apply("allow_metadata", scope: scope) }
    _ = try await fixture.apply("enable_background", scope: scope)
    _ = try await fixture.apply("allow_metadata", scope: scope)
    #expect(fixture.state.relayRetains == 1)
    #expect(!fixture.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(.production)))
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerRestartAndNavigationPreservePrivateDraftAndInstalledIdentity() async throws {
    let fixture = try IMessageCoordinatorFixture(restored: true)
    let scope = try await fixture.prepareSelection()
    let draft = try fixture.store.loadSetupDraft(), installation = try fixture.store.load()
    _ = try await fixture.apply("restart", scope: scope)
    #expect(fixture.state.restartRequests == 1 && fixture.state.relayReleases == 1)
    #expect(try fixture.store.loadSetupDraft() == draft)
    #expect(try fixture.store.load()?.installationID == installation?.installationID)
    fixture.manager.invalidate(fixture.view)
    await #expect(throws: IMessageSetupCoordinatorError.scopeChanged) { _ = try await fixture.apply("confirm", scope: scope) }
    #expect(try fixture.store.loadSetupDraft() == draft)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerLostEnrollmentKeepsSameProofForNextExplicitContinue() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let oldReference = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let old = try fixture.store.preparePendingEnrollment(setupReference: oldReference, naturalUserID: "human", workspaceID: "workspace",
        expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(-60)), now: coordinatorNow.addingTimeInterval(-3600))
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    await fixture.transport.loseEnrollmentOnce()
    await #expect(throws: IMessageMachineSetupError.serviceUnavailable) { _ = try await fixture.apply("continue", scope: scope) }
    let loaded = try fixture.store.loadPendingEnrollment()
    let retained = try #require(loaded)
    #expect(retained.credentialBytes == old.credentialBytes && retained.setupReference == coordinatorReference)
    _ = try await fixture.apply("continue", scope: scope)
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    #expect(try fixture.store.load()?.machineCredential == old.machineCredential)
    #expect(await fixture.transport.mutations.filter { $0 == "/v1/desktop-control/enroll" }.count == 2)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerCancelFencesAnInflightApprovalBeforeCreate() async throws {
    let fixture = try IMessageCoordinatorFixture(restored: true)
    fixture.state.acceptReview = true
    let scope = try await fixture.prepareSelection()
    let draft = try fixture.store.loadSetupDraft()
    await fixture.transport.hold("/user/imessage/approve")
    let pending = Task { _ = try await fixture.apply("confirm", scope: scope) }
    await fixture.transport.waitUntilHeld()
    let cancelled = try await fixture.apply("cancel", scope: scope)
    #expect(cancelled["state"] as? String == "continue")
    await fixture.transport.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await fixture.transport.mutations.filter { $0 == "/user/imessage/configs" }.isEmpty)
    #expect(try fixture.store.loadSetupDraft() == draft)
    #expect(try fixture.store.load()?.installationID == "mac")
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerRequiresExactTerminalReceiptAndExplicitStartAgain() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    await fixture.transport.revokeEnrollment()
    let reset = try await fixture.apply("continue", scope: scope)
    #expect(reset["reason_code"] as? String == "start_again_required")
    let loaded = try fixture.store.loadPendingEnrollment()
    let old = try #require(loaded)
    let fresh = try await fixture.apply("start_again", scope: scope)
    let reference = try #require(fresh["setup_reference"] as? String)
    #expect(reference != coordinatorReference && fresh["scope"] as? String == scope)
    #expect(fresh["next_action"] as? String == "continue" && fresh["reason_code"] == nil)
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    #expect(try fixture.store.load() == nil)
    _ = try await fixture.apply("continue", scope: scope)
    #expect(try fixture.store.load()?.machineCredential != old.machineCredential)
    #expect(fixture.random.calls == 2)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerFreshJourneyCarriesOnlySameOwnerDraftIntent() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let oldReference = Data(repeating: 9, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let old = try IMessageSetupDraft(setupReference: oldReference, naturalUserID: "human", workspaceID: "workspace",
        environmentIdentity: DesktopEnvironmentConfiguration.production.preferenceIdentity, expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(120)),
        expectedAccountID: "native-account", sourceGeneration: "native-source", selectedConversations: [.init(nativeChatRowID: "1", expectedGUID: "native-guid")])
    try fixture.store.saveSetupDraft(old, now: coordinatorNow)
    let scope = try await fixture.prepareSelection()
    let loaded = try fixture.store.loadSetupDraft()
    let migrated = try #require(loaded)
    #expect(migrated.setupReference == coordinatorReference && migrated.selectedConversations == old.selectedConversations)
    #expect(await fixture.provider.restores == 1)
    #expect(!scope.isEmpty)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerBeginAndCancelNeverGrantMetadataOrStartProvider() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    _ = try await fixture.apply("cancel", scope: scope)
    #expect(fixture.state.metadataConsentRequests == 0 && fixture.state.relayRetains == 0)
    #expect(await fixture.provider.restores == 0)
    #expect(await fixture.transport.mutations.isEmpty)
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerMetadataSheetCancelLeavesRuntimeDenied() async throws {
    let fixture = try IMessageCoordinatorFixture(restored: true)
    fixture.state.metadataConsent = false
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    _ = try await fixture.apply("continue", scope: scope)
    _ = try await fixture.apply("request_messages_access", scope: scope)
    _ = try await fixture.apply("enable_background", scope: scope)
    let result = try await fixture.apply("allow_metadata", scope: scope)
    #expect(result["state"] as? String == "background")
    #expect(fixture.state.metadataConsentRequests == 1 && fixture.state.relayRetains == 0)
    #expect(await fixture.provider.restores == 0)
    #expect(await fixture.transport.mutations.allSatisfy { !$0.hasSuffix("metadata") })
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerFDASettingsOffersConditionalRestartWithoutClaimingGrant() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    _ = try await fixture.apply("continue", scope: scope)
    _ = try await fixture.apply("check_permissions", scope: scope)
    let opened = try await fixture.apply("open_full_disk_access", scope: scope)
    #expect(opened["restart_available"] as? Bool == true)
    #expect(opened["permissions_ready"] as? Bool == false)
    let denied = try await fixture.apply("check_permissions", scope: scope)
    #expect(denied["next_action"] as? String == "open_full_disk_access")
    #expect(denied["restart_available"] as? Bool == true)
    #expect(fixture.state.settingsOpened == ["Privacy_AllFiles"])
    _ = try await fixture.apply("request_messages_access", scope: scope)
    let ready = try await fixture.apply("check_permissions", scope: scope)
    #expect(ready["restart_available"] as? Bool == false && ready["permissions_ready"] as? Bool == true)
    try await fixture.cleanup()
}

private func coordinatorCookie(_ name: String, domain: String, secure: Bool = false, expires: Date? = nil) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "fixture", .domain: domain, .path: "/"]
    if secure { properties[.secure] = "TRUE" }
    if let expires { properties[.expires] = expires }
    return try #require(HTTPCookie(properties: properties))
}

@Test @MainActor func iMessageSetupManagerCookiePolicyUsesActualBFFDefaultAndConfiguredOrigin() throws {
    let cookies = try [
        coordinatorCookie("ps_session", domain: "my.personastack.ai"),
        coordinatorCookie("custom_login", domain: "my.personastack.ai"),
        coordinatorCookie("personastack_session", domain: "my.personastack.ai"),
        coordinatorCookie("personastack_workspace_id_human", domain: "my.personastack.ai"),
        coordinatorCookie("parent_domain", domain: ".personastack.ai"),
        coordinatorCookie("parent_host_only", domain: "personastack.ai"),
        coordinatorCookie("foreign", domain: ".foreign.invalid"),
        coordinatorCookie("suffix_attack", domain: ".evilpersonastack.ai"),
        coordinatorCookie("child_only", domain: "child.my.personastack.ai"),
        coordinatorCookie("expired", domain: "my.personastack.ai", expires: coordinatorNow.addingTimeInterval(-1)),
        coordinatorCookie("secure", domain: "my.personastack.ai", secure: true),
    ]
    let header = try IMessageSetupManager.cookieHeader(cookies, configuration: .production, now: coordinatorNow)
    for name in ["ps_session", "custom_login", "personastack_session", "personastack_workspace_id_human", "parent_domain", "secure"] {
        #expect(header.contains(name + "=fixture"))
    }
    for name in ["parent_host_only", "foreign", "suffix_attack", "child_only", "expired"] { #expect(!header.contains(name + "=fixture")) }
    let http = try DesktopEnvironmentConfiguration(appURL: "http://my.personastack.ai", gatewayURL: DesktopEnvironmentConfiguration.production.gatewayURL.absoluteString,
        mcpURL: DesktopEnvironmentConfiguration.production.mcpURL.absoluteString)
    let insecure = try IMessageSetupManager.cookieHeader(cookies, configuration: http, now: coordinatorNow)
    #expect(insecure.contains("ps_session=fixture") && !insecure.contains("secure=fixture"))
}

@Test @MainActor func iMessageSetupManagerNavigationWithoutPrivateJourneyStartsIdleThenCreatesOnceNatively() async throws {
    let fixture = try IMessageCoordinatorFixture()
    fixture.manager.documentInvalidated(fixture.view)
    fixture.manager.documentCommitted(fixture.view)
    let initial = try await fixture.apply("state")
    let scope = try #require(initial["scope"] as? String)
    #expect(initial["state"] as? String == "idle" && initial["next_action"] as? String == "start_again")
    #expect(initial["setup_reference"] == nil)
    #expect(await fixture.transport.mutations.isEmpty)
    let fresh = try await fixture.apply("start_again", scope: scope)
    let reference = try #require(fresh["setup_reference"] as? String)
    #expect(fresh["state"] as? String == "continue" && fresh["scope"] as? String == scope)
    #expect(fixture.state.synchronizedReferences == [reference])
    fixture.manager.openSetup()
    #expect(fixture.state.navigations.last?.query == "setup_reference=" + reference)
    #expect(await fixture.transport.mutations == ["/user/imessage/setup"])
    fixture.manager.documentInvalidated(fixture.view)
    fixture.manager.documentCommitted(fixture.view)
    let refreshed = try await fixture.apply("state")
    #expect(refreshed["setup_reference"] as? String == reference && refreshed["next_action"] as? String == "continue")
    #expect(try fixture.store.loadPendingEnrollment() == nil)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerUnavailableJourneyPreservesProofUntilExplicitFreshJourney() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let old = try fixture.store.preparePendingEnrollment(setupReference: coordinatorReference, naturalUserID: "human", workspaceID: "workspace",
        expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(60)), now: coordinatorNow)
    await fixture.transport.makeJourneyUnavailable()
    let unavailable = try await fixture.apply("begin")
    let scope = try #require(unavailable["scope"] as? String)
    #expect(unavailable["state"] as? String == "needs_attention" && unavailable["next_action"] as? String == "start_again")
    #expect(try fixture.store.loadPendingEnrollment() == old && fixture.random.calls == 1)
    let fresh = try await fixture.apply("start_again", scope: scope)
    let loaded = try fixture.store.loadPendingEnrollment()
    let retained = try #require(loaded)
    #expect(retained.credentialBytes == old.credentialBytes && retained.setupReference == fresh["setup_reference"] as? String)
    #expect(fresh["reason_code"] == nil && fresh["next_action"] as? String == "continue")
    _ = try await fixture.apply("continue", scope: scope)
    #expect(try fixture.store.load()?.machineCredential == old.machineCredential)
    #expect(fixture.random.calls == 1)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerExpiredDraftCreatesFreshJourneyWithoutLosingSelectedIntent() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let expiry = coordinatorUTC(coordinatorNow.addingTimeInterval(-60))
    let oldProof = try fixture.store.preparePendingEnrollment(setupReference: coordinatorReference, naturalUserID: "human", workspaceID: "workspace",
        expiresAt: expiry, now: coordinatorNow.addingTimeInterval(-3600))
    let draft = try IMessageSetupDraft(setupReference: coordinatorReference, naturalUserID: "human", workspaceID: "workspace",
        environmentIdentity: DesktopEnvironmentConfiguration.production.preferenceIdentity, expiresAt: expiry,
        expectedAccountID: "native-account", sourceGeneration: "native-source", selectedConversations: [.init(nativeChatRowID: "1", expectedGUID: "native-guid")])
    try fixture.store.saveSetupDraft(draft, now: coordinatorNow.addingTimeInterval(-3600))
    fixture.manager.documentInvalidated(fixture.view); fixture.manager.documentCommitted(fixture.view)
    let expired = try await fixture.apply("state")
    let scope = try #require(expired["scope"] as? String)
    #expect(expired["next_action"] as? String == "start_again" && expired["state"] as? String == "needs_attention")
    #expect(await fixture.transport.requests.allSatisfy { $0.url?.path != "/user/imessage/setup" })
    let fresh = try await fixture.apply("start_again", scope: scope)
    let reference = try #require(fresh["setup_reference"] as? String)
    let loadedDraft = try fixture.store.loadSetupDraft(), loadedProof = try fixture.store.loadPendingEnrollment()
    #expect(loadedDraft?.setupReference == reference && loadedDraft?.selectedConversations == draft.selectedConversations)
    #expect(loadedProof?.credentialBytes == oldProof.credentialBytes && loadedProof?.setupReference == reference)
    let relaunched = IMessageSetupManager(hosted: .init(transport: fixture.transport), machine: .init(transport: fixture.transport), dependencies: fixture.dependencies)
    let view = WKWebView()
    relaunched.register(view, appURL: DesktopEnvironmentConfiguration.production.appURL)
    relaunched.documentInvalidated(view); relaunched.documentCommitted(view)
    let restored = try await relaunched.apply(.parse(["version": "1", "action": "state", "scope": ""]), view: view)
    #expect(restored["setup_reference"] as? String == reference && restored["next_action"] as? String == "continue")
    #expect(fixture.random.calls == 1)
    await relaunched.shutdown()
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerAccountSwitchCannotDiscardOrMigrateUnresolvedProof() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let old = try fixture.store.preparePendingEnrollment(setupReference: coordinatorReference, naturalUserID: "human", workspaceID: "workspace",
        expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(60)), now: coordinatorNow)
    await fixture.transport.makeJourneyUnavailable(); await fixture.transport.selectWorkspace("personal")
    let unavailable = try await fixture.apply("begin")
    let scope = try #require(unavailable["scope"] as? String)
    await #expect(throws: IMessageSetupCoordinatorError.scopeChanged) { _ = try await fixture.apply("start_again", scope: scope) }
    #expect(try fixture.store.loadPendingEnrollment() == old && fixture.random.calls == 1)
    #expect(await fixture.transport.mutations.isEmpty)
    try await fixture.cleanup()
}

@Test @MainActor func iMessageSetupManagerLateFreshJourneyCannotApplyOldTerminalResetReceipt() async throws {
    let fixture = try IMessageCoordinatorFixture()
    let initial = try await fixture.apply("begin")
    let scope = try #require(initial["scope"] as? String)
    await fixture.transport.revokeEnrollment()
    _ = try await fixture.apply("continue", scope: scope)
    let old = try fixture.store.loadPendingEnrollment()
    await fixture.transport.hold("/user/imessage/setup")
    let pending = Task { _ = try await fixture.apply("start_again", scope: scope) }
    await fixture.transport.waitUntilHeld()
    fixture.manager.documentInvalidated(fixture.view)
    await fixture.transport.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(try fixture.store.loadPendingEnrollment() == old)
    #expect(fixture.state.synchronizedReferences.isEmpty && fixture.random.calls == 1)
    try await fixture.cleanup()
}
