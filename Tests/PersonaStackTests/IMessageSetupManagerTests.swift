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
    private var holdSingleRequest = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var savedRuntime: IMessageRuntime?
    private var savedVersion: Int64 = 7
    private var savedInstallationID = "mac"
    private var savedPaused = false
    private var savedRead = true
    private var savedSend = true
    private var savedGaps: [String] = []
    private var realMetadata = false
    private var observedState = "connected"
    private var observedReceiveState = "disabled"
    private var extraUnavailableConversation = false
    private var savedUnavailable = false
    private var loseSavedMutation = false
    private let savedConnection = UUID()
    func enableSaved(_ runtime: IMessageRuntime, paused: Bool = false) { savedRuntime = runtime; savedPaused = paused }
    func makeSavedUnavailable() { savedUnavailable = true }
    func loseSavedResponse() { loseSavedMutation = true }
    func advanceSavedVersion() { savedVersion += 1 }
    func setSavedGaps(_ ids: [String]) { savedGaps = ids }
    func useRealRuntimeMetadata() { realMetadata = true }
    func setObservedStatus(_ state: String, receive: String = "disabled") { observedState = state; observedReceiveState = receive }
    func includeUnavailableConversation() { extraUnavailableConversation = true }
    func setSavedAvailable(_ value: Bool) { savedUnavailable = !value }
    func setSavedInstallationID(_ value: String) { savedInstallationID = value }
    func mismatchBootstrap() { bootstrapMismatch = true }
    func loseCreateResponse() { lostCreate = true }
    func revokeEnrollment() { revoked = true }
    func loseEnrollmentOnce() { lostEnrollment = true }
    func makeJourneyUnavailable() { journeyUnavailable = true }
    func selectWorkspace(_ value: String) { workspace = value }
    func hold(_ path: String) { heldPath = path; holdSingleRequest = false }
    func holdOnce(_ path: String) { heldPath = path; holdSingleRequest = true }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while waiter == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard waiter != nil else { throw IMessageSetupCoordinatorError.unavailable }
    }
    func release() { heldPath = nil; waiter?.resume(); waiter = nil }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let path = request.url?.path ?? ""
        if heldPath == path {
            if holdSingleRequest { heldPath = nil; holdSingleRequest = false }
            await withCheckedContinuation { waiter = $0 }
        }
        if request.httpMethod == "POST" || request.httpMethod == "PATCH" { mutations.append(path) }
        if path == "/user/imessage/configs/saved" || path.hasPrefix("/user/imessage/configs/saved/") {
            return try savedRequest(request)
        }
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
        case "/user/imessage/setup/metadata": return (try await verification(request), 200)
        case "/user/imessage/approve":
            #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (try coordinatorJSON(["setup_receipt": coordinatorReference, "expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(60))]), 201)
        case "/v1/desktop-control/imessage/actions/redeem": return try humanRedeemed(request)
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
    private func savedRequest(_ request: URLRequest) throws -> (Data, Int) {
        if request.url?.path.hasSuffix("/check") == true || request.url?.path.hasSuffix("/test-send") == true { return try humanPrepared(request) }
        if savedUnavailable { throw IMessageHostedSetupError.serviceUnavailable }
        if request.httpMethod == "GET" {
            return (try savedReadback(), 200)
        }
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(object["expected_config_version"] as? String == String(savedVersion))
        #expect(request.value(forHTTPHeaderField: "Cookie") == "ps_session=fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "fixture-csrf")
        if request.url?.path.hasSuffix("/pause") == true {
            #expect(Set(object.keys) == ["expected_config_version"])
            savedPaused = true
        } else {
            var expected: Set<String> = ["expected_config_version", "name", "conversation_ids", "read_enabled", "send_enabled", "native_approval_receipt"]
            let fromNow = request.url?.path.hasSuffix("/resume-from-now") == true
            if fromNow { expected.insert("resume_conversation_ids") }
            #expect(Set(object.keys) == expected)
            #expect(object["native_approval_receipt"] as? String == coordinatorReference)
            if fromNow {
                #expect(object["conversation_ids"] as? [String] == (extraUnavailableConversation ? ["selected", "other"] : ["selected"]))
                #expect(object["resume_conversation_ids"] as? [String] == savedGaps)
                savedGaps = []
            } else { #expect(object["conversation_ids"] as? [String] != ["selected"]) }
            savedRead = try #require(object["read_enabled"] as? Bool)
            savedSend = try #require(object["send_enabled"] as? Bool)
            if request.url?.path.hasSuffix("/resume") == true || request.url?.path.hasSuffix("/resume-from-now") == true { savedPaused = false }
        }
        savedVersion += 1
        if loseSavedMutation { return (Data(), 503) }
        return (try savedReadback(), 200)
    }
    private func savedReadback() throws -> Data {
        let data = try nativeSavedReadbackData(version: String(savedVersion), paused: savedPaused, read: savedRead, send: savedSend, gaps: savedGaps)
        let decodedRoot = try JSONSerialization.jsonObject(with: data)
        var root = try #require(decodedRoot as? [String: Any])
        var config = try #require(root["config"] as? [String: Any])
        config["installation_id"] = savedInstallationID
        var status = try #require(config["status"] as? [String: Any])
        status["state"] = savedPaused ? "paused" : observedState
        status["receive_state"] = observedReceiveState
        config["status"] = status
        if extraUnavailableConversation {
            var rows = try #require(config["conversations"] as? [[String: Any]])
            rows.append(["conversation_id": "other", "label": "Unavailable saved conversation", "participants": [], "is_group": false, "service": "imessage", "available": false])
            config["conversations"] = rows
        }
        root["config"] = config
        return try coordinatorJSON(root)
    }
    private func humanPrepared(_ request: URLRequest) throws -> (Data, Int) {
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let input = try #require(decoded as? [String: Any])
        #expect(input["expected_config_version"] as? Int64 == savedVersion)
        let send = input["action"] as? String == "test_send"
        let text = input["text"] as? String ?? ""
        let command = IMessageGatewayCommand(requestID: "native-human", authorizationID: "native-grant",
            deadlineAt: coordinatorUTC(coordinatorNow.addingTimeInterval(send ? 45 : 10)),
            target: .init(installationID: "mac", workspaceID: workspace, snapshotRevision: 1, configID: "saved", configVersion: savedVersion,
                accountGeneration: "native-account-epoch", sourceGeneration: "native-source"),
            caller: .init(humanAction: .init(userID: "human", action: send ? .testSend : .check,
                conversationID: send ? "selected" : nil, textSHA256: send ? IMessageSetupProvider.messageTextDigest(text) : nil)),
            input: .configured(send ? .sendMessage(.init(integrationID: "saved", conversationID: "selected",
                clientRequestID: input["client_request_id"] as? String ?? "", text: text)) : .status(.init(integrationID: "saved"))),
            sendAttemptID: send ? "native-attempt" : nil)
        struct Prepared: Encodable { let command: IMessageGatewayCommand }
        return (try JSONEncoder().encode(Prepared(command: command)), 200)
    }
    private func humanRedeemed(_ request: URLRequest) throws -> (Data, Int) {
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "A", count: 43))
        let body = try #require(request.httpBody)
        let value = try IMessageConfiguredGatewayValidation.decode(IMessageGatewayNativeCommandRequest.self, from: body)
        if case .configured(.sendMessage(let input)) = value.command.input {
            return (try coordinatorJSON(["send_message": ["conversation_id": input.conversationID, "client_request_id": input.clientRequestID,
                "message_id": "local-record", "outcome": "local_record_confirmed", "confirmed_at": coordinatorUTC(coordinatorNow)]]), 200)
        }
        return (try coordinatorJSON(["status": ["integration_id": "saved", "state": "connected", "receive_state": "disabled",
            "read_enabled": savedRead, "send_enabled": savedSend, "receive_enabled": false, "pending_count": 0, "continuity_gap_conversation_ids": []]]), 200)
    }
    private func bootstrap() throws -> Data {
        let active = bootstrapMismatch ? "personal" : workspace
        return try coordinatorJSON(["authenticated": true, "natural_user": ["id": "human", "role": "user"],
            "effective_user": ["id": "human", "role": "user", "display_name": "Human", "email": "", "avatar_url": "", "time_zone": ""],
            "impersonation_active": false, "session_expires_at": coordinatorUTC(coordinatorNow.addingTimeInterval(7200)),
            "workspaces": [["id": active, "display_name": "Team workspace", "status": "active", "organization_id": "org", "organization_name": "Team", "personal": false, "workspace_admin": false]],
            "active_workspace_id": active, "no_accessible_workspace": false, "csrf_token": "private-csrf"])
    }
    private func verification(_ request: URLRequest) async throws -> Data {
        let body = try #require(request.httpBody)
        try IMessageJSONDocument.validate(data: body, maximumBytes: 16384)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(Set(object.keys) == ["setup_reference", "generation", "enrollment_ticket", "operation", "input"])
        if object["operation"] as? String == "imessage_prerequisites", let runtime = savedRuntime {
            await runtime.bind(connectionID: savedConnection)
            let scope = IMessageGatewayConfigScope(configID: "saved", workspaceID: workspace, configVersion: savedVersion,
                accountGeneration: "epoch", sourceGeneration: "native-source", accountID: "native-account", conversationIDs: extraUnavailableConversation ? ["selected", "other"] : ["selected"],
                conversationBindings: [.init(conversationID: "selected", nativeChatID: try IMessageRowID(1), nativeChatGUID: "native-guid")] +
                    (extraUnavailableConversation ? [.init(conversationID: "other", nativeChatID: try IMessageRowID(2), nativeChatGUID: "other-guid")] : []),
                readEnabled: savedRead, sendEnabled: savedSend, paused: savedPaused)
            let setup = IMessageGatewaySetupScope(setupReferenceSHA256: IMessageSetupProvider.setupReferenceDigest(reference), generation: 1,
                workspaceID: workspace, userID: "human", expiresAt: coordinatorUTC(coordinatorNow.addingTimeInterval(3600)), enabled: true)
            #expect(await runtime.install(.init(installationID: "mac", revision: 1, configs: [scope], setupScope: setup), connectionID: savedConnection) == .snapshotAck(.init(revision: 1)))
            return try coordinatorJSON(["setup_reference": reference, "generation": 1, "operation": "imessage_prerequisites",
                "result": ["prerequisites": ["database_ready": true]]])
        }
        if realMetadata { return try await admittedMetadata(object) }
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
    private func admittedMetadata(_ object: [String: Any]) async throws -> Data {
        guard let runtime = savedRuntime, let operation = object["operation"] as? String,
              let input = object["input"] as? [String: Any] else { throw IMessageHostedSetupError.invalidRequest }
        let commandInput: IMessageGatewayCommandInput
        if operation == "imessage_setup_conversations", let page = input["setup_conversations"] as? [String: Any] {
            commandInput = .setupConversations(.init(query: page["query"] as? String ?? "", snapshotToken: page["snapshot_token"] as? String,
                pageToken: page["page_token"] as? String, limit: page["limit"] as? Int ?? 50))
        } else if operation == "imessage_verify_conversations", let selected = input["verify_conversations"] as? [String: Any],
                  let ids = selected["conversation_ids"] as? [String] {
            commandInput = .verifyConversations(.init(conversationIDs: ids))
        } else { throw IMessageHostedSetupError.invalidRequest }
        let id = UUID().uuidString.lowercased()
        let command = IMessageGatewayCommand(requestID: id, authorizationID: "grant-" + id,
            deadlineAt: coordinatorUTC(coordinatorNow.addingTimeInterval(10)), target: .init(installationID: "mac", workspaceID: workspace, snapshotRevision: 1),
            caller: .init(setupSession: .init(userID: "human", setupReference: reference, setupGeneration: 1)), input: commandInput)
        let box = IMessageCoordinatorRuntimeReply()
        let rejected = await runtime.admit(command, connectionID: savedConnection) { await box.put($0) }
        let payload: IMessageGatewayPayload
        if let rejected { payload = .failure(rejected) } else { payload = try await box.wait() }
        let result: [String: Any]
        switch payload {
        case .result(.conversationsPage(let page)):
            var body: [String: Any] = ["snapshot_token": page.snapshotToken, "has_more": page.hasMore, "stop_reason": page.stopReason.rawValue,
                "conversations": page.conversations.map { row -> [String: Any] in ["conversation_id": row.conversationID, "label": row.metadata.name, "is_group": row.metadata.isGroup,
                    "participant_count": row.metadata.participants.count, "available": row.metadata.available] }]
            body["next_page_token"] = page.nextPageToken
            result = ["conversations_page": body]
        case .result(.verification(let verification)):
            result = ["verification": ["verified": verification.liveAccount != nil, "conversations": verification.conversations.map { row -> [String: Any] in
                ["conversation_id": row.conversationID, "label": row.metadata.name, "is_group": row.metadata.isGroup,
                 "participant_count": row.metadata.participants.count, "available": row.metadata.available]
            }]]
        default: throw IMessageHostedSetupError.scopeChanged
        }
        return try coordinatorJSON(["setup_reference": reference, "generation": 1, "operation": operation, "result": result])
    }
}

