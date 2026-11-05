import Foundation
import Testing
@testable import PersonaStackCore
@testable import PersonaStack

private func configuredSourceMessage(row: Int64, text: String = "hello", attachmentCount: Int = 2) throws -> IMessageMessage {
    let body: [String: Any] = ["rowid": String(row), "guid": "message-\(row)", "chat_id": "9007199254740993", "text": text,
        "is_from_me": false, "date": "2026-11-03T23:59:59.123456789Z", "sender": "", "service": "iMessage", "text_truncated": false,
        "attachment_count": attachmentCount, "attachments": [], "edited_at": "2026-11-03T23:59:59.123456789Z", "unsent_at": "2026-11-03T23:59:59.123456789Z"]
    return try JSONDecoder().decode(IMessageMessage.self, from: JSONSerialization.data(withJSONObject: body))
}

@Test func iMessageConfiguredProjectionKeepsUnknownSenderAttachmentCountAndEditMetadata() throws {
    let scope = try configuredFixtureScope()
    let binding = try #require(scope.conversationBindings.first)
    let source = try configuredSourceMessage(row: 1)
    let publicMessage = try IMessageConfiguredProjection.message(source, binding: binding)
    #expect(publicMessage.sender.isEmpty)
    #expect(publicMessage.attachments.isEmpty && publicMessage.attachmentCount == 2)
    let encoded = String(decoding: try JSONEncoder().encode(publicMessage), as: UTF8.self)
    #expect(!encoded.contains("chat_id") && !encoded.contains("9007199254740993"))
    let page = IMessageReceivePage(messages: [source], nextRowID: try IMessageRowID(1), hasMore: false, stopReason: .caughtUp)
    let result = try IMessageConfiguredProjection.receivePage(page, binding: binding, scope: scope,
        input: .init(conversationID: "chat", after: try IMessageRowID(0)), sourceHighWater: try IMessageRowID(1), deadline: configuredFixtureDeadline)
    #expect(result.messages.first?.editedAt == source.editedAt)
    #expect(result.messages.first?.unsentAt == source.unsentAt)
}

@Test func iMessageConfiguredProjectionBoundsGoEscapingWithoutSkippingOmittedReceiveRows() throws {
    let scope = try configuredFixtureScope()
    let binding = try #require(scope.conversationBindings.first)
    let rows = try (1...100).map { try configuredSourceMessage(row: Int64($0), text: String(repeating: "&", count: 16 * 1024)) }
    let source = IMessageReceivePage(messages: rows, nextRowID: try IMessageRowID(100), hasMore: false, stopReason: .caughtUp)
    let started = ContinuousClock.now
    let result = try IMessageConfiguredProjection.receivePage(source, binding: binding, scope: scope,
        input: .init(conversationID: "chat", after: try IMessageRowID(0)), sourceHighWater: try IMessageRowID(1000), deadline: configuredFixtureDeadline)
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(!result.messages.isEmpty && result.messages.count < 100)
    #expect(result.hasMore && result.stopReason == .outputLimit)
    #expect(result.nextRowID == result.messages.last?.rowID)
    #expect(result.nextRowID < rows[result.messages.count].rowID)
    #expect(try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.receivePage(result)) <= 1 << 20)
    let next = rows[result.messages.count]
    let extra = IMessageGatewayReceiveRecord(rowID: next.rowID, message: try IMessageConfiguredProjection.message(next, binding: binding), editedAt: next.editedAt, unsentAt: next.unsentAt)
    let tooLarge = IMessageGatewayReceivePageResult(sourceGeneration: result.sourceGeneration, sourceHighWater: result.sourceHighWater,
        messages: result.messages + [extra], nextRowID: extra.rowID, hasMore: true, stopReason: .outputLimit)
    #expect(try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.receivePage(tooLarge)) > 1 << 20)
}

