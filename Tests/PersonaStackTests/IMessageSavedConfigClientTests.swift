import AppKit
import Foundation
import CryptoKit
import Testing
import PersonaStackCore
@testable import PersonaStack

func nativeSavedReadbackData(version: String = "7", paused: Bool = false, installation: String = "mac", read: Bool = true, send: Bool = true,
                             gaps: [String] = []) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["integration_config_id": "saved", "name": "Saved Mac", "config_version": version,
        "config": ["installation_id": installation, "mac_name": "Fixture Mac", "account_label": "Messages account", "read_enabled": read,
            "send_enabled": send, "paused": paused, "conversations": [["conversation_id": "selected", "label": "Selected conversation",
                "participants": ["synthetic@example.test"], "is_group": false, "service": "imessage", "available": true]],
            "status": ["integration_id": "saved", "state": paused ? "paused" : "connected", "receive_state": "disabled",
                "read_enabled": read, "send_enabled": send, "receive_enabled": false, "pending_count": 0, "continuity_gap_conversation_ids": gaps]]], options: [.sortedKeys])
}
func nativeSavedScopeData() -> Data { Data(#"{"natural_user_id":"human","workspace_id":"workspace","app_origin":"https://my.personastack.ai"}"#.utf8) }
func nativeSavedScope() throws -> IMessageHostedNativeScope { try JSONDecoder().decode(IMessageHostedNativeScope.self, from: nativeSavedScopeData()) }
func nativeSavedInstallation() throws -> DesktopControlInstallation {
    try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"mac","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8))
}
private func nativeHumanCommand(version: Int64 = 7, user: String = "human", workspace: String = "workspace", text: String = "hello", key: String = "one-key", digest: String? = nil) -> IMessageGatewayCommand {
    .init(requestID: "human-command", authorizationID: "human-grant", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(45)),
        target: .init(installationID: "mac", workspaceID: workspace, snapshotRevision: 1, configID: "saved", configVersion: version,
            accountGeneration: "account", sourceGeneration: "source"),
        caller: .init(humanAction: .init(userID: user, action: .testSend, conversationID: "selected",
            textSHA256: digest ?? IMessageSetupProvider.messageTextDigest(text))),
        input: .configured(.sendMessage(.init(integrationID: "saved", conversationID: "selected", clientRequestID: key, text: text))), sendAttemptID: "one-attempt")
}
private struct NativeHumanPreparedJSON: Encodable { let command: IMessageGatewayCommand }
private struct NativeHumanSentJSON: Encodable {
    let sendMessage: IMessageGatewaySendMessageResult
    enum CodingKeys: String, CodingKey { case sendMessage = "send_message" }
}
private actor NativeSavedHTTP: AgentBridgeHostedTransport {
    struct Step: Sendable {
        let method: String
        let path: String
        let data: Data
        let status: Int
        init(_ method: String, _ path: String, _ data: Data, _ status: Int = 200) {
            self.method = method; self.path = path; self.data = data; self.status = status
        }
        static var scope: Step { .init("GET", "/user/imessage/native-scope", nativeSavedScopeData()) }
    }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step] = []) { self.steps = steps }
    func request(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        guard !steps.isEmpty else { Issue.record("Unexpected native saved HTTP request"); throw IMessageHostedSetupError.serviceUnavailable }
        let next = steps.removeFirst()
        #expect(request.httpMethod == next.method && request.url?.path == next.path)
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-imessage-v1")
        #expect(request.httpShouldHandleCookies == false)
        return (next.data, next.status)
    }
    func exhausted() { #expect(steps.isEmpty) }
}

