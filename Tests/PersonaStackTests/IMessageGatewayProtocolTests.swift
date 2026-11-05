import Foundation
import Testing
@testable import PersonaStackCore

// These literals also belong to the frozen Go producer's imessageWire tests.
private let gatewayAck = #"{"version":1,"type":"imessage","request_id":"request","imessage":{"snapshot_ack":{"revision":9223372036854775807}}}"#
private let gatewayCommand = #"{"version":1,"type":"imessage","request_id":"request","imessage":{"command":{"request_id":"request","authorization_id":"grant","deadline_at":"2026-11-04T00:00:00Z","target":{"installation_id":"mac","workspace_id":"workspace","snapshot_revision":3},"caller":{"kind":"setup_session","setup_session":{"user_id":"human","setup_reference":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","setup_generation":1}},"operation":"imessage_prerequisites","input":{"prerequisites":{}}}}}"#
private let gatewayAvailable = #"{"conversation_id":"chat","metadata":{"id":"9007199254740993","guid":"iMessage;+;chat","name":"Conversation","service":"iMessage","is_group":false,"available":true,"participants":["person@example.com"]}}"#
private let gatewayUnavailable = #"{"conversation_id":"missing","metadata":{"id":"9223372036854775807","guid":"","name":"","service":"","is_group":false,"available":false,"participants":[]}}"#

private func gatewayEnvelope(_ payload: String, requestID: String = "request") -> String {
    "{\"version\":1,\"type\":\"imessage\",\"request_id\":\"\(requestID)\",\"imessage\":\(payload)}"
}
private func gatewayDecode(_ text: String) throws -> DesktopControlFrame { try DesktopControlFrameCodec.decode(Data(text.utf8)) }
private func gatewayTypedCommand(_ input: IMessageGatewayCommandInput = .prerequisites) throws -> IMessageGatewayCommand {
    let frame = try gatewayDecode(gatewayCommand)
    guard case .command(let original) = try #require(frame.imessage) else { throw IMessageGatewayWireError.invalidFrame }
    return IMessageGatewayCommand(requestID: original.requestID, authorizationID: original.authorizationID,
        deadlineAt: original.deadlineAt, target: original.target, caller: original.caller, input: input)
}
private func gatewayRow(_ text: String = gatewayAvailable) throws -> IMessageGatewaySetupConversation {
    try JSONDecoder().decode(IMessageGatewaySetupConversation.self, from: Data(text.utf8))
}
private func gatewayResultFrame(_ result: IMessageGatewaySetupResult) -> DesktopControlFrame {
    DesktopControlFrame(type: "imessage", requestID: "request", imessage: .result(result))
}

@Test func iMessageGatewayGoLiteralsRoundTripWithoutLegacyFieldsOrIntegerRounding() throws {
    for raw in [gatewayAck, gatewayCommand] {
        let decoded = try gatewayDecode(raw)
        let encoded = try DesktopControlFrameCodec.encode(decoded)
        #expect(try DesktopControlFrameCodec.decode(encoded) == decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["version", "type", "request_id", "imessage"])
        #expect(decoded.target == nil)
        #expect(decoded.arguments == nil)
        #expect(decoded.deadlineAt == nil)
    }
    let frame = try gatewayDecode(gatewayAck)
    guard case .snapshotAck(let ack) = try #require(frame.imessage) else { throw IMessageGatewayWireError.invalidFrame }
    #expect(ack.revision == Int64.max)
    #expect(String(decoding: try DesktopControlFrameCodec.encode(frame), as: UTF8.self).contains("9223372036854775807"))
    let exactCommand = try gatewayDecode(gatewayCommand.replacingOccurrences(of: "\"snapshot_revision\":3", with: "\"snapshot_revision\":9007199254740993")
        .replacingOccurrences(of: "\"setup_generation\":1", with: "\"setup_generation\":9223372036854775807"))
    guard case .command(let exact) = try #require(exactCommand.imessage) else { throw IMessageGatewayWireError.invalidFrame }
    #expect(exact.target.snapshotRevision == 9_007_199_254_740_993)
    #expect(exact.caller.setupSession?.setupGeneration == Int64.max)
    #expect(try DesktopControlFrameCodec.decode(DesktopControlFrameCodec.encode(exactCommand)) == exactCommand)
    try IMessageGatewayWire.validateSnapshotAck(frame, requestID: "request", revision: .max)
    #expect(throws: IMessageGatewayWireError.correlationMismatch) { try IMessageGatewayWire.validateSnapshotAck(frame, requestID: "other", revision: .max) }
}