@Test func iMessageConfiguredProjectionMapsUnavailableSourceWithoutInventedIdentity() throws {
    let scope = try configuredFixtureScope()
    let binding = try #require(scope.conversationBindings.first)
    let raw = Data(#"{"id":"9007199254740993","guid":"","name":"","service":"","is_group":false,"available":false,"participants":[]}"#.utf8)
    let source = try JSONDecoder().decode(IMessageConversation.self, from: raw)
    let value = try IMessageConfiguredProjection.conversation(source, binding: binding)
    #expect(!value.available && value.participants.isEmpty && value.label.isEmpty)
    #expect(value.conversationID == "chat" && value.service == "imessage")
}

@Test func iMessageConfiguredCheckpointProjectionStripsSqliteAccountHintsAndRequiresLiveScope() throws {
    let scope = try configuredFixtureScope()
    let raw = Data(#"{"adapter_revision":2,"source_high_water":"9223372036854775807","observed_at":"2026-11-03T23:59:59.123456789Z","chats":[{"chat_id":"9007199254740993","guid":"iMessage;+;selected","service":"iMessage","available":true,"tail_rowid":"9007199254740994","tail_guid":"tail","account_id":"sqlite-hint","account_login":"private-login"}]}"#.utf8)
    let source = try JSONDecoder().decode(IMessageSourceCheckpoint.self, from: raw)
    let result = try IMessageConfiguredProjection.checkpoint(source, scope: scope, input: .init(conversationIDs: ["chat"]),
        liveAccount: .init(accountID: "public-account", sourceGeneration: "source"), deadline: configuredFixtureDeadline)
    #expect(result.sourceHighWater.value == Int64.max)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!encoded.contains("sqlite-hint") && !encoded.contains("private-login") && !encoded.contains("native_chat_id"))
    #expect(throws: (any Error).self) {
        try IMessageConfiguredProjection.checkpoint(source, scope: scope, input: .init(conversationIDs: ["chat"]),
            liveAccount: .init(accountID: "other-account", sourceGeneration: "source"), deadline: configuredFixtureDeadline)
    }
}

private actor ConfiguredClientTransport: AgentBridgeHostedTransport {
    private let response: Data
    private let status: Int
    private(set) var requests: [URLRequest] = []
    init(response: Data, status: Int = 200) { self.response = response; self.status = status }
    func request(_ request: URLRequest) -> (Data, Int) { requests.append(request); return (response, status) }
}
@MainActor private final class ConfiguredClientFence {
    let gate = ConfiguredRuntimeGate()
    let heldCall: Int
    private(set) var calls = 0
    init(heldCall: Int = 0) { self.heldCall = heldCall }
    func validate() async { calls += 1; if calls == heldCall { await gate.pause() } }
}
private func configuredClientCommand() throws -> IMessageGatewayCommand {
    .init(requestID: "request", authorizationID: "grant", deadlineAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(10)),
        target: .init(installationID: "mac", workspaceID: "workspace", snapshotRevision: 3, configID: "config", configVersion: 2,
            accountGeneration: "account", sourceGeneration: "source"), caller: .init(personaMCP: .init(principalID: "principal", personaID: "persona", bindingVersion: 1)),
        input: .configured(.status(.init(integrationID: "config"))))
}
private func configuredClientInstallation() throws -> DesktopControlInstallation {
    try .init(installationID: "mac", machineCredential: String(repeating: "A", count: 43),
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
}

@Test @MainActor func iMessageConfiguredQueueFrontClientUsesOnlyMachineProofAndExactOriginalCommand() async throws {
    let command = try configuredClientCommand()
    let scope = try configuredFixtureScope()
    let snapshot = IMessageGatewaySnapshot(installationID: "mac", revision: 3, configs: [scope])
    let transport = ConfiguredClientTransport(response: try JSONEncoder().encode(IMessageGatewayNativeAuthorizationResponse(authorized: true, snapshot: snapshot)))
    let fence = ConfiguredClientFence()
    let client = IMessageConfiguredAuthorizationClient(transport: transport)
    let value = try await client.authorize(command, installation: configuredClientInstallation(), configuration: .production,
        deadline: Date().addingTimeInterval(10), validateCurrent: { await fence.validate() })
    #expect(value == snapshot && fence.calls == 2)
    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://my.personastack.ai/v1/desktop-control/imessage/commands/authorize")
    #expect(request.httpMethod == "POST" && !request.httpShouldHandleCookies)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "A", count: 43))
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Origin") == nil)
    #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
    #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-imessage-v1")
    let body = try #require(request.httpBody)
    let decoded = try IMessageConfiguredGatewayValidation.decode(IMessageGatewayNativeCommandRequest.self, from: body)
    #expect(decoded.command == command)
    let raw = String(decoding: body, as: UTF8.self)
    #expect(!raw.contains("machine_credential") && !raw.contains("session_id") && !raw.contains("session_generation"))
}

@Test(arguments: [1, 2]) @MainActor func iMessageConfiguredQueueFrontClientCancellationInsideScopeFenceReturnsNoAuthority(heldCall: Int) async throws {
    let command = try configuredClientCommand()
    let snapshot = IMessageGatewaySnapshot(installationID: "mac", revision: 3, configs: [try configuredFixtureScope()])
    let transport = ConfiguredClientTransport(response: try JSONEncoder().encode(IMessageGatewayNativeAuthorizationResponse(authorized: true, snapshot: snapshot)))
    let client = IMessageConfiguredAuthorizationClient(transport: transport)
    let installation = try configuredClientInstallation()
    let fence = ConfiguredClientFence(heldCall: heldCall)
    let task = Task { try await client.authorize(command, installation: installation, configuration: .production,
        deadline: Date().addingTimeInterval(10), validateCurrent: { await fence.validate() }) }
    await fence.gate.wait()
    task.cancel()
    await fence.gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.requests.count == (heldCall == 1 ? 0 : 1))
}

