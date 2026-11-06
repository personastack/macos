import Foundation
import CryptoKit
import Testing
import PersonaStackCore
@testable import PersonaStack

private let hostedSetupReference = String(repeating: "A", count: 43)
private let hostedSetupExpiry = "2030-01-02T03:04:05.123456789Z"
private let hostedScopeJSON = #"{"natural_user_id":"human","workspace_id":"workspace","app_origin":"https://my.personastack.ai"}"#
private let hostedBootstrapJSON = #"{"authenticated":true,"natural_user":{"id":"human","role":"user"},"effective_user":{"id":"human","role":"user","display_name":"Human","email":"","avatar_url":"","time_zone":""},"impersonation_active":false,"session_expires_at":"2030-01-02T03:04:05Z","workspaces":[{"id":"workspace","display_name":"Team workspace","status":"active","organization_id":"org","organization_name":"Team","personal":false,"workspace_admin":false}],"active_workspace_id":"workspace","no_accessible_workspace":false,"csrf_token":"private-csrf"}"#

private func hostedJourneyJSON(_ generation: Int64 = 1, verified: Bool = false) -> String {
    "{\"setup_reference\":\"\(hostedSetupReference)\",\"generation\":\(generation),\"expires_at\":\"\(hostedSetupExpiry)\",\"mac_verified\":\(verified)}"
}
private func hostedScopeFixture() throws -> IMessageHostedNativeScope {
    try JSONDecoder().decode(IMessageHostedNativeScope.self, from: Data(hostedScopeJSON.utf8))
}
private func hostedLocator(_ generation: Int64 = 1) throws -> IMessageHostedJourneyLocator {
    try .init(setupReference: hostedSetupReference, generation: generation)
}
private func hostedMetadataJSON(operation: String, result: String, generation: Int64 = 1) -> String {
    "{\"setup_reference\":\"\(hostedSetupReference)\",\"generation\":\(generation),\"operation\":\"\(operation)\",\"result\":\(result)}"
}
private func hostedOptionJSON(_ id: String, available: Bool = true) -> String {
    "{\"conversation_id\":\"\(id)\",\"label\":\"Selected conversation\",\"is_group\":false,\"participant_count\":1,\"available\":\(available)}"
}