private actor IMessageCoordinatorRuntimeReply {
    private var value: IMessageGatewayPayload?
    func put(_ value: IMessageGatewayPayload) { self.value = value }
    func wait() async throws -> IMessageGatewayPayload {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while value == nil, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        guard let value else { throw IMessageSetupCoordinatorError.unavailable }
        return value
    }
}

private actor IMessageCoordinatorProvider: IMessageSetupProviding {
    private(set) var restores = 0
    private(set) var stops = 0
    private var replaced = false
    private(set) var inventoryReads = 0
    func replaceAccount() { replaced = true }
    func prerequisites(deadline: Date) throws -> IMessageGatewayPrerequisitesResult { throw IMessageSetupProviderError.dependencyInvalid }
    func conversations(after: IMessageRowID, upper: IMessageRowID?, query: String, limit: Int, deadline: Date) throws -> IMessageSetupProviderPage {
        guard replaced else { throw IMessageSetupProviderError.dependencyInvalid }
        inventoryReads += 1
        let data = try coordinatorJSON(["chats": [["id": "9", "guid": "replacement-guid", "name": "New conversation", "service": "iMessage", "is_group": false,
            "available": true, "participants": ["replacement"]]], "next_chat_rowid": "9", "upper_chat_rowid": "9", "has_more": false, "stop_reason": "caught_up"])
        return .init(page: try JSONDecoder().decode(IMessageConversationPage.self, from: data), account: .init(accountID: "replacement-account", sourceGeneration: "replacement-source"))
    }
    func verify(conversations: [IMessageConversation], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification {
        guard replaced, account == .init(accountID: "replacement-account", sourceGeneration: "replacement-source") else { throw IMessageSetupProviderError.accountChanged }
        return .init(conversations: conversations, liveAccount: .init(accountID: account.accountID, sourceGeneration: account.sourceGeneration, chatGUIDs: conversations.map(\.guid)))
    }
    func restore(selections: [IMessageSetupDraft.Selection], account: IMessageSetupAccount, deadline: Date) throws -> IMessageSetupProviderVerification {
        restores += 1
        if replaced { throw IMessageSetupProviderError.accountChanged }
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
    var expectedReviewGUIDs = ["native-guid"]
    var reviewRead = true
    var reviewSend = true
    var policyRefreshes = 0
    var policyGate: IMessageCoordinatorHumanGate?
    var humanReviews = 0
    var confirmHuman = true
    var humanGate: IMessageCoordinatorHumanGate?
    var physicalID = UUID()
    var sessionGeneration = UUID()
    var physicalAvailable = true
    var admitsOperations = true
    var requiresProviderRetry = false
    var providerRetries = 0
    var pageURL: URL?
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
        runtime = .init(installationID: "mac", provider: rowProvider, referenceDigest: IMessageSetupProvider.setupReferenceDigest,
            textDigest: IMessageSetupProvider.messageTextDigest, now: { coordinatorNow })
        let nativeProvider = IMessageSetupProvider(client: .init(transport: IMessageCoordinatorNeverTransport()))
        var deps = IMessageSetupManager.Dependencies()
        deps.configuration = { _ in config }; deps.currentConfiguration = { config }
        deps.admitsOperations = { [state] in state.admitsOperations }
        deps.nativeRegistration = { nil }
        deps.configuredMenuAvailability = { [state] in state.physicalAvailable ? .connected : .offline }
        deps.pageURL = { [state] _ in state.pageURL }
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
        deps.permissionState = { [state] _, _ in state.requiresProviderRetry ? .retryRequired : (state.permissionReady ? .ready : .fullDiskAccessRequired) }
        deps.retryProvider = { [state] _ in state.providerRetries += 1; state.requiresProviderRetry = false }
        deps.messagesAccess = { [state] _, _ in state.automationRequests += 1; state.permissionReady = true }
        deps.prepareBackground = { [state] _ in state.background = true }
        deps.backgroundReady = { [state] in state.background }
        deps.restart = { [state] _ in state.restartRequests += 1 }
        deps.refreshRelayPolicy = { [state] in
            state.policyRefreshes += 1
            if let gate = state.policyGate { state.policyGate = nil; await gate.pause() }
        }
        deps.captureHumanContext = { [state, store, runtime] in
            guard state.physicalAvailable else { throw IMessageHumanContextError.offline }
            let loaded = try store.load()
            let installed = try #require(loaded)
            return .init(session: .init(installation: installed, configuration: config, runtime: runtime, provider: nativeProvider),
                connectionID: state.physicalID, lifecycleGeneration: state.physicalID, sessionGeneration: state.sessionGeneration)
        }
        deps.validateHumanContext = { [state] context in
            guard state.physicalAvailable, context.connectionID == state.physicalID, context.sessionGeneration == state.sessionGeneration else {
                throw IMessageHumanContextError.changed
            }
        }
        deps.showReview = { [state] review, _ in
            state.reviews += 1
            #expect(review.workspaceName == "Team workspace" && review.macName == "Fixture Mac" && review.accountLabel == "Native Messages account")
            #expect(review.conversations.map(\.metadata.guid) == state.expectedReviewGUIDs)
            return state.acceptReview ? .init(readEnabled: state.reviewRead, sendEnabled: state.reviewSend) : nil
        }
        deps.accountLabel = { _, _ in "Native Messages account" }
        deps.showMetadataConsent = { [state] _ in state.metadataConsentRequests += 1; return state.metadataConsent }
        deps.showHumanReview = { [state] _, action, _ in
            state.humanReviews += 1
            await state.humanGate?.pause()
            guard state.confirmHuman else { return nil }
            return .init(conversationID: action == .check ? nil : "selected", text: action == .check ? nil : "exact private text")
        }
        deps.evidence = { _, consent, validate in
            #expect(try await validate(consent))
            let checkpoint = try IMessageSetupApprovalCheckpoint(sourceHighWater: IMessageRowID(1), observedAt: coordinatorUTC(coordinatorNow),
                chats: consent.conversations.map { try .init(chatID: $0.metadata.id, guid: $0.metadata.guid, tailRowID: IMessageRowID(1), tailGUID: "tail") })
            return try .init(verification: .init(conversations: consent.conversations, liveAccount: .init(accountID: consent.account.accountID,
                sourceGeneration: consent.account.sourceGeneration, chatGUIDs: consent.conversations.map(\.metadata.guid))), checkpoint: checkpoint,
                readEnabled: consent.readEnabled, sendEnabled: consent.sendEnabled)
        }
        deps.openMessages = { Issue.record("Unplanned Messages launch") }
        deps.openSettings = { [state] section in state.settingsOpened.append(section) }
        deps.openLoginItems = { Issue.record("Unplanned Login Items launch") }
        deps.navigate = { [state] url in state.navigations.append(url) }
        deps.synchronizeReference = { [state] _, reference in state.synchronizedReferences.append(reference) }
        let client = IMessageHostedSetupClient(transport: transport)
        dependencies = deps
        manager = .init(hosted: client, machine: .init(transport: transport), saved: .init(transport: transport), dependencies: deps)
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
        return try await manager.apply(IMessageSetupPageCommand.parse(body), view: view)
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
    func seedSaved(paused: Bool = false) async throws {
        try store.save(nativeSavedInstallation())
        await transport.enableSaved(runtime, paused: paused)
        await runtime.setConfiguredPolicy(enabled: true)
        preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(.production))
        preferences.set(paused, forKey: IMessagePreferenceKeys.relayPaused(.production))
    }
    func savedAction(_ action: String, scope: String, version: String = "7", key: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = ["version": "1", "action": action, "scope": scope, "config_id": "saved", "expected_config_version": version]
        body["client_request_id"] = key
        return try await manager.apply(IMessageSavedPageCommand.parse(body), view: view)
    }
    func prepareSavedSelection(_ action: String = "edit_connection", paused: Bool = false) async throws -> String {
        try await seedSaved(paused: paused)
        if action == "resume_from_now" { await transport.setSavedGaps(["selected"]) }
        let initial = try await apply("state")
        let scope = try #require(initial["scope"] as? String)
        let start = try await savedAction(action, scope: scope)
        #expect(start["integration_config_id"] as? String == "saved" && start["expected_config_version"] as? String == "7")
        _ = try await apply("continue", scope: scope)
        _ = try await apply("request_messages_access", scope: scope)
        _ = try await apply("enable_background", scope: scope)
        let choices = try await apply("allow_metadata", scope: scope)
        let ids = try #require(choices["selected_conversation_ids"] as? [String])
        #expect(ids.count == 1 && ids != ["selected"])
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
    try await coordinatorAwaitTransportEntry(fixture.transport, task: pending)
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
    try await coordinatorAwaitTransportEntry(fixture.transport, task: pending)
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
    let restored = try await relaunched.apply(IMessageSetupPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: view)
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
    try await coordinatorAwaitTransportEntry(fixture.transport, task: pending)
    fixture.manager.documentInvalidated(fixture.view)
    await fixture.transport.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(try fixture.store.loadPendingEnrollment() == old)
    #expect(fixture.state.synchronizedReferences.isEmpty && fixture.random.calls == 1)
    try await fixture.cleanup()
}


private actor IMessageCoordinatorHumanGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func pause() async {
        guard !released else { return }
        entered = true
        await withCheckedContinuation { waiting = $0 }
    }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard entered else { throw IMessageSetupCoordinatorError.unavailable }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

@Test(arguments: [(true, false), (false, true), (true, true), (false, false)]) @MainActor
func iMessageSetupManagerNativeCapabilityChoicesAreTheExactApprovedAndCreatedFlags(flags: (Bool, Bool)) async throws {
    let f = try IMessageCoordinatorFixture(restored: true)
    f.state.acceptReview = true; f.state.reviewRead = flags.0; f.state.reviewSend = flags.1
    let scope = try await f.prepareSelection()
    if !flags.0 && !flags.1 {
        await #expect(throws: IMessageSetupCoordinatorError.invalidRequest) { _ = try await f.apply("confirm", scope: scope) }
    } else { _ = try await f.apply("confirm", scope: scope) }
    let requests = await f.transport.requests
    let commits = requests.filter { ["/user/imessage/approve", "/user/imessage/configs"].contains($0.url?.path ?? "") }
    #expect(commits.count == ((flags.0 || flags.1) ? 2 : 0))
    for request in commits {
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(object["read_enabled"] as? Bool == flags.0 && object["send_enabled"] as? Bool == flags.1)
    }
    try await f.cleanup()
}

@Test(arguments: ["edit_connection", "resume_connection", "resume_from_now", "repair_connection"]) @MainActor
func iMessageSetupManagerSavedFlowsUseFreshScopeAndNeverCreateAnotherConfiguration(action: String) async throws {
    let f = try IMessageCoordinatorFixture()
    f.state.acceptReview = true
    let scope = try await f.prepareSavedSelection(action, paused: action == "resume_connection")
    let result = try await f.apply("confirm", scope: scope)
    #expect(result["state"] as? String == "assign_personas" && result["integration_config_id"] as? String == "saved")
    #expect(result["expected_config_version"] as? String == "7")
    let requests = await f.transport.requests
    #expect(!requests.contains { $0.url?.path == "/user/imessage/configs" })
    let suffix = action == "resume_connection" ? "/resume" : (action == "resume_from_now" ? "/resume-from-now" : "")
    #expect(requests.filter { $0.url?.path == "/user/imessage/configs/saved" + suffix && $0.httpMethod != "GET" }.count == 1)
    #expect(await f.provider.restores == 1)
    #expect(try f.store.loadSetupDraft() == nil)
    #expect(!String(describing: result).contains("native-guid") && !String(describing: result).contains("setup_receipt"))
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerSavedStaleVersionAndLostMutationNeverReplayOrFallThroughCreate() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    await #expect(throws: IMessageSetupCoordinatorError.scopeChanged) { _ = try await f.savedAction("edit_connection", scope: scope, version: "6") }
    #expect(await f.transport.mutations.isEmpty)
    try await f.cleanup()
    let g = try IMessageCoordinatorFixture()
    g.state.acceptReview = true
    let edit = try await g.prepareSavedSelection()
    await g.transport.loseSavedResponse()
    await #expect(throws: IMessageHostedSetupError.serviceUnavailable) { _ = try await g.apply("confirm", scope: edit) }
    await #expect(throws: IMessageSetupCoordinatorError.unavailable) { _ = try await g.apply("confirm", scope: edit) }
    let requests = await g.transport.requests
    #expect(requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    #expect(!requests.contains { $0.url?.path == "/user/imessage/configs" })
    try await g.cleanup()
}

@Test(arguments: ["confirm", "cancel", "offline"]) @MainActor
func iMessageSetupManagerHumanPreviewUsesNativeTextAndNeverPreparesAfterCancelOrOffline(mode: String) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    f.state.confirmHuman = mode != "cancel"; f.state.physicalAvailable = mode != "offline"
    let reply = try await f.savedAction("send_test", scope: scope, key: "opaque-key")
    #expect(reply["kind"] as? String == (mode == "cancel" ? "cancelled_before_prepare" : "send"))
    let requests = await f.transport.requests
    let prepares = requests.filter { $0.url?.path == "/user/imessage/configs/saved/test-send" }
    let redeems = requests.filter { $0.url?.path == "/v1/desktop-control/imessage/actions/redeem" }
    #expect(prepares.count == (mode == "confirm" ? 1 : 0) && redeems.count == prepares.count)
    if mode == "confirm" {
        #expect(reply["state"] as? String == "local_record_confirmed")
        let request = try #require(prepares.first)
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        #expect(object["text"] as? String == "exact private text" && object["conversation_id"] as? String == "selected")
    }
    #expect(!String(describing: reply).contains("exact private text") && !String(describing: reply).contains("native-guid"))
    #expect(await f.provider.restores == 0)
    try await f.cleanup()
}

@Test(arguments: ["physical", "document", "cookie", "session"]) @MainActor
func iMessageSetupManagerHeldHumanConfirmationCannotTransferToNewPhysicalOrDocumentContext(loss: String) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    let gate = IMessageCoordinatorHumanGate(); f.state.humanGate = gate
    let pending = Task { @MainActor in _ = try await f.savedAction("send_test", scope: scope, key: "opaque-key") }
    try await coordinatorAwaitHumanEntry(gate, transport: f.transport, task: pending)
    switch loss {
    case "physical": f.state.physicalID = UUID()
    case "document": f.manager.documentInvalidated(f.view)
    case "cookie": f.state.cookies = "ps_session=changed"
    default: f.state.sessionGeneration = UUID()
    }
    await gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(await f.transport.requests.allSatisfy { !["/user/imessage/configs/saved/test-send", "/v1/desktop-control/imessage/actions/redeem"].contains($0.url?.path ?? "") })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerAfterPossiblePrepareRetainsOpaqueKeyAndNeverRedeemsOnPhysicalLoss() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    await f.transport.hold("/user/imessage/configs/saved/test-send")
    let pending = Task { @MainActor in
        let reply = try await f.savedAction("send_test", scope: scope, key: "opaque-key")
        return (reply["kind"] as? String, reply["client_request_id"] as? String, reply["state"] as? String)
    }
    try await coordinatorAwaitTransportEntry(f.transport, task: pending)
    f.state.physicalID = UUID()
    await f.transport.release()
    let (kind, key, outcome) = try await pending.value
    #expect(kind == "send" && key == "opaque-key")
    #expect(outcome == "outcome_unknown")
    #expect(await f.transport.requests.filter { $0.url?.path == "/user/imessage/configs/saved/test-send" }.count == 1)
    #expect(await f.transport.requests.allSatisfy { $0.url?.path != "/v1/desktop-control/imessage/actions/redeem" })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerSavedLocatorDoesNotRestoreDraftAndExplicitInitialConnectCannotMutateSavedTarget() async throws {
    let f = try IMessageCoordinatorFixture()
    _ = try await f.prepareSavedSelection()
    f.manager.documentInvalidated(f.view); f.manager.documentCommitted(f.view)
    f.state.pageURL = URL(string: "https://my.personastack.ai/user/imessage?config_id=saved")
    let locator = try await f.apply("state")
    #expect(locator["state"] as? String == "idle" && locator["flow"] == nil)
    #expect(try f.store.loadSetupDraft()?.savedIntention?.configID == "saved")
    f.state.pageURL = URL(string: "https://my.personastack.ai/user/imessage")
    let initial = try await f.apply("state")
    #expect(initial["state"] as? String == "idle" && initial["integration_config_id"] == nil)
    #expect(await f.transport.requests.allSatisfy { $0.httpMethod != "PATCH" })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerFromNowRepairsOnlyCanonicalGapAndPreservesUnavailableUnrelatedSelection() async throws {
    let f = try IMessageCoordinatorFixture()
    await f.transport.includeUnavailableConversation()
    f.state.acceptReview = true
    let scope = try await f.prepareSavedSelection("resume_from_now")
    await #expect(throws: IMessageSetupCoordinatorError.invalidRequest) {
        _ = try await f.apply("list", scope: scope, extra: ["query": "foreign"])
    }
    await #expect(throws: IMessageSetupCoordinatorError.invalidRequest) {
        _ = try await f.apply("set_selected", scope: scope, extra: ["conversation_ids": ["other"]])
    }
    _ = try await f.apply("verify", scope: scope)
    let result = try await f.apply("confirm", scope: scope)
    #expect(result["integration_config_id"] as? String == "saved")
    let requests = await f.transport.requests
    let request = try #require(requests.first { $0.url?.path.hasSuffix("/resume-from-now") == true })
    let body = try #require(request.httpBody)
    let decoded = try JSONSerialization.jsonObject(with: body)
    let input = try #require(decoded as? [String: Any])
    #expect(input["conversation_ids"] as? [String] == ["selected", "other"])
    #expect(input["resume_conversation_ids"] as? [String] == ["selected"])
    #expect(await f.provider.restores == 1)
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerOfflineLocalPauseRecoversWithGetAndDoesNotReplayLostMutation() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    // A current local card read establishes the owner without granting execution.
    f.state.confirmHuman = false
    _ = try await f.savedAction("check_connection", scope: scope)
    await f.transport.makeSavedUnavailable()
    let pending = try await f.savedAction("pause_connection", scope: scope)
    #expect(pending["state"] as? String == "sync_pending")
    #expect(f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(.production)))
    await f.transport.setSavedAvailable(true)
    await f.transport.loseSavedResponse()
    _ = try await f.apply("state", scope: scope)
    let first = await f.transport.requests.filter { $0.url?.path.hasSuffix("/pause") == true }
    #expect(first.count == 1)
    _ = try await f.apply("state", scope: scope)
    #expect(await f.transport.requests.filter { $0.url?.path.hasSuffix("/pause") == true }.count == 1)
    #expect(f.manager.menuState == .paused)
    let replacement = IMessageSetupManager(hosted: .init(transport: f.transport), machine: .init(transport: f.transport),
        saved: .init(transport: f.transport), dependencies: f.dependencies)
    #expect(replacement.menuState == .paused)
    await replacement.shutdown()
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerResumeBeforePauseAckSupersedesOldCallbackAndUsesFreshActiveCanonicalConfig() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    f.state.confirmHuman = false
    _ = try await f.savedAction("check_connection", scope: scope)
    await f.transport.hold("/user/imessage/configs/saved/pause")
    let oldPause = Task { @MainActor in _ = try await f.savedAction("pause_connection", scope: scope) }
    try await coordinatorAwaitTransportEntry(f.transport, task: oldPause)
    await f.manager.resume() // Synchronously supersedes the pending generation.
    await f.transport.release()
    _ = try await oldPause.value
    let ack = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: DesktopEnvironmentConfiguration.production.preferenceIdentity)
    #expect(!f.preferences.bool(forKey: ack))
    #expect(f.manager.menuState == .resumePending)
    // A lost/unaccepted cloud Pause may leave the canonical config active. A
    // separately authorized Resume still performs one fresh native review.
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerHiddenDocumentFencesHumanIntentWithoutStoppingConfiguredActor() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    let gate = IMessageCoordinatorHumanGate(); f.state.humanGate = gate
    let request = Task { @MainActor in _ = try await f.savedAction("send_test", scope: scope, key: "retained-key") }
    try await coordinatorAwaitHumanEntry(gate, transport: f.transport, task: request)
    f.manager.documentInvalidated(f.view)
    await gate.release()
    await #expect(throws: (any Error).self) { try await request.value }
    #expect(f.preferences.bool(forKey: IMessagePreferenceKeys.relayEnabled(.production)))
    let diagnostics = await f.runtime.diagnostics()
    #expect(!diagnostics.activeCommand && diagnostics.waitingCommands == 0)
    #expect(await f.transport.requests.allSatisfy { !$0.url!.path.hasSuffix("/test-send") })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerFreshResumeBeforeUnacknowledgedPauseDoesNotRequireCloudPauseFirst() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    var initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    f.state.confirmHuman = false
    _ = try await f.savedAction("check_connection", scope: scope)
    await f.transport.makeSavedUnavailable()
    let local = try await f.savedAction("pause_connection", scope: scope)
    #expect(local["state"] as? String == "sync_pending")
    await f.transport.setSavedAvailable(true)
    initial = try await f.savedAction("resume_connection", scope: scope)
    #expect(initial["flow"] as? String == "resume")
    _ = try await f.apply("continue", scope: scope)
    _ = try await f.apply("request_messages_access", scope: scope)
    _ = try await f.apply("enable_background", scope: scope)
    _ = try await f.apply("allow_metadata", scope: scope)
    _ = try await f.apply("verify", scope: scope)
    f.state.acceptReview = true
    _ = try await f.apply("confirm", scope: scope)
    #expect(!f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(.production)))
    let requests = await f.transport.requests
    #expect(requests.filter { $0.url?.path.hasSuffix("/resume") == true }.count == 1)
    #expect(requests.allSatisfy { $0.url?.path.hasSuffix("/pause") != true })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerOnlyExplicitRetryResetsProviderAndWithdrawsOldSelectionWithoutReplay() async throws {
    let f = try IMessageCoordinatorFixture(restored: true)
    let scope = try await f.prepareSelection()
    f.state.requiresProviderRetry = true
    for _ in 0..<2 {
        let passive = try await f.apply("check_permissions", scope: scope)
        #expect(passive["next_action"] as? String == "retry_provider")
    }
    #expect(f.state.providerRetries == 0)
    let retry = try await f.apply("retry_provider", scope: scope)
    #expect(f.state.providerRetries == 1)
    #expect(retry["next_action"] as? String == "enable_background")
    #expect(retry["selected_count"] as? Int == 0)
    await #expect(throws: IMessageSetupCoordinatorError.scopeChanged) { _ = try await f.apply("verify", scope: scope) }
    #expect(await f.transport.mutations.allSatisfy { !["/user/imessage/approve", "/user/imessage/configs"].contains($0) })
    try await f.cleanup()
}