@Test @MainActor func iMessageConfiguredQueueFrontClientRejectsExpiredDeadlineWithoutHTTP() async throws {
    let transport = ConfiguredClientTransport(response: Data())
    let client = IMessageConfiguredAuthorizationClient(transport: transport)
    let installation = try configuredClientInstallation()
    let command = try configuredClientCommand()
    await #expect(throws: IMessageConfiguredAuthorizationError.denied(.providerTimeout)) {
        try await client.authorize(command, installation: installation, configuration: .production,
            deadline: .distantPast, validateCurrent: {})
    }
    #expect(await transport.requests.isEmpty)
}

private actor ConfiguredProviderAccount: IMessageSetupAccountReading {
    private(set) var observations = 0
    let changedPostRead: Bool
    init(changedPostRead: Bool = false) { self.changedPostRead = changedPostRead }
    func prepareProviderConnection(_ client: IMessageRPCClient) async { await client.stop() }
    func clearProviderBinding() {}
    func validateProviderConnection() {}
    func observeCurrentAccount() -> IMessageCurrentAccountObservation {
        observations += 1
        return .init(accountID: "public-account", sourceGeneration: "source", accountLabel: "Messages")
    }
    func observe(chatGUIDs: [String], expectedAccountID: String?, requestAutomation: Bool) -> IMessageLiveAccountObservation {
        observations += 1
        #expect(chatGUIDs == ["iMessage;+;selected"] && expectedAccountID == "public-account" && !requestAutomation)
        return .init(accountID: "public-account", sourceGeneration: changedPostRead && observations > 1 ? "changed" : "source", chatGUIDs: chatGUIDs)
    }
}
private actor ConfiguredProviderTransport: IMessageRPCTransport {
    private var bytes = Data()
    private var receiver: CheckedContinuation<Data, any Error>?
    private var closed = false
    private var sent = false
    private var sentText = ""
    private let unavailable: Bool
    private(set) var methods: [String] = []
    init(unavailable: Bool = false) { self.unavailable = unavailable }
    func launch() { closed = false }
    func terminate() { closed = true; bytes.removeAll(); receiver?.resume(returning: Data()); receiver = nil }
    func read(maximumBytes: Int) async throws -> Data {
        if closed { return Data() }
        if !bytes.isEmpty { let data = Data(bytes.prefix(maximumBytes)); bytes.removeFirst(data.count); return data }
        #expect(receiver == nil)
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func write(_ data: Data) throws {
        let decoded = try JSONSerialization.jsonObject(with: data)
        let request = try #require(decoded as? [String: Any])
        let method = try #require(request["method"] as? String)
        let id = try #require(request["id"] as? String)
        let params = try #require(request["params"] as? [String: Any])
        methods.append(method)
        let result: [String: Any]
        switch method {
        case "personastack.initialize", "personastack.status":
            result = ["protocol_version": 1, "personastack_adapter_revision": 2, "database": ["ready": true], "methods": IMessageRPCMethod.allCases.map(\.rawValue)]
        case "personastack.chatMetadata":
            #expect(params["chat_ids"] as? [String] == ["9007199254740993"])
            result = ["chats": [["id": "9007199254740993", "guid": unavailable ? "" : "iMessage;+;selected", "name": unavailable ? "" : "Selected",
                "service": unavailable ? "" : "iMessage", "is_group": false, "available": !unavailable, "participants": unavailable ? [] : ["participant"]]]]
        case "personastack.source_checkpoint":
            #expect(params["chat_ids"] as? [String] == ["9007199254740993"])
            let anchors = params["anchors"] as? [[String: String]] ?? []
            var row: [String: Any] = ["chat_id": "9007199254740993", "guid": "iMessage;+;selected", "service": "iMessage", "available": true,
                "tail_rowid": "1", "tail_guid": "incoming-1", "account_id": "sqlite-hint"]
            if let anchor = anchors.first { row["anchor_matches"] = anchor["rowid"] == "1" && anchor["guid"] == "incoming-1" }
            result = ["adapter_revision": 2, "source_high_water": "20", "observed_at": ISO8601DateFormatter().string(from: Date()), "chats": [row]]
        case "personastack.recent_messages":
            #expect(params["chat_id"] as? String == "9007199254740993")
            #expect((params["limit"] as? Int ?? 0) <= 100)
            result = ["messages": [message(row: "1", guid: "incoming-1", text: "hello", outgoing: false)], "truncated": false, "stop_reason": "caught_up"]
        case "personastack.receive_page":
            #expect(params["chat_id"] as? String == "9007199254740993")
            #expect((params["limit"] as? Int ?? 0) <= 100)
            let row = sent ? "21" : "1"
            result = ["messages": [message(row: row, guid: sent ? "outgoing-21" : "incoming-1", text: sent ? sentText : "hello", outgoing: sent)],
                "next_rowid": row, "has_more": false, "stop_reason": "caught_up"]
        case "personastack.send":
            #expect(Set(params.keys) == ["chat_id", "chat_guid", "text", "expected_account_id"])
            #expect(params["chat_id"] as? String == "9007199254740993")
            #expect(params["chat_guid"] as? String == "iMessage;+;selected")
            #expect(params["expected_account_id"] as? String == "public-account")
            sentText = try #require(params["text"] as? String); sent = true
            result = ["submitted": true, "transport": "applescript", "service": "iMessage", "chat_guid": "iMessage;+;selected"]
        default: Issue.record("Unplanned configured provider RPC \(method)"); throw IMessageRPCError.invalidArguments
        }
        var frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]); frame.append(0x0a)
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) } else { bytes.append(frame) }
    }
    private func message(row: String, guid: String, text: String, outgoing: Bool) -> [String: Any] {
        ["rowid": row, "guid": guid, "chat_id": "9007199254740993", "text": text, "is_from_me": outgoing,
         "date": "2026-11-03T23:59:59Z", "sender": "", "service": "iMessage", "text_truncated": false,
         "attachment_count": 2, "attachments": [], "edited_at": "2026-11-03T23:59:59.123456789Z"]
    }
}
private func configuredProviderInput(_ operation: String) throws -> IMessageGatewayConfiguredInput {
    switch operation {
    case "status": .status(.init(integrationID: "config"))
    case "conversations": .conversations(.init(integrationID: "config"))
    case "conversation": .conversation(.init(integrationID: "config", conversationID: "chat"))
    case "recent": .recentMessages(.init(integrationID: "config", conversationID: "chat", limit: 50))
    case "checkpoint": .sourceCheckpoint(.init(conversationIDs: ["chat"], anchors: [.init(conversationID: "chat", rowID: try IMessageRowID(1), guid: "incoming-1")]))
    case "receive": .receivePage(.init(conversationID: "chat", after: try IMessageRowID(0), limit: 100))
    case "send": .sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "intent", text: "exact hello"))
    default: throw IMessageRPCError.invalidArguments
    }
}