@Test func iMessageGatewayNegotiationDoesNotChangeLegacyDesktopEncodingOrDisableItsSocket() throws {
    let raw = #"{"version":1,"type":"command","request_id":"r","operation":"desktop_control_status","arguments":{"value":1.5,"imessage":null},"deadline_at":"2026-09-23T18:30:00.123456Z","future_desktop_field":true}"#
    let decoded = try gatewayDecode(raw)
    #expect(decoded.arguments == .object(["value": .number(1.5), "imessage": .null]))
    let old = DesktopControlFrame(type: "heartbeat", readiness: "paused")
    let oldObject = try #require(JSONSerialization.jsonObject(with: DesktopControlFrameCodec.encode(old)) as? [String: Any])
    #expect(Set(oldObject.keys) == ["version", "type", "readiness"])
    for kind in ["ready", "heartbeat"] {
        for version in [0, 1, 2, Int.max] {
            let frame = DesktopControlFrame(type: kind, readiness: "paused", imessageProtocolVersion: version)
            let restored = try DesktopControlFrameCodec.decode(DesktopControlFrameCodec.encode(frame))
            #expect(restored.type == kind)
            #expect(restored.readiness == "paused")
            #expect(IMessageGatewayWire.supports(protocolVersion: restored.imessageProtocolVersion) == (version == 2))
        }
    }
    #expect(try gatewayDecode(#"{"version":1,"type":"ready","type":"ready","arguments":null}"#).arguments == nil)
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try DesktopControlFrameCodec.encode(DesktopControlFrame(type: "ready", imessageProtocolVersion: -1)) }
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try DesktopControlFrameCodec.encode(DesktopControlFrame(type: "hello", imessageProtocolVersion: 2)) }
    for token in ["1.0", "1e0", "true", "\"1\"", "1,\"imessage_protocol_version\":2"] {
        #expect(throws: (any Error).self) { try gatewayDecode("{\"version\":1,\"type\":\"ready\",\"imessage_protocol_version\":\(token)}") }
    }
}