@Test @MainActor func iMessageSetupManagerPendingPauseCannotMoveToDifferentCurrentWorkspace() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    f.state.confirmHuman = false
    _ = try await f.savedAction("check_connection", scope: scope)
    await f.transport.makeSavedUnavailable()
    _ = try await f.savedAction("pause_connection", scope: scope)
    await f.transport.setSavedAvailable(true)
    let protectedReads = await f.transport.requests.filter { $0.url?.path == "/user/imessage/configs/saved" }.count
    await f.transport.selectWorkspace("different")
    await #expect(throws: (any Error).self) { _ = try await f.apply("state", scope: scope) }
    _ = try await f.apply("state")
    #expect(await f.transport.requests.filter { $0.url?.path == "/user/imessage/configs/saved" }.count == protectedReads)
    #expect(await f.transport.requests.allSatisfy { $0.url?.path.hasSuffix("/pause") != true })
    #expect(f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(.production)))
    #expect(f.manager.menuState == .syncPending)
    try await f.cleanup()
}


@MainActor private func coordinatorAwaitTransportEntry<T: Sendable>(_ transport: IMessageCoordinatorTransport, task: Task<T, Error>) async throws {
    do { try await transport.waitUntilHeld() }
    catch {
        await transport.release()
        _ = try? await task.value
        throw error
    }
}