@Test @MainActor func iMessageNativeHumanHTTPUsesExactInt64BodyAndSeparateProofOnlyRedemption() async throws {
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData(version: String(Int64.max)))
    let command = nativeHumanCommand(version: Int64.max)
    let confirmed = IMessageGatewaySendMessageResult(conversationID: "selected", clientRequestID: "one-key", messageID: "canonical-message",
        confirmedAt: ISO8601DateFormatter().string(from: Date()))
    let transport = NativeSavedHTTP([.scope, .init("POST", "/user/imessage/configs/saved/test-send", try JSONEncoder().encode(NativeHumanPreparedJSON(command: command))),
        .scope, .init("POST", "/v1/desktop-control/imessage/actions/redeem", try JSONEncoder().encode(NativeHumanSentJSON(sendMessage: confirmed)))])
    let client = IMessageSavedConfigClient(transport: transport)
    let input = IMessageHumanActionRequest(expectedConfigVersion: Int64.max, action: .testSend, conversationID: "selected", clientRequestID: "one-key", text: "hello")
    let deadline = Date().addingTimeInterval(45), scope = try nativeSavedScope()
    let prepared = try await client.prepare(input, saved: saved, configuration: .production, cookies: "ps_session=human", csrf: "csrf", scope: scope, deadline: deadline) {}
    #expect(prepared.command == command)
    let redeemed = try await client.redeem(command, input: input, saved: saved, installation: nativeSavedInstallation(), configuration: .production,
        scope: scope, deadline: deadline) {}
    #expect(redeemed.sendMessage == confirmed)
    let requests = await transport.requests
    #expect(requests.count == 4)
    let human = requests[1], machine = requests[3]
    #expect(human.value(forHTTPHeaderField: "Cookie") == "ps_session=human" && human.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(human.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf" && human.value(forHTTPHeaderField: "X-PersonaStack-Workspace-ID") == "workspace")
    let humanBody = try #require(human.httpBody)
    let raw = String(decoding: humanBody, as: UTF8.self)
    #expect(raw.contains("\"expected_config_version\":9223372036854775807"))
    #expect(machine.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "A", count: 43))
    for forbidden in ["Cookie", "X-CSRF-Token", "X-PersonaStack-Workspace-ID", "Origin", "Referer"] { #expect(machine.value(forHTTPHeaderField: forbidden) == nil) }
    let machineBody = try #require(machine.httpBody)
    let decodedWrapper = try JSONSerialization.jsonObject(with: machineBody)
    let wrapper = try #require(decodedWrapper as? [String: Any])
    #expect(Set(wrapper.keys) == ["command"])
    #expect(machine.timeoutInterval <= 45 && human.timeoutInterval <= 45)
    await transport.exhausted()
}

@Test(arguments: ["version", "human", "workspace", "body", "key", "digest", "union", "snapshot"])
@MainActor func iMessageNativeHumanPreparedResponseCannotBroadenConfirmedIntent(fault: String) async throws {
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData())
    let issued = nativeHumanCommand(version: fault == "version" ? 8 : 7, user: fault == "human" ? "foreign" : "human",
        workspace: fault == "workspace" ? "foreign" : "workspace", text: fault == "body" ? "changed" : "hello", key: fault == "key" ? "other" : "one-key",
        digest: fault == "digest" ? String(repeating: "a", count: 64) : nil)
    var data = try JSONEncoder().encode(NativeHumanPreparedJSON(command: issued))
    if fault == "union" || fault == "snapshot" {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        object[fault == "union" ? "status" : "snapshot"] = [:]
        data = try JSONSerialization.data(withJSONObject: object)
    }
    let transport = NativeSavedHTTP([.scope, .init("POST", "/user/imessage/configs/saved/test-send", data), .scope])
    let client = IMessageSavedConfigClient(transport: transport)
    let input = IMessageHumanActionRequest(expectedConfigVersion: 7, action: .testSend, conversationID: "selected", clientRequestID: "one-key", text: "hello")
    await #expect(throws: (any Error).self) {
        _ = try await client.prepare(input, saved: saved, configuration: .production, cookies: "ps_session=human", csrf: "csrf",
            scope: nativeSavedScope(), deadline: Date().addingTimeInterval(45)) {}
    }
    #expect(await transport.requests.count == 3)
    await transport.exhausted()
}

@Test(arguments: ["missing_count", "count_overflow", "oldest_without_count", "no_oldest", "missing_gap", "null_gap", "foreign_gap", "duplicate_gap", "private_selector", "numeric_version", "float_version", "duplicate", "null", "extra"])
func iMessageSavedReadbackStrictlyDecodesActualPublicStatusOnly(fault: String) throws {
    let fixtureData = try nativeSavedReadbackData()
    let decodedObject = try JSONSerialization.jsonObject(with: fixtureData)
    var object = try #require(decodedObject as? [String: Any])
    var config = try #require(object["config"] as? [String: Any]), status = try #require(config["status"] as? [String: Any])
    switch fault {
    case "missing_count": status.removeValue(forKey: "pending_count")
    case "count_overflow": status["pending_count"] = 10001
    case "oldest_without_count": status["oldest_pending_at"] = "2026-11-04T00:00:00Z"
    case "no_oldest": status["pending_count"] = 1
    case "missing_gap": status.removeValue(forKey: "continuity_gap_conversation_ids")
    case "null_gap": status["continuity_gap_conversation_ids"] = NSNull()
    case "foreign_gap": status["continuity_gap_conversation_ids"] = ["foreign"]
    case "duplicate_gap": status["continuity_gap_conversation_ids"] = ["selected", "selected"]
    case "private_selector": config["native_chat_id"] = "1"
    case "numeric_version": object["config_version"] = 7
    case "float_version": object["config_version"] = "7.0"
    case "null": config["account_label"] = NSNull()
    case "extra": object["native_approval_receipt"] = "never-page-data"
    default: break
    }
    config["status"] = status; object["config"] = config
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    if fault == "duplicate" { data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"config_version\":\"7\"", with: "\"config_version\":\"7\",\"config_version\":\"7\"").utf8) }
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: data) }
}