@Test func iMessageGatewayRejectsDuplicateNullUnknownAndCrossFamilyJSON() throws {
    let cases = [
        gatewayAck.replacingOccurrences(of: "\"imessage\":", with: "\"unknown\":true,\"imessage\":"),
        gatewayAck.replacingOccurrences(of: "\"revision\":", with: "\"extra\":1,\"revision\":"),
        gatewayAck.replacingOccurrences(of: "\"revision\":", with: "\"revision\":1,\"revision\":"),
        gatewayAck.replacingOccurrences(of: "\"revision\":", with: "\"revisi\\u006fn\":1,\"revision\":"),
        gatewayAck.replacingOccurrences(of: "9223372036854775807", with: "null"),
        gatewayAck.replacingOccurrences(of: "9223372036854775807", with: "3e0"),
        gatewayAck.replacingOccurrences(of: "9223372036854775807", with: "3.0"),
        gatewayAck.replacingOccurrences(of: "9223372036854775807", with: "9223372036854775808"),
        gatewayAck.replacingOccurrences(of: "\"type\":\"imessage\"", with: "\"type\":\"imessage\",\"type\":\"ready\""),
        gatewayAck.replacingOccurrences(of: "\"type\":\"imessage\"", with: "\"type\":\"imessage\",\"TYPE\":\"ready\""),
        gatewayAck.replacingOccurrences(of: "\"imessage\":", with: "\"deadline_at\":\"0001-01-01T00:00:00Z\",\"imessage\":"),
        gatewayAck.replacingOccurrences(of: "\"imessage\":", with: "\"sequence\":0,\"imessage\":"),
        gatewayAck.replacingOccurrences(of: "\"imessage\":", with: "\"diagnostics_supported\":false,\"imessage\":"),
        gatewayEnvelope("{}"), gatewayEnvelope(#"{"snapshot_ack":{}}"#),
        gatewayEnvelope(#"{"snapshot_ack":{"revision":1},"failure":{"code":"busy","message":"Busy","retry_safe":true}}"#),
        #"{"version":1,"type":"ready","imessage":null}"#,
        #"{"version":1,"type":"ready","IMESSAGE":null}"#,
        gatewayAck + "{}", gatewayAck + "false",
    ]
    for raw in cases { #expect(throws: (any Error).self) { try gatewayDecode(raw) } }
    var invalidUTF8 = Data(gatewayAck.utf8)
    invalidUTF8.insert(0xff, at: 1)
    #expect(throws: (any Error).self) { try DesktopControlFrameCodec.decode(invalidUTF8) }
    let nested = gatewayAck.replacingOccurrences(of: "9223372036854775807", with: String(repeating: "[", count: 600) + "1" + String(repeating: "]", count: 600))
    #expect(throws: (any Error).self) { try gatewayDecode(nested) }
    #expect(throws: IMessageGatewayWireError.frameTooLarge) { try DesktopControlFrameCodec.decode(Data(count: DesktopControlFrameCodec.maximumFrameBytes + 1)) }
}

@Test func iMessageGatewayAllowsOnlyThreeSetupCommandsAndCanonicalizesZeroOptionalAuthority() throws {
    let zeroFields = gatewayCommand.replacingOccurrences(of: "\"snapshot_revision\":3", with: "\"snapshot_revision\":3,\"config_id\":\"\",\"config_version\":0,\"account_generation\":\"\",\"source_generation\":\"\"")
    let normalized = String(decoding: try DesktopControlFrameCodec.encode(gatewayDecode(zeroFields)), as: UTF8.self)
    #expect(!normalized.contains("account_generation"))
    #expect(!normalized.contains("config_version"))
    let inputs: [IMessageGatewayCommandInput] = [.prerequisites,
        .setupConversations(.init(query: "search", snapshotToken: "inventory", pageToken: "page", limit: 2)),
        .verifyConversations(.init(conversationIDs: ["chat", "missing"]))]
    for input in inputs {
        let command = try gatewayTypedCommand(input)
        let frame = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .command(command))
        #expect(try DesktopControlFrameCodec.decode(DesktopControlFrameCodec.encode(frame)) == frame)
    }
    for raw in [gatewayCommand.replacingOccurrences(of: "imessage_prerequisites", with: "imessage_send_message"),
                gatewayCommand.replacingOccurrences(of: "setup_session", with: "persona_mcp"),
                gatewayCommand.replacingOccurrences(of: "\"prerequisites\":{}", with: "\"prerequisites\":{\"text\":\"body\"}"),
                zeroFields.replacingOccurrences(of: "\"config_version\":0", with: "\"config_version\":1"),
                gatewayCommand.replacingOccurrences(of: "\"input\":", with: "\"send_attempt_id\":\"send\",\"input\":"),
                gatewayCommand.replacingOccurrences(of: "\"snapshot_revision\":3", with: "\"snapshot_revision\":3.0"),
                gatewayCommand.replacingOccurrences(of: "2026-11-04T00:00:00Z", with: "2026-11-04T00:00:00+00:00")] {
        #expect(throws: (any Error).self) { try gatewayDecode(raw) }
    }
    for input in [IMessageGatewayCommandInput.setupConversations(.init(query: String(repeating: "界", count: 129))),
                  .setupConversations(.init(pageToken: "page")), .setupConversations(.init(limit: 51)),
                  .verifyConversations(.init(conversationIDs: [])), .verifyConversations(.init(conversationIDs: ["same", "same"]))] {
        #expect(throws: (any Error).self) { try IMessageGatewayWire.validate(gatewayTypedCommand(input)) }
    }
}

@Test func iMessageGatewaySnapshotAndNanosecondCorrelationsStayExact() throws {
    let digest = String(repeating: "A", count: 43)
    let scope = IMessageGatewaySetupScope(setupReferenceSHA256: digest, generation: 1, workspaceID: "workspace", userID: "human",
        expiresAt: "2026-11-05T00:00:00.123456789Z", enabled: true)
    let snapshot = IMessageGatewaySnapshot(installationID: "mac", revision: 3, setupScope: scope)
    let frame = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .snapshot(snapshot))
    let data = try DesktopControlFrameCodec.encode(frame)
    #expect(try DesktopControlFrameCodec.decode(data) == frame)
    #expect(String(decoding: data, as: UTF8.self).contains(scope.expiresAt))
    try IMessageGatewayWire.validate(command: gatewayTypedCommand(), against: snapshot, setupReferenceSHA256: digest)
    try IMessageGatewayWire.validateSnapshotUnchanged(snapshot, snapshot)
    #expect(try IMessageGatewayWire.timestampsEqual("2026-11-05T00:00:00Z", "2026-11-05T00:00:00.000000000Z"))
    #expect(try IMessageGatewayWire.timestampPrecedes("2026-11-05T00:00:00.123456788Z", scope.expiresAt))
    #expect(try IMessageGatewayWire.timestampsEqual("2026-11-05T00:00:00.123456788Z", scope.expiresAt) == false)
    #expect(try IMessageGatewayWire.utcDate(scope.expiresAt).timeIntervalSince1970 > 0)
    let changed = IMessageGatewaySnapshot(installationID: "mac", revision: 9_007_199_254_740_993, setupScope: scope)
    #expect(throws: IMessageGatewayWireError.correlationMismatch) { try IMessageGatewayWire.validateSnapshotUnchanged(snapshot, changed) }
    #expect(throws: IMessageGatewayWireError.correlationMismatch) { try IMessageGatewayWire.validate(command: gatewayTypedCommand(), against: changed, setupReferenceSHA256: digest) }
    let empty = try gatewayDecode(gatewayEnvelope(#"{"snapshot":{"installation_id":"mac","revision":9223372036854775807,"configs":[]}}"#))
    #expect(String(decoding: try DesktopControlFrameCodec.encode(empty), as: UTF8.self).contains("9223372036854775807"))
    for raw in [String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"configs\":[]", with: "\"configs\":[{}]"),
                String(decoding: data, as: UTF8.self).replacingOccurrences(of: scope.expiresAt, with: "2030-02-30T00:00:00Z"),
                String(decoding: data, as: UTF8.self).replacingOccurrences(of: scope.expiresAt, with: "0001-01-01T00:00:00Z")] {
        #expect(throws: (any Error).self) { try gatewayDecode(raw) }
    }
}

@Test func iMessageGatewayResultsReuseProviderMetadataAndLivePublicAccountProof() throws {
    let available = try gatewayRow(), unavailable = try gatewayRow(gatewayUnavailable)
    let page = try IMessageGatewayConversationsPageResult(snapshotToken: "inventory", conversations: [available],
        nextChatRowID: IMessageRowID(9_007_199_254_740_993), upperChatRowID: IMessageRowID(.max), hasMore: false, stopReason: .caughtUp)
    let verification = IMessageGatewayVerificationResult(conversations: [available, unavailable],
        liveAccount: .init(accountID: "public-account", sourceGeneration: "app-owned-source", chatGUIDs: [available.metadata.guid]))
    let results: [IMessageGatewaySetupResult] = [.prerequisites(.init(databaseReady: true)), .conversationsPage(page),
        .verification(verification), .verification(.init(conversations: [unavailable]))]
    for result in results {
        let frame = gatewayResultFrame(result)
        let data = try DesktopControlFrameCodec.encode(frame)
        #expect(try DesktopControlFrameCodec.decode(data) == frame)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["\"text\":", "\"path\":", "\"account_generation\":", "\"messages\":"] { #expect(!text.contains(forbidden)) }
    }
    try IMessageGatewayWire.validateResult(gatewayResultFrame(.conversationsPage(page)), for: gatewayTypedCommand(.setupConversations(.init(snapshotToken: "inventory"))))
    try IMessageGatewayWire.validateResult(gatewayResultFrame(.verification(verification)), for: gatewayTypedCommand(.verifyConversations(.init(conversationIDs: ["chat", "missing"]))))
    #expect(throws: IMessageGatewayWireError.correlationMismatch) {
        try IMessageGatewayWire.validateResult(gatewayResultFrame(.verification(verification)), for: gatewayTypedCommand(.verifyConversations(.init(conversationIDs: ["missing", "chat"]))))
    }
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try IMessageGatewayWire.validate(.verification(.init(conversations: [available]))) }
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try IMessageGatewayWire.validate(.verification(.init(conversations: [unavailable], liveAccount: verification.liveAccount))) }
}