@MainActor private func coordinatorAwaitHumanEntry<T: Sendable>(_ gate: IMessageCoordinatorHumanGate, transport: IMessageCoordinatorTransport,
                                                              task: Task<T, Error>) async throws {
    do { try await gate.wait() }
    catch {
        await gate.release()
        await transport.release()
        _ = try? await task.value
        throw error
    }
}

@Test(arguments: ["edit_connection", "resume_connection", "resume_from_now", "repair_connection"], [false, true]) @MainActor
func iMessageSavedCancellationPreservesImmutableTargetAcrossDirectContinuationAndRestart(action: String, startAgain: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    f.state.acceptReview = true
    let originalScope = try await f.prepareSavedSelection(action)
    let cancelled = try await f.apply("cancel", scope: originalScope)
    let scope = try #require(cancelled["scope"] as? String)
    #expect(cancelled["integration_config_id"] as? String == "saved")
    #expect(cancelled["expected_config_version"] as? String == "7")
    if startAgain {
        let restarted = try await f.apply("start_again", scope: scope)
        #expect(restarted["integration_config_id"] as? String == "saved")
        #expect(restarted["expected_config_version"] as? String == "7")
    }
    let continued = try await f.apply("continue", scope: scope)
    #expect(continued["integration_config_id"] as? String == "saved")
    #expect(continued["expected_config_version"] as? String == "7")
    _ = try await f.apply("request_messages_access", scope: scope)
    _ = try await f.apply("enable_background", scope: scope)
    let selection = try await f.apply("allow_metadata", scope: scope)
    #expect(selection["flow"] as? String == (action == "edit_connection" ? "edit" : (action == "resume_connection" ? "resume" : (action == "resume_from_now" ? "resume_from_now" : "repair"))))
    _ = try await f.apply("verify", scope: scope)
    let draft = try f.store.loadSetupDraft()
    #expect(draft?.savedIntention?.configID == "saved" && draft?.savedIntention?.expectedConfigVersion == 7)
    let completed = try await f.apply("confirm", scope: scope)
    #expect(completed["integration_config_id"] as? String == "saved")
    #expect(completed["expected_config_version"] as? String == "7")
    #expect(await f.transport.requests.allSatisfy { $0.url?.path != "/user/imessage/configs" })
    try await f.cleanup()
}