@Test @MainActor func iMessageNativeSavedPauseUsesStringVersionAndCanonicalReadback() async throws {
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData())
    let transport = NativeSavedHTTP([.scope, .init("POST", "/user/imessage/configs/saved/pause", try nativeSavedReadbackData(version: "8", paused: true)), .scope])
    let result = try await IMessageSavedConfigClient(transport: transport).pause(saved, configuration: .production, cookies: "ps_session=human", csrf: "csrf", scope: nativeSavedScope()) {}
    #expect(result.configVersion == 8 && result.config.paused)
    let requests = await transport.requests
    let request = try #require(requests.first(where: { $0.httpMethod == "POST" }))
    let rawBody = try #require(request.httpBody)
    let decodedBody = try JSONSerialization.jsonObject(with: rawBody)
    let body = try #require(decodedBody as? [String: Any])
    #expect(Set(body.keys) == ["expected_config_version"] && body["expected_config_version"] as? String == "7")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    await transport.exhausted()
}

@Test @MainActor func iMessageNativeHumanInvalidInputAndExpiredBudgetCauseZeroNetwork() async throws {
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData(read: false, send: false))
    let transport = NativeSavedHTTP(), client = IMessageSavedConfigClient(transport: transport)
    let wrong = IMessageHumanActionRequest(expectedConfigVersion: 8, action: .testSend, conversationID: "selected", clientRequestID: "one-key", text: "hello")
    await #expect(throws: IMessageHostedSetupError.scopeChanged) {
        _ = try await client.prepare(wrong, saved: saved, configuration: .production, cookies: "cookie", csrf: "csrf", scope: nativeSavedScope(), deadline: Date().addingTimeInterval(45)) {}
    }
    let check = IMessageHumanActionRequest(expectedConfigVersion: 7, action: .check, conversationID: nil, clientRequestID: nil, text: nil)
    await #expect(throws: IMessageHostedSetupError.serviceUnavailable) {
        _ = try await client.prepare(check, saved: saved, configuration: .production, cookies: "cookie", csrf: "csrf", scope: nativeSavedScope(), deadline: Date().addingTimeInterval(-1)) {}
    }
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func iMessageNativeReviewControlsRequireOneCapabilityAndBoundNativeMessageText() throws {
    let approve = NSButton()
    let flags = IMessageReviewCapabilityControls(readEnabled: false, sendEnabled: false, approvalButton: approve)
    #expect(!approve.isEnabled)
    flags.read.performClick(nil)
    #expect(approve.isEnabled && flags.read.state == .on && flags.send.state == .off)
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData())
    let review = NSButton()
    let composer = IMessageNativeMessageComposer(conversations: saved.config.conversations, approvalButton: review)
    for (text, allowed) in [("", false), (" \n", false), (String(repeating: "é", count: 8192), true), (String(repeating: "é", count: 8193), false)] {
        composer.text.string = text
        composer.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(review.isEnabled == allowed)
    }
}