@Test(arguments: ["status", "conversations", "conversation", "recent", "checkpoint", "receive", "send"])
func iMessageConfiguredProviderUsesTheCanonicalFiniteRPCForEveryOperation(operation: String) async throws {
    let transport = ConfiguredProviderTransport()
    let accounts = ConfiguredProviderAccount()
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: accounts)
    let scope = try configuredFixtureScope()
    let input = try configuredProviderInput(operation)
    let deadline = Date().addingTimeInterval(10)
    let result = try await provider.executeConfigured(input, scope: scope, deadline: deadline, validateCurrent: { true })
    try IMessageConfiguredGatewayValidation.validate(result, for: input, scope: scope, deadline: ISO8601DateFormatter().string(from: deadline))
    let methods = await transport.methods
    #expect(methods.first == "personastack.initialize")
    #expect(!methods.contains("messages.history") && !methods.contains("messages.send") && !methods.contains("status"))
    if case .sendMessage(let value) = result { #expect(value.messageID == "outgoing-21" && value.outcome == "local_record_confirmed") }
    if case .receivePage(let value) = result { #expect(value.messages.first?.message.attachmentCount == 2 && value.messages.first?.editedAt != nil) }
    await provider.stop()
}

@Test func iMessageConfiguredProviderMissingConversationRemainsUnavailableWithoutBodyReads() async throws {
    let transport = ConfiguredProviderTransport(unavailable: true)
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: transport), accounts: ConfiguredProviderAccount())
    let scope = try configuredFixtureScope()
    let value = try await provider.executeConfigured(.conversations(.init(integrationID: "config")), scope: scope,
        deadline: Date().addingTimeInterval(10), validateCurrent: { true })
    guard case .conversations(let result) = value else { Issue.record("Missing metadata result"); return }
    #expect(result.conversations.count == 1 && result.conversations[0].participants.isEmpty && !result.conversations[0].available)
    #expect(await transport.methods == ["personastack.initialize", "personastack.chatMetadata"])
    await provider.stop()
}