@Test(arguments: [false, true]) @MainActor
func iMessageChangedSavedSourceRequiresFreshExecutableNativeConsentAndNeverTurnsFromNowIntoReplacement(fromNow: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    await f.transport.useRealRuntimeMetadata()
    if fromNow { await f.transport.setSavedGaps(["selected"]) }
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    _ = try await f.savedAction(fromNow ? "resume_from_now" : "repair_connection", scope: scope)
    _ = try await f.apply("continue", scope: scope)
    _ = try await f.apply("request_messages_access", scope: scope)
    _ = try await f.apply("enable_background", scope: scope)
    await f.provider.replaceAccount()
    var changed = try await f.apply("allow_metadata", scope: scope)
    #expect(changed["integration_config_id"] as? String == "saved" && changed["expected_config_version"] as? String == "7")
    let readyForExplicitRepair = fromNow
        ? (changed["state"] as? String == "needs_attention" && changed["reason_code"] as? String == "selection_unavailable" && changed["next_action"] as? String != "list")
        : changed["next_action"] as? String == "allow_metadata"
    #expect(readyForExplicitRepair)
    guard readyForExplicitRepair else {
        // RED must prove the real Core actor revoked consent. A transport fake
        // returning a page directly would miss this exact failure.
        await #expect(throws: IMessageHostedSetupError.scopeChanged) { _ = try await f.apply("list", scope: scope, extra: ["query": ""]) }
        #expect(await f.provider.inventoryReads == 0)
        try await f.cleanup()
        return
    }
    if fromNow {
        await #expect(throws: (any Error).self) { _ = try await f.apply("list", scope: scope, extra: ["query": ""]) }
        await #expect(throws: (any Error).self) { _ = try await f.apply("allow_metadata", scope: scope) }
        #expect(await f.transport.requests.allSatisfy { $0.url?.path.hasSuffix("/resume-from-now") != true })
        let previousReference = try #require(changed["setup_reference"] as? String)
        let repair = try await f.savedAction("repair_connection", scope: scope)
        #expect(repair["setup_reference"] as? String != previousReference)
        #expect(repair["flow"] as? String == "repair" && repair["expected_config_version"] as? String == "7")
        let replacementDraft = try f.store.loadSetupDraft()
        #expect(replacementDraft?.savedIntention?.action == .repair)
        #expect(replacementDraft?.savedIntention?.configID == "saved" && replacementDraft?.savedIntention?.expectedConfigVersion == 7)
        _ = try await f.apply("continue", scope: scope)
        _ = try await f.apply("request_messages_access", scope: scope)
        _ = try await f.apply("enable_background", scope: scope)
        changed = try await f.apply("allow_metadata", scope: scope)
        #expect(changed["next_action"] as? String == "allow_metadata")
    }
    let consents = f.state.metadataConsentRequests
    let fresh = try await f.apply("allow_metadata", scope: scope)
    #expect(f.state.metadataConsentRequests == consents + 1)
    #expect(fresh["next_action"] as? String == "list")
    let listed = try await f.apply("list", scope: scope, extra: ["query": ""])
    let page = try #require(listed["conversations_page"] as? [String: Any])
    let rows = try #require(page["conversations"] as? [[String: Any]])
    let id = try #require(rows.first?["conversation_id"] as? String)
    _ = try await f.apply("set_selected", scope: scope, extra: ["conversation_ids": [id]])
    let verified = try await f.apply("verify", scope: scope)
    #expect(verified["verification_ready"] as? Bool == true)
    let draft = try f.store.loadSetupDraft()
    #expect(draft?.expectedAccountID == "replacement-account" && draft?.sourceGeneration == "replacement-source")
    #expect(draft?.selectedConversations.map(\.expectedGUID) == ["replacement-guid"])
    #expect(draft?.savedIntention?.configID == "saved" && draft?.savedIntention?.expectedConfigVersion == 7)
    f.state.acceptReview = true; f.state.expectedReviewGUIDs = ["replacement-guid"]
    let completed = try await f.apply("confirm", scope: scope)
    #expect(completed["integration_config_id"] as? String == "saved")
    #expect(await f.transport.requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    #expect(await f.transport.requests.allSatisfy { $0.url?.path != "/user/imessage/configs" })
    #expect(await f.provider.inventoryReads == 1)
    try await f.cleanup()
}