@Test func iMessageGatewayMetadataAndResultBoundaryRejectsInventedFieldsAndUnavailableClaims() throws {
    let raw = gatewayEnvelope("{\"result\":{\"verification\":{\"conversations\":[" + gatewayUnavailable + "]}}}")
    for bad in [raw.replacingOccurrences(of: "\"name\":\"\"", with: "\"name\":\"retained hint\""),
                raw.replacingOccurrences(of: "\"metadata\":{", with: "\"metadata\":{\"text\":\"private body\","),
                raw.replacingOccurrences(of: "\"metadata\":{", with: "\"metadata\":{\"account_generation\":\"invented\","),
                raw.replacingOccurrences(of: "\"participants\":[]", with: "\"participants\":null"),
                raw.replacingOccurrences(of: "\"participants\":[]", with: "\"participants\":[],\"account_id\":null"),
                raw.replacingOccurrences(of: "\"id\":\"9223372036854775807\"", with: "\"id\":9223372036854775807"),
                raw.replacingOccurrences(of: "\"id\":\"9223372036854775807\"", with: "\"id\":\"01\""),
                raw.replacingOccurrences(of: "\"verification\":", with: "\"receive_page\":"),
                raw.replacingOccurrences(of: "\"verification\":", with: "\"prerequisites\":{\"protocol_version\":1,\"adapter_revision\":2,\"database_ready\":true},\"verification\":")] {
        #expect(throws: (any Error).self) { try gatewayDecode(bad) }
    }
    #expect(try gatewayDecode(raw).imessage != nil)
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try IMessageGatewayWire.validate(.prerequisites(.init(adapterRevision: 1, databaseReady: true))) }
    let page = gatewayEnvelope("{\"result\":{\"conversations_page\":{\"snapshot_token\":\"inventory\",\"conversations\":[" + gatewayAvailable + "],\"next_chat_rowid\":\"9007199254740993\",\"upper_chat_rowid\":\"9223372036854775807\",\"has_more\":false,\"stop_reason\":\"caught_up\"}}}")
    for bad in [page.replacingOccurrences(of: "Conversation", with: String(repeating: "界", count: 86)),
                page.replacingOccurrences(of: "\"service\":\"iMessage\"", with: "\"service\":\"SMS\""),
                page.replacingOccurrences(of: "\"participants\":[\"person@example.com\"]", with: "\"participants\":[\"\"]"),
                page.replacingOccurrences(of: "\"has_more\":false", with: "\"has_more\":true"),
                page.replacingOccurrences(of: "\"conversations\":[" + gatewayAvailable + "]", with: "\"conversations\":[" + gatewayAvailable + "," + gatewayAvailable + "]")] {
        #expect(throws: (any Error).self) { try gatewayDecode(bad) }
    }
}

