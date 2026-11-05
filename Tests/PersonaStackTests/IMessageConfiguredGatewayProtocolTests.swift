import Foundation
import Testing
@testable import PersonaStackCore

func configuredFixtureScope(read: Bool = true, send: Bool = true, paused: Bool = false, version: Int64 = 2) throws -> IMessageGatewayConfigScope {
    .init(configID: "config", workspaceID: "workspace", configVersion: version, accountGeneration: "account", sourceGeneration: "source",
        accountID: "public-account", conversationIDs: ["chat"], conversationBindings: [
            .init(conversationID: "chat", nativeChatID: try IMessageRowID(decimal: "9007199254740993"), nativeChatGUID: "iMessage;+;selected")],
        readEnabled: read, sendEnabled: send, paused: paused)
}
func configuredFixtureMessage(text: String = "hello") -> IMessageGatewayPublicMessage {
    .init(messageID: "message-guid", conversationID: "chat", sentAt: "2026-11-03T23:59:59Z", sender: "", isFromMe: false,
          text: text, textTruncated: false, attachments: [], attachmentCount: 2)
}
let configuredFixtureDeadline = "2026-11-04T00:00:00Z"

@Test func iMessageConfiguredScopeMatchesFrozenGoLiteralAndKeepsExactRowID() throws {
    let raw = Data(#"{"config_id":"config","workspace_id":"workspace","config_version":2,"account_generation":"account","source_generation":"source","account_id":"public-account","conversation_ids":["chat"],"conversation_bindings":[{"conversation_id":"chat","native_chat_id":"9007199254740993","native_chat_guid":"iMessage;+;selected"}],"read_enabled":true,"send_enabled":true,"paused":false,"revoked_through":0}"#.utf8)
    let value = try IMessageConfiguredGatewayValidation.decode(IMessageGatewayConfigScope.self, from: raw)
    let expected = try configuredFixtureScope()
    #expect(value == expected)
    #expect(value.conversationBindings.first?.nativeChatID.value == 9_007_199_254_740_993)
    let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
    let literal = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
    #expect(canonical == literal)
    #expect(IMessageConfiguredGatewayValidation.wireVersion == 2)
    #expect(IMessageConfiguredGatewayValidation.providerVersion == 1)
    #expect(IMessageConfiguredGatewayValidation.adapterRevision == 2)
}

@Test(arguments: ["duplicate", "escaped-duplicate", "unknown", "null", "numeric-cursor", "float", "overflow", "trailing", "utf8"])
func iMessageConfiguredModelsRejectStrictMalformedBoundaries(fault: String) throws {
    let encoded = try JSONEncoder().encode(configuredFixtureScope())
    var raw = String(decoding: encoded, as: UTF8.self)
    switch fault {
    case "duplicate": raw = raw.replacingOccurrences(of: "\"config_version\":2", with: "\"config_version\":2,\"config_version\":2")
    case "escaped-duplicate": raw = raw.replacingOccurrences(of: "\"config_version\":2", with: "\"config_version\":2,\"config_\\u0076ersion\":2")
    case "unknown": raw = String(raw.dropLast()) + ",\"command\":\"ls\"}"
    case "null": raw = raw.replacingOccurrences(of: "\"paused\":false", with: "\"paused\":null")
    case "numeric-cursor": raw = raw.replacingOccurrences(of: "\"9007199254740993\"", with: "9007199254740993")
    case "float": raw = raw.replacingOccurrences(of: "\"config_version\":2", with: "\"config_version\":2.0")
    case "overflow": raw = raw.replacingOccurrences(of: "\"config_version\":2", with: "\"config_version\":9223372036854775808")
    case "trailing": raw += "{}"
    default: break
    }
    let data = fault == "utf8" ? Data([0xff]) : Data(raw.utf8)
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.decode(IMessageGatewayConfigScope.self, from: data) }
}