@MainActor private func coordinatorObservedMenu(_ manager: IMessageSetupManager, state: IMessageMenuState) async -> Bool {
    let until = ContinuousClock.now.advanced(by: .milliseconds(500))
    while manager.menuState != state, ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(5)) }
    return manager.menuState == state
}

@Test @MainActor func iMessageConfiguredMenuFollowsCurrentAuthorityAndAvailabilityWithoutOpeningSetup() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let locator = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: DesktopEnvironmentConfiguration.production.preferenceIdentity)
    f.preferences.set("saved", forKey: locator)
    f.state.pageURL = URL(string: "https://my.personastack.ai/user")
    let manager = IMessageSetupManager(hosted: .init(transport: f.transport), machine: .init(transport: f.transport),
        saved: .init(transport: f.transport), dependencies: f.dependencies)
    manager.register(f.view, appURL: DesktopEnvironmentConfiguration.production.appURL)
    manager.documentCommitted(f.view)
    manager.recoverPendingPause(f.view) // Existing app recovery callback.
    #expect(await coordinatorObservedMenu(manager, state: .connected))
    #expect(!manager.menuState.offersResume)
    f.state.physicalAvailable = false
    manager.recoverPendingPause(f.view)
    #expect(await coordinatorObservedMenu(manager, state: .offline))
    #expect(manager.canPauseMessages)
    f.state.physicalAvailable = true
    manager.recoverPendingPause(f.view)
    #expect(await coordinatorObservedMenu(manager, state: .connected))
    await f.transport.setObservedStatus("needs_attention")
    manager.recoverPendingPause(f.view)
    #expect(await coordinatorObservedMenu(manager, state: .needsAttention))
    await f.transport.setObservedStatus("connected", receive: "pending")
    manager.recoverPendingPause(f.view)
    #expect(await coordinatorObservedMenu(manager, state: .resumePending))
    #expect(f.state.navigations.isEmpty && f.state.metadataConsentRequests == 0 && f.state.humanReviews == 0)
    await manager.pause()
    #expect(!manager.canPauseMessages)
    #expect(f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(.production)))
    manager.recoverPendingPause(f.view)
    #expect(manager.menuState == .paused || manager.menuState == .syncPending)
    #expect(await f.transport.requests.allSatisfy { !$0.url!.path.hasSuffix("/test-send") })
    await manager.shutdown()
    try await f.cleanup()
}