@Test func iMessageGatewayResultBudgetMatchesGoHtmlEscapingWithoutTruncation() throws {
    let metadata = try gatewayRow().metadata
    let rows = try (1...50).map { index in
        try IMessageGatewaySetupConversation(conversationID: "option-\(index)", metadata: IMessageConversation(id: IMessageRowID(Int64(index)),
            guid: metadata.guid, name: metadata.name, service: "iMessage", isGroup: false, available: true,
            participants: Array(repeating: String(repeating: "<", count: 200), count: 80), accountID: nil, accountLogin: nil))
    }
    let result = try IMessageGatewaySetupResult.conversationsPage(.init(snapshotToken: "inventory", conversations: rows,
        nextChatRowID: IMessageRowID(50), upperChatRowID: IMessageRowID(50), hasMore: false, stopReason: .caughtUp))
    let encoded = try JSONEncoder().encode(result)
    #expect(encoded.count < IMessageGatewayWire.maximumResultBytes)
    #expect(throws: IMessageGatewayWireError.resultTooLarge) { try DesktopControlFrameCodec.encode(gatewayResultFrame(result)) }
    let inbound = gatewayEnvelope("{\"result\":" + String(decoding: encoded, as: UTF8.self) + "}")
    #expect(throws: IMessageGatewayWireError.resultTooLarge) { try gatewayDecode(inbound) }
    #expect(rows.count == 50)
}