@Test func iMessageConfiguredProviderRejectsChangedPostReadAccountSourceBeforeReturningContent() async throws {
    let provider = IMessageSetupProvider(client: IMessageRPCClient(transport: ConfiguredProviderTransport()), accounts: ConfiguredProviderAccount(changedPostRead: true))
    await #expect(throws: IMessageSetupProviderError.accountChanged) {
        try await provider.executeConfigured(.recentMessages(.init(integrationID: "config", conversationID: "chat")), scope: configuredFixtureScope(),
            deadline: Date().addingTimeInterval(10), validateCurrent: { true })
    }
    await provider.stop()
}

@Test(arguments: ["denied", "revision", "setup", "duplicate", "oversized"]) @MainActor
func iMessageConfiguredQueueFrontClientRejectsForeignOrMalformedAuthorityWithoutRetry(fault: String) async throws {
    let command = try configuredClientCommand()
    let snapshot = IMessageGatewaySnapshot(installationID: "mac", revision: fault == "revision" ? 4 : 3, configs: [try configuredFixtureScope()],
        setupScope: fault == "setup" ? .init(setupReferenceSHA256: String(repeating: "A", count: 43), generation: 1, workspaceID: "workspace", userID: "human",
            expiresAt: command.deadlineAt, enabled: true) : nil)
    let value = fault == "denied" ? IMessageGatewayNativeAuthorizationResponse(authorized: false, reasonCode: .scopeDenied)
        : IMessageGatewayNativeAuthorizationResponse(authorized: true, snapshot: snapshot)
    var raw = try JSONEncoder().encode(value)
    if fault == "duplicate" {
        raw = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"authorized\":true", with: "\"authorized\":true,\"authorized\":true").utf8)
    }
    if fault == "oversized" { raw = Data(repeating: 0x20, count: IMessageConfiguredGatewayValidation.maximumCommandControlBytes + 1) }
    let transport = ConfiguredClientTransport(response: raw)
    let client = IMessageConfiguredAuthorizationClient(transport: transport)
    let installation = try configuredClientInstallation()
    await #expect(throws: (any Error).self) {
        try await client.authorize(command, installation: installation, configuration: .production, deadline: Date().addingTimeInterval(10), validateCurrent: {})
    }
    #expect(await transport.requests.count == 1)
}


@Test func iMessageConfiguredRecentProjectionKeepsLargestLatestSuffixWithinReadBudget() throws {
    let scope = try configuredFixtureScope()
    let binding = try #require(scope.conversationBindings.first)
    let rows = try (1...100).map { try configuredSourceMessage(row: Int64($0), text: String(repeating: "<", count: 16 * 1024)) }
    let source = IMessageRecentMessages(messages: rows, truncated: false, stopReason: .caughtUp)
    let started = ContinuousClock.now
    let result = try IMessageConfiguredProjection.recentMessages(source, binding: binding, limit: 100)
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(result.truncated && result.windowLimit == 100 && !result.messages.isEmpty && result.messages.count < 100)
    #expect(result.messages.map(\.messageID) == rows.suffix(result.messages.count).map(\.guid))
    #expect(try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.recentMessages(result)) <= 1 << 20)
    let earlier = rows[rows.count - result.messages.count - 1]
    let tooLarge = IMessageGatewayRecentMessagesResult(messages: [try IMessageConfiguredProjection.message(earlier, binding: binding)] + result.messages,
        windowLimit: 100, truncated: true)
    #expect(try IMessageConfiguredGatewayValidation.resultBytes(IMessageGatewayConfiguredResult.recentMessages(tooLarge)) > 1 << 20)
}

@Test func iMessageConfiguredRecentProjectionPreservesAnEmptyWindow() throws {
    let scope = try configuredFixtureScope()
    let binding = try #require(scope.conversationBindings.first)
    let source = IMessageRecentMessages(messages: [], truncated: false, stopReason: .caughtUp)
    let result = try IMessageConfiguredProjection.recentMessages(source, binding: binding, limit: 100)
    #expect(result.messages.isEmpty && !result.truncated && result.windowLimit == 100)
}