@MainActor private func coordinatorAwaitMenuPauseHold(_ stage: String, gate: IMessageCoordinatorHumanGate,
                                                     transport: IMessageCoordinatorTransport, task: Task<Void, Never>) async throws {
    do {
        if stage == "refresh" { try await gate.wait() }
        else { try await transport.waitUntilHeld() }
    } catch {
        await gate.release(); await transport.release(); await task.value
        throw error
    }
}

@Test(arguments: ["refresh", "saved_get"], [false, true]) @MainActor
func iMessageMenuPauseCannotSupersedeNewerResumeDuringRefreshOrSavedRead(stage: String, boundOwner: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let config = DesktopEnvironmentConfiguration.production
    let locatorKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: config.preferenceIdentity)
    let ownerKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigOwner", appOrigin: config.preferenceIdentity)
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let ackKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: config.preferenceIdentity)
    f.preferences.set("saved", forKey: locatorKey)
    if boundOwner {
        let owner = try IMessageLocalPauseIntent(installationID: "mac", configID: "saved", naturalUserID: "human", workspaceID: "workspace")
        f.preferences.set(owner.preferences, forKey: ownerKey)
    }
    f.state.physicalAvailable = false
    f.state.pageURL = URL(string: "https://my.personastack.ai/user/imessage?config_id=saved")
    let manager = IMessageSetupManager(hosted: .init(transport: f.transport), machine: .init(transport: f.transport),
        saved: .init(transport: f.transport), dependencies: f.dependencies)
    manager.register(f.view, appURL: config.appURL)
    // Install the visible fake document without scheduling unrelated automatic observation.
    f.state.admitsOperations = false; manager.documentCommitted(f.view); f.state.admitsOperations = true
    _ = try await manager.apply(IMessageSetupPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: f.view)
    #expect(manager.menuState == .offline && manager.canPauseMessages)
    let gate = IMessageCoordinatorHumanGate()
    if stage == "refresh" { f.state.policyGate = gate }
    else { await f.transport.holdOnce("/user/imessage/configs/saved") }
    let oldPause = Task { await manager.pause() }
    try await coordinatorAwaitMenuPauseHold(stage, gate: gate, transport: f.transport, task: oldPause)
    let capturedValue = try #require(f.preferences.object(forKey: pauseKey))
    let captured = try IMessageLocalPauseIntent.parse(capturedValue)
    #expect(captured.naturalUserID == (boundOwner ? "human" : nil))
    await manager.resume()
    let newer = try await manager.apply(IMessageSetupPageCommand.parse(["version": "1", "action": "state", "scope": ""]), view: f.view)
    let newerScope = try #require(newer["scope"] as? String)
    let newerReference = try #require(newer["setup_reference"] as? String)
    let newerDraft = try f.store.loadSetupDraft()
    let mutationsBeforeRelease = await f.transport.mutations
    let navigationsBeforeRelease = f.state.navigations.count
    #expect(newerDraft?.setupReference == newerReference && newerDraft?.savedIntention?.action == .resume)
    #expect(manager.menuState == .resumePending && f.preferences.object(forKey: pauseKey) == nil)
    await gate.release(); await f.transport.release(); await oldPause.value
    #expect(manager.menuState == .resumePending)
    #expect(f.preferences.object(forKey: pauseKey) == nil)
    #expect(!f.preferences.bool(forKey: ackKey))
    #expect(await f.transport.mutations == mutationsBeforeRelease)
    #expect(await f.transport.requests.allSatisfy { $0.url?.path.hasSuffix("/pause") != true })
    #expect(f.state.navigations.count == navigationsBeforeRelease)
    #expect(try f.store.loadSetupDraft() == newerDraft)
    // A stale shutdown would retire this exact newer document scope.
    let retained = try? await manager.apply(IMessageSetupPageCommand.parse(["version": "1", "action": "state", "scope": newerScope]), view: f.view)
    let retainedReference: String? = retained?["setup_reference"] as? String
    let retainedScope: String? = retained?["scope"] as? String
    #expect(retainedReference == newerReference)
    #expect(retainedScope == newerScope)
    #expect(manager.menuState == .resumePending && f.preferences.object(forKey: pauseKey) == nil)
    await manager.shutdown()
    try await f.cleanup()
}

@Test(arguments: [false, true]) @MainActor
func iMessageMenuPauseBindsOnlyItsOriginalCurrentIntention(boundOwner: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let config = DesktopEnvironmentConfiguration.production
    let locatorKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: config.preferenceIdentity)
    let ownerKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigOwner", appOrigin: config.preferenceIdentity)
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let ackKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: config.preferenceIdentity)
    f.preferences.set("saved", forKey: locatorKey)
    if boundOwner {
        let owner = try IMessageLocalPauseIntent(installationID: "mac", configID: "saved", naturalUserID: "human", workspaceID: "workspace")
        f.preferences.set(owner.preferences, forKey: ownerKey)
    }
    f.state.physicalAvailable = false
    f.state.pageURL = URL(string: "https://my.personastack.ai/user/imessage?config_id=saved")
    let manager = IMessageSetupManager(hosted: .init(transport: f.transport), machine: .init(transport: f.transport),
        saved: .init(transport: f.transport), dependencies: f.dependencies)
    manager.register(f.view, appURL: config.appURL)
    f.state.admitsOperations = false; manager.documentCommitted(f.view); f.state.admitsOperations = true
    await f.transport.holdOnce("/user/imessage/configs/saved")
    let pause = Task { await manager.pause() }
    try await coordinatorAwaitMenuPauseHold("saved_get", gate: IMessageCoordinatorHumanGate(), transport: f.transport, task: pause)
    let capturedValue = try #require(f.preferences.object(forKey: pauseKey))
    let captured = try IMessageLocalPauseIntent.parse(capturedValue)
    await f.transport.release(); await pause.value
    let currentValue = try #require(f.preferences.object(forKey: pauseKey))
    let current = try IMessageLocalPauseIntent.parse(currentValue)
    #expect(current.generation == captured.generation)
    #expect(current.installationID == "mac" && current.configID == "saved")
    #expect(current.naturalUserID == "human" && current.workspaceID == "workspace")
    #expect(f.preferences.bool(forKey: ackKey) && manager.menuState == .paused)
    let posts = await f.transport.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/pause") == true }
    #expect(posts.count == 1)
    await manager.shutdown()
    try await f.cleanup()
}