@Test func iMessageGatewayFailureIsFiniteRetrySafeAndCorrelatedWithoutLegacyTarget() throws {
    let failure = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(.init(code: .permissionRequired, message: "Permission required")))
    #expect(try DesktopControlFrameCodec.decode(DesktopControlFrameCodec.encode(failure)) == failure)
    try IMessageGatewayWire.validateResult(failure, for: gatewayTypedCommand())
    let postDispatch = DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(.init(code: .busy, message: "Busy", retrySafe: false)))
    #expect(try DesktopControlFrameCodec.decode(DesktopControlFrameCodec.encode(postDispatch)) == postDispatch)
    #expect(throws: IMessageGatewayWireError.correlationMismatch) { try IMessageGatewayWire.validateResult(postDispatch, for: gatewayTypedCommand()) }
    for value in [IMessageGatewayFailure(code: .outcomeUnknown, message: "Unknown"), .init(code: .statusUnavailable, message: "Unknown"),
                  .init(code: .busy, message: "")] {
        #expect(throws: IMessageGatewayWireError.invalidFrame) {
            try DesktopControlFrameCodec.encode(DesktopControlFrame(type: "imessage", requestID: "request", imessage: .failure(value)))
        }
    }
    let foreign = DesktopControlFrame(type: "imessage", requestID: "foreign", imessage: failure.imessage)
    #expect(throws: IMessageGatewayWireError.correlationMismatch) { try IMessageGatewayWire.validateResult(foreign, for: gatewayTypedCommand()) }
    let hybrid = DesktopControlFrame(type: "imessage", requestID: "request", operation: "desktop_control_status", imessage: failure.imessage)
    #expect(throws: IMessageGatewayWireError.invalidFrame) { try DesktopControlFrameCodec.encode(hybrid) }
}

@Test func iMessageStrictHTTPDocumentBudgetIsIndependentFromUnchangedWebSocketFrameLimit() throws {
    let documentBudget = IMessageJSONDocument.maximumDocumentBytes
    #expect(documentBudget == (8 << 20) + 16384)
    try IMessageJSONDocument.validate(data: Data(#"{"ok":true}"#.utf8), maximumBytes: documentBudget)
    #expect(throws: IMessageGatewayWireError.frameTooLarge) {
        try IMessageGatewayJSONInspection(Data("{}".utf8), maximumBytes: documentBudget)
    }
    #expect(throws: IMessageGatewayWireError.frameTooLarge) {
        try DesktopControlFrameCodec.decode(Data(repeating: 0x20, count: DesktopControlFrameCodec.maximumFrameBytes + 1))
    }
    #expect(throws: IMessageGatewayWireError.frameTooLarge) {
        try IMessageJSONDocument.validate(data: Data("{}".utf8), maximumBytes: documentBudget + 1)
    }
    #expect(throws: IMessageGatewayWireError.frameTooLarge) {
        try IMessageJSONDocument.validate(data: Data(repeating: 0x20, count: documentBudget + 1), maximumBytes: documentBudget)
    }
    for invalid in [#"{"ok":true,"ok":false}"#, #"{"ok":null}"#, #"{"revision":1.5}"#, "{} {}"] {
        #expect(throws: (any Error).self) { try IMessageJSONDocument.validate(data: Data(invalid.utf8), maximumBytes: documentBudget) }
    }
}