private actor IMessageHostedTransportFixture: AgentBridgeHostedTransport {
    struct Step: Sendable {
        let method: String
        let path: String
        let body: Data
        let status: Int
        init(_ method: String, _ path: String, _ body: String, status: Int = 200) {
            self.method = method; self.path = path; self.body = Data(body.utf8); self.status = status
        }
        init(_ method: String, _ path: String, data: Data, status: Int = 200) {
            self.method = method; self.path = path; body = data; self.status = status
        }
        static var scope: Self { .init("GET", "/user/imessage/native-scope", hostedScopeJSON) }
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    init(_ steps: [Step]) { self.steps = steps }
    func holdNextResponse() { held = true }
    func waitUntilHeld() async { if continuation == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        guard !steps.isEmpty else { Issue.record("Unplanned hosted setup request"); throw IMessageHostedSetupError.serviceUnavailable }
        let step = steps.removeFirst()
        #expect(request.httpMethod == step.method)
        #expect(request.url?.path == step.path)
        if held { await withCheckedContinuation { continuation = $0; entered?.resume(); entered = nil } }
        return (step.body, step.status)
    }
    func requireExhausted() { #expect(steps.isEmpty) }
}

@MainActor
private final class IMessageHostedScopeFence {
    var valid = true
    var calls = 0
    func validate() throws { calls += 1; guard valid else { throw IMessageHostedSetupError.scopeChanged } }
}

@MainActor
private final class IMessageHostedHeldScopeFence {
    private let heldCall: Int
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    init(heldCall: Int) { self.heldCall = heldCall }
    func validate() async {
        calls += 1
        guard calls == heldCall else { return }
        await withCheckedContinuation {
            continuation = $0
            entered?.resume()
            entered = nil
        }
    }
    func waitUntilHeld() async {
        if continuation == nil { await withCheckedContinuation { entered = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test(arguments: [1, 2], [false, true]) @MainActor
func iMessageHostedSetupClientRechecksCancellationAfterEachScopeCallback(heldCall: Int, cancel: Bool) async throws {
    let transport = IMessageHostedTransportFixture([.scope])
    let client = IMessageHostedSetupClient(transport: transport)
    let fence = IMessageHostedHeldScopeFence(heldCall: heldCall)
    let request = Task {
        try await client.nativeScope(configuration: .production, cookies: "fixture", validateScope: { await fence.validate() })
    }
    await fence.waitUntilHeld()
    if cancel { request.cancel() }
    fence.release()
    if cancel {
        await #expect(throws: CancellationError.self) { try await request.value }
    } else {
        let scope = try await request.value
        let expected = try hostedScopeFixture()
        #expect(scope == expected)
    }
    #expect(await transport.requests.count == (cancel && heldCall == 1 ? 0 : 1))
}

@Test func iMessageHostedSetupClientStatefulJourneyUsesOnlyCurrentNativeScopeAndFiniteRoutes() async throws {
    let transport = IMessageHostedTransportFixture([
        .scope, .scope, .init("POST", "/user/imessage/setup", hostedJourneyJSON(), status: 201),
        .scope, .init("GET", "/user/imessage/setup", hostedJourneyJSON(2)),
        .scope, .init("POST", "/user/imessage/setup/reauthorize", hostedJourneyJSON(3)),
        .scope, .init("POST", "/user/imessage/setup/cancel", "", status: 204),
    ])
    let client = IMessageHostedSetupClient(transport: transport)
    let scope = try await client.nativeScope(configuration: .production, cookies: "personastack_session=fixture", validateScope: {})
    #expect(scope.naturalUserID == "human" && scope.workspaceID == "workspace")
    let created = try await client.createJourney(configuration: .production, cookies: "personastack_session=fixture", csrf: "csrf-fixture",
        expectedScope: scope, validateScope: {})
    #expect(created.generation == 1 && created.expiresAt == hostedSetupExpiry && !created.macVerified)
    let observed = try await client.readJourney(created.locator, configuration: .production, cookies: "personastack_session=fixture",
        expectedScope: scope, validateScope: {})
    #expect(observed.generation == 2)
    let reauthorized = try await client.reauthorizeJourney(observed.locator, configuration: .production,
        cookies: "personastack_session=fixture", csrf: "csrf-fixture", expectedScope: scope, validateScope: {})
    #expect(reauthorized.generation == 3)
    try await client.cancelJourney(reauthorized.locator, configuration: .production, cookies: "personastack_session=fixture",
        csrf: "csrf-fixture", expectedScope: scope, validateScope: {})
    let requests = await transport.requests
    #expect(requests.count == 9)
    for request in requests {
        #expect(request.url?.scheme == "https" && request.url?.host == "my.personastack.ai")
        #expect(!request.httpShouldHandleCookies && request.timeoutInterval == 15)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "personastack_session=fixture")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-imessage-v1")
        for forbidden in ["Origin", "Referer", "Authorization", "Sec-Fetch-Site", "Sec-Fetch-Mode"] {
            #expect(request.value(forHTTPHeaderField: forbidden) == nil)
        }
        if request.url?.path == "/user/imessage/native-scope" {
            #expect(request.httpBody == nil && request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == nil)
        } else { #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == "workspace") }
        if request.httpMethod == "POST" {
            #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-fixture")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }
    #expect(requests[2].httpBody == Data("{}".utf8))
    let readQuery = try #require(URLComponents(url: requests[4].url!, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(Set(readQuery.map(\.name)) == ["setup_reference", "generation"])
    #expect(readQuery.first(where: { $0.name == "generation" })?.value == "1")
    let cancelBody = try JSONDecoder().decode(IMessageHostedJourneyLocator.self, from: #require(requests.last?.httpBody))
    #expect(cancelBody.generation == 3 && cancelBody.setupReference == hostedSetupReference)
    await transport.requireExhausted()
}

@Test(arguments: [Int64(9_007_199_254_740_993), Int64.max])
func iMessageHostedSetupClientNeverRoundsJourneyGenerations(generation: Int64) async throws {
    let transport = IMessageHostedTransportFixture([.scope, .init("GET", "/user/imessage/setup", hostedJourneyJSON(generation))])
    let client = IMessageHostedSetupClient(transport: transport)
    let result = try await client.readJourney(hostedLocator(generation), configuration: .production, cookies: "fixture",
        expectedScope: hostedScopeFixture(), validateScope: {})
    #expect(result.generation == generation)
    let request = try #require(await transport.requests.last)
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "generation" })?.value == String(generation))
    await transport.requireExhausted()
}

@Test(arguments: [false, true])
func iMessageHostedSetupClientTicketUsesOnlyDigestAndFiniteEnrollmentMode(attach: Bool) async throws {
    let ticketJSON = "{\"enrollment_ticket\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}"
    let transport = IMessageHostedTransportFixture([.scope, .init("POST", "/user/imessage/enrollment-ticket", ticketJSON, status: 201)])
    let client = IMessageHostedSetupClient(transport: transport)
    let ticket = try await client.enrollmentTicket(hostedLocator(Int64.max), mode: attach ? .attach(installationID: "existing-mac") : .enroll,
        credentialSHA256: hostedSetupReference, configuration: .production, cookies: "fixture", csrf: "csrf",
        expectedScope: hostedScopeFixture(), validateScope: {})
    #expect(ticket.enrollmentTicket == hostedSetupReference && ticket.expiresAt == hostedSetupExpiry)
    #expect(!String(describing: ticket).contains(hostedSetupReference))
    #expect(!String(reflecting: ticket).contains(hostedSetupReference))
    let body = try #require(await transport.requests.last?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == (attach ? ["setup_reference", "generation", "operation", "credential_sha256", "installation_id"]
                                      : ["setup_reference", "generation", "operation", "credential_sha256"]))
    #expect(object["operation"] as? String == (attach ? "attach" : "enroll"))
    #expect(object["credential_sha256"] as? String == hostedSetupReference)
    #expect(String(decoding: body, as: UTF8.self).contains("9223372036854775807"))
    #expect(object["machine_credential"] == nil && object["credential_bytes"] == nil)
    await transport.requireExhausted()
}

@Test func iMessageHostedSetupClientProjectsOnlyBoundedMetadataAndExactSelectionOrder() async throws {
    let page = "{\"conversations_page\":{\"snapshot_token\":\"snapshot\",\"next_page_token\":\"page-2\",\"conversations\":[\(hostedOptionJSON("first"))],\"has_more\":true,\"stop_reason\":\"scan_limit\"}}"
    let verification = "{\"verification\":{\"conversations\":[\(hostedOptionJSON("first")),\(hostedOptionJSON("missing", available: false))],\"verified\":false}}"
    let transport = IMessageHostedTransportFixture([
        .scope, .init("POST", "/user/imessage/setup/metadata", hostedMetadataJSON(operation: "imessage_prerequisites", result: #"{"prerequisites":{"database_ready":false}}"#)),
        .scope, .init("POST", "/user/imessage/setup/metadata", hostedMetadataJSON(operation: "imessage_setup_conversations", result: page)),
        .scope, .init("POST", "/user/imessage/setup/metadata", hostedMetadataJSON(operation: "imessage_verify_conversations", result: verification)),
    ])
    let client = IMessageHostedSetupClient(transport: transport)
    let scope = try hostedScopeFixture(), locator = try hostedLocator()
    func request(_ input: IMessageGatewayCommandInput) throws -> IMessageHostedMetadataRequest {
        try .init(locator: locator, enrollmentTicket: hostedSetupReference, input: input)
    }
    let prerequisite = try await client.executeMetadata(request(.prerequisites), configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
    #expect(prerequisite.result == .prerequisites(databaseReady: false))
    let input = try request(.setupConversations(.init(query: "name", limit: 1)))
    #expect(!String(reflecting: input).contains(hostedSetupReference))
    let listed = try await client.executeMetadata(input, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
    guard case .conversationsPage(let listedPage)? = listed.result else { Issue.record("Missing metadata page"); return }
    #expect(listedPage.conversations.map(\.conversationID) == ["first"] && listedPage.nextPageToken == "page-2")
    let checked = try await client.executeMetadata(request(.verifyConversations(.init(conversationIDs: ["first", "missing"]))),
        configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
    guard case .verification(let verifiedProjection)? = checked.result else { Issue.record("Missing metadata verification"); return }
    #expect(!verifiedProjection.verified && verifiedProjection.conversations.map(\.conversationID) == ["first", "missing"])
    #expect(!verifiedProjection.conversations[1].available)
    for request in await transport.requests where request.httpMethod == "POST" {
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["setup_reference", "generation", "enrollment_ticket", "operation", "input"])
        #expect(object["account_id"] == nil && object["command"] == nil && object["authorization_id"] == nil && object["target"] == nil)
    }
    await transport.requireExhausted()
}

@Test func iMessageHostedSetupClientKeepsFiniteMetadataDomainFailureSeparateFromHTTPFailure() async throws {
    let response = "{\"setup_reference\":\"\(hostedSetupReference)\",\"generation\":1,\"operation\":\"imessage_prerequisites\",\"reason_code\":\"mac_offline\"}"
    let transport = IMessageHostedTransportFixture([.scope, .init("POST", "/user/imessage/setup/metadata", response)])
    let client = IMessageHostedSetupClient(transport: transport)
    let result = try await client.executeMetadata(.init(locator: hostedLocator(), enrollmentTicket: hostedSetupReference, input: .prerequisites),
        configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: hostedScopeFixture(), validateScope: {})
    #expect(result.reasonCode == .macOffline && result.result == nil)
    await transport.requireExhausted()
}

@Test(arguments: [
    #"{"natural_user_id":"human","workspace_id":"workspace","app_origin":"https://foreign.invalid"}"#,
    #"{"natural_user_id":"human","workspace_id":"workspace","app_origin":"https://my.personastack.ai/path"}"#,
    #"{"natural_user_id":"human","workspace_id":"workspace","app_origin":null}"#,
    #"{"natural_user_id":"human","workspace_id":"workspace","app_origin":"https://my.personastack.ai","token":"private"}"#,
    #"{"natural_user_id":"human","natural_user_id":"foreign","workspace_id":"workspace","app_origin":"https://my.personastack.ai"}"#,
    #"{"natural_user_id":"human","\u006eatural_user_id":"foreign","workspace_id":"workspace","app_origin":"https://my.personastack.ai"}"#,
    #"{"natural_user_id":"human","workspace_id":"workspace"}"#,
]) func iMessageHostedSetupClientRejectsUntrustedOrAmbiguousNativeScope(raw: String) async {
    let transport = IMessageHostedTransportFixture([.init("GET", "/user/imessage/native-scope", raw)])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: (any Error).self) { try await client.nativeScope(configuration: .production, cookies: "fixture", validateScope: {}) }
}

@Test(arguments: ["", "\n", String(repeating: "x", count: 16385), "session=value\r\nAuthorization: injected"])
func iMessageHostedSetupClientRejectsInvalidCookiesBeforeAnyTransport(cookie: String) async {
    let transport = IMessageHostedTransportFixture([])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: IMessageHostedSetupError.invalidRequest) { try await client.nativeScope(configuration: .production, cookies: cookie, validateScope: {}) }
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func iMessageHostedSetupClientRechecksNativeDocumentFenceAfterAwait() async throws {
    let transport = IMessageHostedTransportFixture([.scope])
    let client = IMessageHostedSetupClient(transport: transport)
    let fence = IMessageHostedScopeFence()
    await transport.holdNextResponse()
    let request = Task { try await client.nativeScope(configuration: .production, cookies: "fixture", validateScope: { try fence.validate() }) }
    await transport.waitUntilHeld()
    fence.valid = false
    await transport.release()
    await #expect(throws: IMessageHostedSetupError.scopeChanged) { try await request.value }
    #expect(fence.calls == 2)
}

@Test func iMessageHostedSetupClientFreshServerScopeChangePreventsMutation() async throws {
    let changed = hostedScopeJSON.replacingOccurrences(of: "\"human\"", with: "\"different-human\"")
    let transport = IMessageHostedTransportFixture([.init("GET", "/user/imessage/native-scope", changed)])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: IMessageHostedSetupError.scopeChanged) {
        try await client.createJourney(configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    #expect(await transport.requests.count == 1)
    await transport.requireExhausted()
}

@Test(arguments: [401, 403, 404, 409, 429, 500, 302])
func iMessageHostedSetupClientRejectsRedirectStatusesWithoutExposingHTTPBody(status: Int) async {
    let transport = IMessageHostedTransportFixture([.init("GET", "/user/imessage/native-scope", "private-machine-proof-and-body", status: status)])
    let client = IMessageHostedSetupClient(transport: transport)
    let expected: IMessageHostedSetupError = status == 401 ? .authenticationRequired : ([403, 404, 409].contains(status) ? .scopeChanged : (status == 429 ? .rateLimited : .serviceUnavailable))
    await #expect(throws: expected) { try await client.nativeScope(configuration: .production, cookies: "fixture", validateScope: {}) }
    #expect(!(expected.errorDescription ?? "").contains("private-machine-proof"))
    #expect(await transport.requests.count == 1)
}

@Test(arguments: [Data([0xff]), Data(repeating: 0x20, count: 4097)])
func iMessageHostedSetupClientBoundsScopeResponseBeforeDecode(raw: Data) async {
    let transport = IMessageHostedTransportFixture([.init("GET", "/user/imessage/native-scope", data: raw)])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: IMessageHostedSetupError.invalidResponse) { try await client.nativeScope(configuration: .production, cookies: "fixture", validateScope: {}) }
}

@Test(arguments: ["1.0", "1e0", "9223372036854775808", "null", "\"1\""])
func iMessageHostedSetupClientRejectsInexactJourneyGenerationBeforeUse(token: String) async throws {
    let raw = hostedJourneyJSON().replacingOccurrences(of: "\"generation\":1", with: "\"generation\":\(token)")
    let transport = IMessageHostedTransportFixture([.scope, .init("GET", "/user/imessage/setup", raw)])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        try await client.readJourney(hostedLocator(), configuration: .production, cookies: "fixture", expectedScope: hostedScopeFixture(), validateScope: {})
    }
}

@Test(arguments: ["create_verified", "read_foreign", "reauthorize_jump", "cancel_body"])
func iMessageHostedSetupClientCorrelatesJourneyResponsesAndNeverRetriesMutations(reason: String) async throws {
    let path = reason == "reauthorize_jump" ? "/user/imessage/setup/reauthorize" : (reason == "cancel_body" ? "/user/imessage/setup/cancel" : "/user/imessage/setup")
    let method = reason == "read_foreign" ? "GET" : "POST"
    let response = reason == "create_verified" ? hostedJourneyJSON(1, verified: true) : (reason == "reauthorize_jump" ? hostedJourneyJSON(3) : hostedJourneyJSON().replacingOccurrences(of: hostedSetupReference, with: String(repeating: "B", count: 42) + "A"))
    let status = reason == "create_verified" ? 201 : (reason == "cancel_body" ? 204 : 200)
    let transport = IMessageHostedTransportFixture([.scope, .init(method, path, response, status: status)])
    let client = IMessageHostedSetupClient(transport: transport)
    let scope = try hostedScopeFixture(), locator = try hostedLocator()
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        switch reason {
        case "create_verified": _ = try await client.createJourney(configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
        case "read_foreign": _ = try await client.readJourney(locator, configuration: .production, cookies: "fixture", expectedScope: scope, validateScope: {})
        case "reauthorize_jump": _ = try await client.reauthorizeJourney(locator, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
        default: try await client.cancelJourney(locator, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: scope, validateScope: {})
        }
    }
    #expect(await transport.requests.count == 2)
    await transport.requireExhausted()
}

@Test(arguments: ["wrong_generation", "wrong_operation", "unknown_field", "null_result", "unsafe_reason", "mixed_failure"])
func iMessageHostedSetupClientRejectsUncorrelatedOrOverbroadMetadataResponses(reason: String) async throws {
    var response = hostedMetadataJSON(operation: "imessage_prerequisites", result: #"{"prerequisites":{"database_ready":true}}"#)
    switch reason {
    case "wrong_generation": response = response.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":2")
    case "wrong_operation": response = response.replacingOccurrences(of: "imessage_prerequisites", with: "imessage_setup_conversations")
    case "unknown_field": response = String(response.dropLast()) + ",\"enrollment_ticket\":\"private\"}"
    case "null_result": response = hostedMetadataJSON(operation: "imessage_prerequisites", result: "null")
    case "unsafe_reason": response = "{\"setup_reference\":\"\(hostedSetupReference)\",\"generation\":1,\"operation\":\"imessage_prerequisites\",\"reason_code\":\"outcome_unknown\"}"
    default: response = String(response.dropLast()) + ",\"reason_code\":\"mac_offline\"}"
    }
    let transport = IMessageHostedTransportFixture([.scope, .init("POST", "/user/imessage/setup/metadata", response)])
    let client = IMessageHostedSetupClient(transport: transport)
    let request = try IMessageHostedMetadataRequest(locator: hostedLocator(), enrollmentTicket: hostedSetupReference, input: .prerequisites)
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        try await client.executeMetadata(request, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    await transport.requireExhausted()
}

@Test func iMessageHostedSetupClientRejectsInvalidMetadataInputsBeforeNetwork() throws {
    let locator = try hostedLocator()
    _ = try IMessageHostedMetadataRequest(locator: locator, enrollmentTicket: hostedSetupReference,
        input: .setupConversations(.init(query: "👩‍💻")))
    let inputs: [IMessageGatewayCommandInput] = [.setupConversations(.init(query: "unsafe\nquery")),
        .setupConversations(.init(limit: 51)), .setupConversations(.init(pageToken: "page")),
        .verifyConversations(.init(conversationIDs: [])), .verifyConversations(.init(conversationIDs: ["same", "same"]))]
    for input in inputs {
        #expect(throws: IMessageHostedSetupError.invalidRequest) { try IMessageHostedMetadataRequest(locator: locator, enrollmentTicket: hostedSetupReference, input: input) }
    }
}

@Test(arguments: ["", "two tokens", "csrf\nvalue", String(repeating: "x", count: 513)])
func iMessageHostedSetupClientRejectsInvalidCSRFTokensWithoutMutation(csrf: String) async throws {
    let transport = IMessageHostedTransportFixture([.scope])
    let client = IMessageHostedSetupClient(transport: transport)
    await #expect(throws: IMessageHostedSetupError.invalidRequest) {
        try await client.createJourney(configuration: .production, cookies: "fixture", csrf: csrf, expectedScope: hostedScopeFixture(), validateScope: {})
    }
    #expect(await transport.requests.count == 1)
    #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    await transport.requireExhausted()
}

@Test(arguments: ["limit", "snapshot", "stuck_page", "order", "unavailable_verified", "private_selector", "oversized_label"])
func iMessageHostedSetupClientPinsPageAndSelectedProjectionContracts(reason: String) async throws {
    let verification = ["order", "unavailable_verified"].contains(reason)
    let input: IMessageGatewayCommandInput = verification
        ? .verifyConversations(.init(conversationIDs: ["first", "second"]))
        : .setupConversations(.init(snapshotToken: "snapshot", pageToken: reason == "stuck_page" ? "page" : nil, limit: 1))
    let operation = verification ? "imessage_verify_conversations" : "imessage_setup_conversations"
    let result: String
    if verification {
        let rows = reason == "order" ? [hostedOptionJSON("second"), hostedOptionJSON("first")]
            : [hostedOptionJSON("first"), hostedOptionJSON("second", available: false)]
        result = "{\"verification\":{\"conversations\":[\(rows.joined(separator: ","))],\"verified\":true}}"
    } else {
        var row = hostedOptionJSON("first")
        if reason == "private_selector" { row = String(row.dropLast()) + ",\"guid\":\"private-native-selector\"}" }
        if reason == "oversized_label" { row = row.replacingOccurrences(of: "Selected conversation", with: String(repeating: "é", count: 256)) }
        let rows = reason == "limit" ? row + "," + hostedOptionJSON("second") : row
        let snapshot = reason == "snapshot" ? "foreign-snapshot" : "snapshot"
        result = "{\"conversations_page\":{\"snapshot_token\":\"\(snapshot)\",\"next_page_token\":\"page\",\"conversations\":[\(rows)],\"has_more\":true,\"stop_reason\":\"output_limit\"}}"
    }
    let transport = IMessageHostedTransportFixture([.scope, .init("POST", "/user/imessage/setup/metadata", hostedMetadataJSON(operation: operation, result: result))])
    let client = IMessageHostedSetupClient(transport: transport)
    let request = try IMessageHostedMetadataRequest(locator: hostedLocator(), enrollmentTicket: hostedSetupReference, input: input)
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        try await client.executeMetadata(request, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    await transport.requireExhausted()
}

@Test func iMessageHostedSetupClientBoundsMetadataResponseAndPreservesReadOnlyCancellation() async throws {
    let transport = IMessageHostedTransportFixture([.scope, .init("POST", "/user/imessage/setup/metadata", data: Data(repeating: 0x20, count: 65537))])
    let client = IMessageHostedSetupClient(transport: transport)
    let request = try IMessageHostedMetadataRequest(locator: hostedLocator(), enrollmentTicket: hostedSetupReference, input: .prerequisites)
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        try await client.executeMetadata(request, configuration: .production, cookies: "fixture", csrf: "csrf", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    let held = IMessageHostedTransportFixture([.scope])
    await held.holdNextResponse()
    let pending = Task { try await IMessageHostedSetupClient(transport: held).nativeScope(configuration: .production, cookies: "fixture", validateScope: {}) }
    await held.waitUntilHeld()
    pending.cancel()
    await held.release()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await held.requests.count == 1)
}

@Test func iMessageHostedSetupClientReadsTrustedDisplayContextWithoutChangingScopeAuthority() async throws {
    let transport = IMessageHostedTransportFixture([.scope, .init("GET", "/user/mobile/bootstrap", hostedBootstrapJSON)])
    let context = try await IMessageHostedSetupClient(transport: transport).displayContext(configuration: .production,
        cookies: "fixture", expectedScope: hostedScopeFixture(), validateScope: {})
    #expect(context.workspaceName == "Team workspace" && context.workspaceID == "workspace" && context.naturalUserID == "human")
    #expect(await transport.requests.count == 2)
    await transport.requireExhausted()
}

@Test func iMessageHostedDisplayContextFingerprintTracksOnlySessionCSRF() throws {
    let original = try JSONDecoder().decode(IMessageHostedDisplayContext.self, from: Data(hostedBootstrapJSON.utf8))
    let renamed = hostedBootstrapJSON.replacingOccurrences(of: "Team workspace", with: "Renamed workspace")
    let sameSession = try JSONDecoder().decode(IMessageHostedDisplayContext.self, from: Data(renamed.utf8))
    let changed = hostedBootstrapJSON.replacingOccurrences(of: "private-csrf", with: "another-opaque.token+/=")
    let differentSession = try JSONDecoder().decode(IMessageHostedDisplayContext.self, from: Data(changed.utf8))
    #expect(original.sessionFingerprint == Data(SHA256.hash(data: Data("private-csrf".utf8))))
    #expect(sameSession.sessionFingerprint == original.sessionFingerprint)
    #expect(differentSession.sessionFingerprint != original.sessionFingerprint)
    let maximum = hostedBootstrapJSON.replacingOccurrences(of: "private-csrf", with: String(repeating: "x", count: 512))
    let bounded = try JSONDecoder().decode(IMessageHostedDisplayContext.self, from: Data(maximum.utf8))
    #expect(bounded.sessionFingerprint.count == 32)
}

@Test(arguments: ["", String(repeating: "x", count: 513), String(repeating: "é", count: 257), "has space", "has\ttab", "has\nnewline", "has\u{00A0}space", "has\u{0000}control", "has\u{007F}control"])
func iMessageHostedSetupClientRejectsInvalidSessionCSRFTokens(token: String) async throws {
    var bootstrap = try #require(JSONSerialization.jsonObject(with: Data(hostedBootstrapJSON.utf8)) as? [String: Any])
    bootstrap["csrf_token"] = token
    let body = String(decoding: try JSONSerialization.data(withJSONObject: bootstrap), as: UTF8.self)
    let transport = IMessageHostedTransportFixture([.scope, .init("GET", "/user/mobile/bootstrap", body)])
    await #expect(throws: IMessageHostedSetupError.invalidResponse) {
        try await IMessageHostedSetupClient(transport: transport).displayContext(configuration: .production,
            cookies: "fixture", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    #expect(await transport.requests.count == 2)
    await transport.requireExhausted()
}

@Test(arguments: ["natural", "effective", "workspace", "impersonation", "unknown", "null", "duplicate"])
func iMessageHostedSetupClientRejectsMismatchedOrAmbiguousDisplayContext(reason: String) async throws {
    var body = hostedBootstrapJSON
    switch reason {
    case "natural": body = body.replacingOccurrences(of: #""natural_user":{"id":"human""#, with: #""natural_user":{"id":"foreign""#)
    case "effective": body = body.replacingOccurrences(of: #""effective_user":{"id":"human""#, with: #""effective_user":{"id":"foreign""#)
    case "workspace": body = body.replacingOccurrences(of: #""active_workspace_id":"workspace""#, with: #""active_workspace_id":"foreign""#)
    case "impersonation": body = body.replacingOccurrences(of: #""impersonation_active":false"#, with: #""impersonation_active":true"#)
    case "unknown": body = String(body.dropLast()) + #","setup_receipt":"private"}"#
    case "null": body = body.replacingOccurrences(of: #""display_name":"Team workspace""#, with: #""display_name":null"#)
    default: body = String(body.dropLast()) + #","active_workspace_id":"workspace"}"#
    }
    let transport = IMessageHostedTransportFixture([.scope, .init("GET", "/user/mobile/bootstrap", body)])
    await #expect(throws: (any Error).self) {
        try await IMessageHostedSetupClient(transport: transport).displayContext(configuration: .production,
            cookies: "fixture", expectedScope: hostedScopeFixture(), validateScope: {})
    }
    await transport.requireExhausted()
}

private func hostedApprovalFixture() throws -> (IMessageSetupFinalConsent, IMessageSetupApprovalEvidence, DesktopControlInstallation, IMessageHostedJourney, Date) {
    let journey = try JSONDecoder().decode(IMessageHostedJourney.self, from: Data(hostedJourneyJSON().utf8))
    let now = try IMessageGatewayWire.utcDate(journey.expiresAt).addingTimeInterval(-3600)
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: .init(
        setupReferenceSHA256: IMessageSetupProvider.setupReferenceDigest(hostedSetupReference), generation: 1,
        workspaceID: "workspace", userID: "human", expiresAt: journey.expiresAt, enabled: true))
    let metadataJSON = Data(#"{"id":"1","guid":"native-guid","name":"Selected conversation","service":"iMessage","is_group":false,"available":true,"participants":["participant"]}"#.utf8)
    try IMessageJSONDocument.validate(data: metadataJSON, maximumBytes: 4096)
    let metadata = try JSONDecoder().decode(IMessageConversation.self, from: metadataJSON)
    let row = IMessageGatewaySetupConversation(conversationID: "local-option", metadata: metadata)
    let account = IMessageSetupAccount(accountID: "native-account", sourceGeneration: "native-source")
    let consent = try IMessageSetupFinalConsent(intent: intent, installationID: "mac", environmentIdentity: DesktopEnvironmentConfiguration.production.preferenceIdentity,
        conversations: [row], account: account, readEnabled: true, sendEnabled: true, selectionAndCapabilitiesConfirmed: true,
        confirmedAt: now, deadline: now.addingTimeInterval(10))
    let evidence = try IMessageSetupApprovalEvidence(verification: .init(conversations: [row], liveAccount: .init(accountID: account.accountID,
        sourceGeneration: account.sourceGeneration, chatGUIDs: ["native-guid"])), checkpoint: .init(sourceHighWater: IMessageRowID(1),
        observedAt: "2030-01-02T02:04:05Z", chats: [.init(chatID: IMessageRowID(1), guid: "native-guid", tailRowID: IMessageRowID(1), tailGUID: "tail")]),
        readEnabled: true, sendEnabled: true)
    let installation = try DesktopControlInstallation(installationID: "mac", machineCredential: hostedSetupReference,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    return (consent, evidence, installation, journey, now)
}

@Test func iMessageHostedSetupClientPrivatelyApprovesThenCreatesOnlyCanonicalConfigID() async throws {
    let (consent, evidence, installation, journey, now) = try hostedApprovalFixture()
    let transport = IMessageHostedTransportFixture([
        .init("POST", "/user/imessage/approve", "{\"setup_receipt\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}", status: 201),
        .scope, .init("POST", "/user/imessage/configs", #"{"integration_config_id":"canonical-config"}"#, status: 201),
    ])
    let client = IMessageHostedSetupClient(transport: transport)
    let ticket = try JSONDecoder().decode(IMessageHostedEnrollmentTicket.self, from: Data("{\"enrollment_ticket\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}".utf8))
    let receipt = try await client.approve(consent: consent, evidence: evidence, installation: installation, journey: journey, ticket: ticket,
        mode: .enroll, macName: "Fixture Mac", accountLabel: "Messages account", configuration: .production, now: now, validateCurrent: { _ in })
    #expect(!String(reflecting: receipt).contains(hostedSetupReference))
    let id = try await client.createConfiguration(receipt: receipt, consent: consent, configuration: .production, cookies: "fixture",
        csrf: "csrf", expectedScope: hostedScopeFixture(), now: now, validateCurrent: { _ in })
    #expect(id == "canonical-config")
    let requests = await transport.requests
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + installation.machineCredential)
    for header in ["Cookie", "Origin", "Referer", "X-CSRF-Token"] { #expect(requests[0].value(forHTTPHeaderField: header) == nil) }
    let approvalBody = try #require(requests[0].httpBody)
    let approval = try #require(JSONSerialization.jsonObject(with: approvalBody) as? [String: Any])
    #expect(Set(approval.keys) == ["enrollment_ticket", "operation", "setup_reference", "generation", "installation_id", "mac_name", "account_label", "verification", "checkpoint", "read_enabled", "send_enabled"])
    #expect(approval["setup_reference"] as? String == hostedSetupReference)
    let createBody = try #require(requests[2].httpBody)
    let create = try #require(JSONSerialization.jsonObject(with: createBody) as? [String: Any])
    #expect(Set(create.keys) == ["setup_receipt", "name", "conversation_ids", "read_enabled", "send_enabled"])
    #expect(create["conversation_ids"] as? [String] == ["local-option"])
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
    await transport.requireExhausted()
}

@Test(arguments: [1, 2]) @MainActor
func iMessageHostedSetupClientCancelsApprovalAfterEitherFinalConsentFence(heldCall: Int) async throws {
    let (consent, evidence, installation, journey, now) = try hostedApprovalFixture()
    let ticket = try JSONDecoder().decode(IMessageHostedEnrollmentTicket.self, from: Data("{\"enrollment_ticket\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}".utf8))
    let transport = IMessageHostedTransportFixture([.init("POST", "/user/imessage/approve", "{\"setup_receipt\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}", status: 201)])
    let fence = IMessageHostedHeldScopeFence(heldCall: heldCall)
    let task = Task {
        try await IMessageHostedSetupClient(transport: transport).approve(consent: consent, evidence: evidence,
            installation: installation, journey: journey, ticket: ticket, mode: .enroll, macName: "Mac", accountLabel: "Messages",
            configuration: .production, now: now, validateCurrent: { _ in await fence.validate() })
    }
    await fence.waitUntilHeld(); task.cancel(); fence.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.count == (heldCall == 1 ? 0 : 1))
}

@Test(arguments: ["standard_padded", "standard_unpadded", "url_padded", "url_unpadded"])
func iMessageHostedSetupClientCanonicalizesLegacyMachineProofBeforeApproval(format: String) async throws {
    let (consent, evidence, _, journey, now) = try hostedApprovalFixture()
    let bytes = Data(repeating: 251, count: 32)
    let standard = bytes.base64EncodedString()
    let canonical = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let proof: String
    switch format {
    case "standard_padded": proof = standard
    case "standard_unpadded": proof = String(standard.dropLast())
    case "url_padded": proof = canonical + "="
    default: proof = canonical
    }
    let installation = try DesktopControlInstallation(installationID: "mac", machineCredential: proof,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    let ticket = try JSONDecoder().decode(IMessageHostedEnrollmentTicket.self,
        from: Data("{\"enrollment_ticket\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}".utf8))
    let transport = IMessageHostedTransportFixture([.init("POST", "/user/imessage/approve",
        "{\"setup_receipt\":\"\(hostedSetupReference)\",\"expires_at\":\"\(hostedSetupExpiry)\"}", status: 201)])
    _ = try await IMessageHostedSetupClient(transport: transport).approve(consent: consent, evidence: evidence, installation: installation,
        journey: journey, ticket: ticket, mode: .attach(installationID: "mac"), macName: "Mac", accountLabel: "Messages",
        configuration: .production, now: now, validateCurrent: { _ in })
    let request = try #require(await transport.requests.first)
    #expect(standard.contains("+") && standard.contains("/"))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + canonical)
    #expect(canonical.utf8.count == 43 && !canonical.contains("="))
    await transport.requireExhausted()
}