@Test(arguments: ["canonical_get", "second_refresh"], [false, true]) @MainActor
func iMessageSavedPauseCannotSupersedeResumeDuringCanonicalReadOrSecondRefresh(stage: String, boundOwner: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let config = DesktopEnvironmentConfiguration.production
    let locatorKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: config.preferenceIdentity)
    let ownerKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigOwner", appOrigin: config.preferenceIdentity)
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let ackKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: config.preferenceIdentity)
    f.preferences.set("saved", forKey: locatorKey)
    if boundOwner {
        let owner = try IMessageLocalPauseIntent(installationID: "mac", configID: "saved", naturalUserID: "human", workspaceID: "workspace")
        f.preferences.set(owner.preferences, forKey: ownerKey)
    }
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    let firstRefresh = IMessageCoordinatorHumanGate(), secondRefresh = IMessageCoordinatorHumanGate()
    f.state.policyGate = firstRefresh
    let oldPause = Task { @MainActor in _ = try await f.savedAction("pause_connection", scope: scope) }
    try await coordinatorAwaitHumanEntry(firstRefresh, transport: f.transport, task: oldPause)
    let capturedValue = try #require(f.preferences.object(forKey: pauseKey))
    let captured = try IMessageLocalPauseIntent.parse(capturedValue)
    if stage == "canonical_get" { await f.transport.holdOnce("/user/imessage/configs/saved") }
    else { f.state.policyGate = secondRefresh }
    await firstRefresh.release()
    if stage == "canonical_get" { try await coordinatorAwaitTransportEntry(f.transport, task: oldPause) }
    else { try await coordinatorAwaitHumanEntry(secondRefresh, transport: f.transport, task: oldPause) }
    let heldValue = try #require(f.preferences.object(forKey: pauseKey))
    let held = try IMessageLocalPauseIntent.parse(heldValue)
    #expect(held.generation == captured.generation)
    let mutationsBeforeResume = await f.transport.mutations
    await f.manager.resume()
    if stage == "second_refresh" { f.manager.documentInvalidated(f.view) }
    #expect(f.manager.menuState == .resumePending && f.preferences.object(forKey: pauseKey) == nil)
    await secondRefresh.release(); await f.transport.release()
    _ = try? await oldPause.value
    #expect(f.manager.menuState == .resumePending)
    #expect(f.preferences.object(forKey: pauseKey) == nil)
    #expect(!f.preferences.bool(forKey: ackKey))
    #expect(await f.transport.mutations == mutationsBeforeResume)
    #expect(await f.transport.requests.allSatisfy { $0.url?.path.hasSuffix("/pause") != true })
    if stage == "canonical_get" {
        // Resume has started navigation, but no provisional callback has retired this document yet.
        let continued = try? await f.apply("state", scope: scope)
        let retainedScope: String? = continued?["scope"] as? String
        #expect(retainedScope == scope)
        #expect(f.manager.menuState == .resumePending && f.preferences.object(forKey: pauseKey) == nil)
    }
    try await f.cleanup()
}

@Test(arguments: [false, true]) @MainActor
func iMessageSavedPauseKeepsOriginalRecordThroughCanonicalOwnerBinding(boundOwner: Bool) async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let config = DesktopEnvironmentConfiguration.production
    let locatorKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigLocator", appOrigin: config.preferenceIdentity)
    let ownerKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageSavedConfigOwner", appOrigin: config.preferenceIdentity)
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let ackKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: config.preferenceIdentity)
    f.preferences.set("saved", forKey: locatorKey)
    if boundOwner {
        let owner = try IMessageLocalPauseIntent(installationID: "mac", configID: "saved", naturalUserID: "human", workspaceID: "workspace")
        f.preferences.set(owner.preferences, forKey: ownerKey)
    }
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    let gate = IMessageCoordinatorHumanGate()
    f.state.policyGate = gate
    let pause = Task { @MainActor in _ = try await f.savedAction("pause_connection", scope: scope) }
    try await coordinatorAwaitHumanEntry(gate, transport: f.transport, task: pause)
    let originalValue = try #require(f.preferences.object(forKey: pauseKey))
    let original = try IMessageLocalPauseIntent.parse(originalValue)
    await gate.release(); try await pause.value
    let currentValue = try #require(f.preferences.object(forKey: pauseKey))
    let current = try IMessageLocalPauseIntent.parse(currentValue)
    #expect(current.generation == original.generation)
    #expect(current.configID == "saved" && current.installationID == "mac")
    #expect(current.naturalUserID == "human" && current.workspaceID == "workspace")
    #expect(f.preferences.bool(forKey: ackKey) && f.manager.menuState == .paused)
    #expect(await f.transport.requests.filter { $0.url?.path.hasSuffix("/pause") == true }.count == 1)
    try await f.cleanup()
}

@Test @MainActor func iMessageSavedPauseWithoutOriginalLocalRecordRequiresAnotherExplicitIntent() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    let config = DesktopEnvironmentConfiguration.production
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    await #expect(throws: IMessageSetupCoordinatorError.scopeChanged) { _ = try await f.savedAction("pause_connection", scope: scope) }
    #expect(f.preferences.object(forKey: pauseKey) == nil)
    #expect(!f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(config)))
    #expect(await f.transport.requests.allSatisfy { $0.url?.path.hasSuffix("/pause") != true })
    let fresh = try await f.apply("state")
    let freshScope = try #require(fresh["scope"] as? String)
    let paused = try await f.savedAction("pause_connection", scope: freshScope)
    #expect(paused["state"] as? String == "paused")
    #expect(await f.transport.requests.filter { $0.url?.path.hasSuffix("/pause") == true }.count == 1)
    try await f.cleanup()
}

@Test @MainActor func iMessageSavedPauseRemoteConfigKeepsCloudOnlyBehaviorWithoutLocalRecord() async throws {
    let f = try IMessageCoordinatorFixture()
    try await f.seedSaved()
    await f.transport.setSavedInstallationID("remote-mac")
    let config = DesktopEnvironmentConfiguration.production
    let pauseKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessageLocalPauseIntent", appOrigin: config.preferenceIdentity)
    let ackKey = DesktopEnvironmentConfigurationStore.scopedPreferenceKey("imessagePauseAcknowledged", appOrigin: config.preferenceIdentity)
    let initial = try await f.apply("state")
    let scope = try #require(initial["scope"] as? String)
    let refreshes = f.state.policyRefreshes
    let paused = try await f.savedAction("pause_connection", scope: scope)
    #expect(paused["state"] as? String == "paused")
    #expect(f.preferences.object(forKey: pauseKey) == nil && !f.preferences.bool(forKey: ackKey))
    #expect(!f.preferences.bool(forKey: IMessagePreferenceKeys.relayPaused(config)))
    #expect(f.state.policyRefreshes == refreshes)
    #expect(await f.transport.requests.filter { $0.url?.path.hasSuffix("/pause") == true }.count == 1)
    try await f.cleanup()
}