@Test func iMessageConfiguredResultUnionRoundTripsAllSevenOperations() throws {
    let scope = try configuredFixtureScope()
    let message = configuredFixtureMessage()
    let row = IMessageGatewayPublicConversation(conversationID: "chat", label: "Selected", participants: ["synthetic@example.test"], isGroup: false)
    let values: [(IMessageGatewayConfiguredInput, IMessageGatewayConfiguredResult)] = [
        (.status(.init(integrationID: "config")), .status(.init(state: .connected))),
        (.conversations(.init(integrationID: "config")), .conversations(.init(conversations: [row]))),
        (.conversation(.init(integrationID: "config", conversationID: "chat")), .conversation(.init(conversation: row))),
        (.recentMessages(.init(integrationID: "config", conversationID: "chat")), .recentMessages(.init(messages: [message], windowLimit: 50, truncated: false))),
        (.sendMessage(.init(integrationID: "config", conversationID: "chat", clientRequestID: "intent", text: "hello")),
         .sendMessage(.init(conversationID: "chat", clientRequestID: "intent", messageID: "outgoing-guid", confirmedAt: "2026-11-03T23:59:59Z"))),
        (.receivePage(.init(conversationID: "chat", after: try IMessageRowID(0))),
         .receivePage(.init(sourceGeneration: "source", sourceHighWater: try IMessageRowID(Int64.max), messages: [.init(rowID: try IMessageRowID(1), message: message)], nextRowID: try IMessageRowID(2), hasMore: true, stopReason: .scanLimit))),
        (.sourceCheckpoint(.init(conversationIDs: ["chat"])), .sourceCheckpoint(.init(accountID: "public-account", sourceGeneration: "source", sourceHighWater: try IMessageRowID(Int64.max), observedAt: "2026-11-03T23:59:59Z", conversations: [
            .init(conversationID: "chat", chatGUID: "iMessage;+;selected", available: true, tailRowID: try IMessageRowID(0), tailGUID: "")]))),
    ]
    for (input, result) in values {
        try IMessageConfiguredGatewayValidation.validate(result, for: input, scope: scope, deadline: configuredFixtureDeadline)
        #expect(try IMessageConfiguredGatewayValidation.decode(IMessageGatewayConfiguredResult.self, from: JSONEncoder().encode(result)) == result)
        #expect(try IMessageConfiguredGatewayValidation.decode(IMessageGatewayConfiguredInput.self, from: JSONEncoder().encode(input)) == input)
    }
}

@Test func iMessageConfiguredUnavailableMetadataIsExplicitAndNeverInventsParticipants() throws {
    let unavailable = IMessageGatewayPublicConversation(conversationID: "chat", label: "", participants: [], isGroup: false, available: false)
    let raw = try JSONEncoder().encode(unavailable)
    #expect(try IMessageConfiguredGatewayValidation.decode(IMessageGatewayPublicConversation.self, from: raw) == unavailable)
    #expect(throws: IMessageGatewayWireError.invalidFrame) {
        try IMessageConfiguredGatewayValidation.validate(IMessageGatewayPublicConversation(conversationID: "chat", label: "", participants: [], isGroup: false))
    }
    let null = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\"participants\":[]", with: "\"participants\":null")
    #expect(throws: (any Error).self) { try IMessageConfiguredGatewayValidation.decode(IMessageGatewayPublicConversation.self, from: Data(null.utf8)) }
}


@Test func iMessageConfiguredFrozenGoCommandUsesFlatWireTwoUnionAndCorrelatedFailure() throws {
    let raw = Data(#"{"version":1,"type":"imessage","request_id":"request","imessage":{"command":{"request_id":"request","authorization_id":"grant","deadline_at":"2026-11-04T00:00:00Z","target":{"installation_id":"mac","workspace_id":"workspace","snapshot_revision":3,"config_id":"config","config_version":2,"account_generation":"account","source_generation":"source"},"caller":{"kind":"persona_mcp","persona_mcp":{"principal_id":"principal","persona_id":"persona","binding_version":1}},"operation":"imessage_send_message","input":{"send_message":{"integration_id":"config","conversation_id":"chat","client_request_id":"intent","text":"hello"}},"send_attempt_id":"attempt"}}}"#.utf8)
    let frame = try DesktopControlFrameCodec.decode(raw)
    guard case .command(let command)? = frame.imessage else { Issue.record("Missing typed command"); return }
    let snapshot = IMessageGatewaySnapshot(installationID: "mac", revision: 3, configs: [try configuredFixtureScope()])
    try IMessageGatewayWire.validate(command: command, against: snapshot)
    let canonical = try JSONSerialization.jsonObject(with: DesktopControlFrameCodec.encode(frame)) as? NSDictionary
    let literal = try JSONSerialization.jsonObject(with: raw) as? NSDictionary
    #expect(canonical == literal)
    let safe = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(.init(code: .scopeDenied, message: "Denied", clientRequestID: "intent")))
    try IMessageGatewayWire.validateResult(safe, for: command, snapshot: snapshot)
    let unknown = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(.init(code: .outcomeUnknown, message: "Unknown", retrySafe: false, clientRequestID: "intent")))
    try IMessageGatewayWire.validateResult(unknown, for: command, snapshot: snapshot)
    let foreign = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(.init(code: .scopeDenied, message: "Denied", clientRequestID: "other")))
    #expect(throws: (any Error).self) { try IMessageGatewayWire.validateResult(foreign, for: command, snapshot: snapshot) }
}


@Test func iMessageConfiguredGoJSONByteCountMatchesPrimaryEscapesWithoutPerByteAllocation() throws {
    let source = "&<>\u{2028}\u{2029}/\"\n"
    let expected = #""\u0026\u003c\u003e\u2028\u2029/\"\n""#
    #expect(try IMessageConfiguredGatewayValidation.resultBytes(source) == expected.utf8.count)
}