private func maximumSavedUpdateFixture(escaped: Bool, fromNow: Bool) throws -> (IMessageSavedReadback, IMessageSetupFinalConsent, IMessageHostedApprovalReceipt, [String], Data) {
    let ids = (0..<32).map { index in
        String(("saved-\(index)-" + String(repeating: escaped ? "\"\\<>" : "a", count: 256)).prefix(256))
    }
    let data = try nativeSavedReadbackData()
    let decoded = try JSONSerialization.jsonObject(with: data)
    var root = try #require(decoded as? [String: Any])
    var config = try #require(root["config"] as? [String: Any])
    var status = try #require(config["status"] as? [String: Any])
    status["continuity_gap_conversation_ids"] = fromNow ? ids : []
    config["status"] = status
    config["conversations"] = ids.map { ["conversation_id": $0, "label": "Selected conversation", "participants": ["synthetic@example.test"],
        "is_group": false, "service": "imessage", "available": true] }
    root["config"] = config
    let saved = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: JSONSerialization.data(withJSONObject: root))
    let rows: [IMessageGatewaySetupConversation] = try ids.enumerated().map { index, _ in
        let metadata = try JSONSerialization.data(withJSONObject: ["id": String(index + 1), "guid": "iMessage;-;guid-\(index)", "name": "Conversation",
            "service": "iMessage", "is_group": false, "available": true, "participants": ["synthetic@example.test"]])
        let option = String(("fresh-\(index)-" + String(repeating: escaped ? "\"\\<>" : "b", count: 256)).prefix(256))
        return .init(conversationID: option, metadata: try JSONDecoder().decode(IMessageConversation.self, from: metadata))
    }
    let now = Date()
    let utc = ISO8601DateFormatter()
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: .init(setupReferenceSHA256: String(repeating: "A", count: 43), generation: 1,
        workspaceID: "workspace", userID: "human", expiresAt: utc.string(from: now.addingTimeInterval(300)), enabled: true))
    let consent = try IMessageSetupFinalConsent(intent: intent, installationID: "mac", environmentIdentity: DesktopEnvironmentConfiguration.production.preferenceIdentity,
        conversations: rows, account: .init(accountID: "account", sourceGeneration: "source"), readEnabled: true, sendEnabled: true,
        selectionAndCapabilitiesConfirmed: true, confirmedAt: now, deadline: now.addingTimeInterval(10))
    let receipt = IMessageHostedApprovalReceipt(value: String(repeating: "A", count: 43), expiresAt: utc.string(from: now.addingTimeInterval(60)), consent: consent, macName: "Fixture Mac")
    root["config_version"] = "8"
    status["continuity_gap_conversation_ids"] = []
    config["status"] = status; root["config"] = config
    return (saved, consent, receipt, ids, try JSONSerialization.data(withJSONObject: root))
}

@Test(arguments: [IMessageSavedPageCommand.Action.edit, .resume, .resumeFromNow], [false, true]) @MainActor
func iMessageNativeFullSettingsUpdatesAllowMaximumLegalSelectionAndKeepExactEncodedIDs(flow: IMessageSavedPageCommand.Action, escaped: Bool) async throws {
    let (saved, consent, receipt, ids, response) = try maximumSavedUpdateFixture(escaped: escaped, fromNow: flow == .resumeFromNow)
    let suffix = flow == .edit ? "" : (flow == .resume ? "/resume" : "/resume-from-now")
    let method = flow == .edit ? "PATCH" : "POST"
    let transport = NativeSavedHTTP([.scope, .init(method, "/user/imessage/configs/saved" + suffix, response), .scope])
    let client = IMessageSavedConfigClient(transport: transport)
    _ = try await client.update(saved, flow: flow, receipt: receipt, consent: consent, configuration: .production,
        cookies: "ps_session=human", csrf: "csrf", scope: nativeSavedScope(), resumeConversationIDs: flow == .resumeFromNow ? ids : []) {}
    let mutations = await transport.requests.filter { $0.httpMethod != "GET" }
    #expect(mutations.count == 1)
    let request = try #require(mutations.first)
    let body = try #require(request.httpBody)
    #expect(body.count <= IMessageSavedConfigClient.maximumConfigUpdateBytes)
    if flow == .resumeFromNow { #expect(body.count > 16384) }
    let decoded = try JSONSerialization.jsonObject(with: body)
    let object = try #require(decoded as? [String: Any])
    #expect(object["expected_config_version"] as? String == "7")
    #expect(object["conversation_ids"] as? [String] == (flow == .resumeFromNow ? ids : consent.conversations.map(\.conversationID)))
    #expect(object["resume_conversation_ids"] as? [String] == (flow == .resumeFromNow ? ids : nil))
    #expect(object["text"] == nil)
    await transport.exhausted()
}

@Test func iMessageNativeConfigUpdateEncoderRejectsOver128KiBBeforeHTTPPreparation() throws {
    // The finite encoder is the production preflight before any scope HTTP.
    // Current valid 32+32 IDs already impose a smaller bound. This protects the
    // independent transport cap if a future producer expands a string field.
    let oversized = IMessageSavedConfigUpdateRequest(expectedConfigVersion: "7", name: String(repeating: "x", count: 128 << 10),
        conversationIDs: ["selected"], readEnabled: true, sendEnabled: true, nativeApprovalReceipt: String(repeating: "A", count: 43), resumeConversationIDs: nil)
    #expect(throws: IMessageHostedSetupError.invalidRequest) { try oversized.encodedBody() }
}

@Test func iMessageSavedReadbackUsesItsBoundedHTTPDocumentBudgetEvenForTinyCanonicalResponse() throws {
    let result = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: nativeSavedReadbackData(),
        maximumBytes: IMessageSavedConfigClient.maximumReadbackBytes)
    #expect(result.integrationConfigID == "saved" && result.config.status.continuityGapConversationIDs.isEmpty)
}
