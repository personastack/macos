import Foundation
import Testing
@testable import PersonaStackCore

private func approvalModelRows() throws -> [IMessageGatewaySetupConversation] {
    try [42, 44].map { id in
        try IMessageGatewaySetupConversation(conversationID: "private-option-\(id)", metadata: .init(id: IMessageRowID(Int64(id)), guid: "private-guid-\(id)",
            name: "Private label", service: "iMessage", isGroup: false, available: true,
            participants: ["private@example.invalid"], accountID: "sqlite-hint", accountLogin: nil))
    }
}

private func approvalModelVerification() throws -> IMessageGatewayVerificationResult {
    let rows = try approvalModelRows()
    return .init(conversations: rows, liveAccount: .init(accountID: "private-account", sourceGeneration: "private-source",
        chatGUIDs: rows.map(\.metadata.guid)))
}

private func approvalModelCheckpoint() throws -> IMessageSetupApprovalCheckpoint {
    try .init(sourceHighWater: IMessageRowID(.max), observedAt: "2026-11-05T00:00:00.123456789Z",
        chats: approvalModelRows().map { try .init(chatID: $0.metadata.id, guid: $0.metadata.guid,
            tailRowID: IMessageRowID(9_007_199_254_740_993), tailGUID: "private-tail") })
}

@Test func iMessageFinalConsentRequiresDistinctExplicitConfirmationAndKeepsOriginalDeadline() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let intent = IMessageRuntimeSetupIntent(localGeneration: UUID(), scope: .init(setupReferenceSHA256: String(repeating: "A", count: 43),
        generation: .max, workspaceID: "workspace", userID: "human", expiresAt: "2030-01-01T00:00:00Z", enabled: true))
    let account = IMessageSetupAccount(accountID: "private-account", sourceGeneration: "private-source")
    let rows = try approvalModelRows()
    for (confirmed, read, send) in [(false, true, true), (true, false, false)] {
        #expect(throws: IMessageSetupApprovalError.consentRequired) {
            try IMessageSetupFinalConsent(intent: intent, installationID: "installation", environmentIdentity: "app|gateway|mcp",
                conversations: rows, account: account, readEnabled: read, sendEnabled: send,
                selectionAndCapabilitiesConfirmed: confirmed, confirmedAt: now, deadline: now.addingTimeInterval(100))
        }
    }
    let consent = try IMessageSetupFinalConsent(intent: intent, installationID: "installation", environmentIdentity: "app|gateway|mcp",
        conversations: rows, account: account, readEnabled: true, sendEnabled: false,
        selectionAndCapabilitiesConfirmed: true, confirmedAt: now, deadline: now.addingTimeInterval(100))
    #expect(consent.deadline == now.addingTimeInterval(10))
    #expect(consent.intent.localGeneration == intent.localGeneration)
    #expect(consent.conversations.map(\.conversationID) == rows.map(\.conversationID))
    #expect(consent.readEnabled && !consent.sendEnabled)
    var reflected = ""
    dump(consent, to: &reflected)
    #expect(!reflected.contains("private-option"))
    #expect(String(describing: consent).contains("<redacted>"))
}

@Test func iMessageApprovalEvidenceKeepsExactCursorsAndStripsSqliteHintsAndAnchors() throws {
    let raw = #"{"adapter_revision":2,"source_high_water":"9223372036854775807","observed_at":"2026-11-05T00:00:00.123456789Z","chats":[{"chat_id":"42","guid":"private-guid-42","service":"iMessage","available":true,"tail_rowid":"9007199254740993","tail_guid":"private-tail","account_id":"sqlite-hint","account_login":"sqlite-login","anchor_matches":true},{"chat_id":"44","guid":"private-guid-44","service":"iMessage","available":true,"tail_rowid":"0","tail_guid":""}]}"#
    let source = try JSONDecoder().decode(IMessageSourceCheckpoint.self, from: Data(raw.utf8))
    let evidence = try IMessageSetupApprovalEvidence(verification: approvalModelVerification(), checkpoint: .init(source), readEnabled: true, sendEnabled: true)
    let data = try JSONEncoder().encode(evidence)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["verification", "checkpoint", "read_enabled", "send_enabled"])
    let checkpoint = try #require(object["checkpoint"] as? [String: Any])
    #expect(checkpoint["source_high_water"] as? String == "9223372036854775807")
    #expect(checkpoint["observed_at"] as? String == source.observedAt)
    let chats = try #require(checkpoint["chats"] as? [[String: Any]])
    #expect(chats[0]["tail_rowid"] as? String == "9007199254740993")
    #expect(Set(chats[0].keys) == ["chat_id", "guid", "service", "available", "tail_rowid", "tail_guid"])
    #expect(chats[0]["account_id"] == nil && chats[0]["anchor_matches"] == nil)
    var reflected = ""
    dump(evidence, to: &reflected)
    #expect(!reflected.contains("private-guid"))
    #expect(!String(reflecting: evidence).contains("private-account"))
}

@Test func iMessageApprovalEvidenceRejectsForeignOrderUnavailableAndInvalidTailPairs() throws {
    let verification = try approvalModelVerification()
    let valid = try approvalModelCheckpoint()
    let first = valid.chats[0]
    let replacements = [
        IMessageSetupApprovalCheckpoint.Chat(chatID: first.chatID, guid: "foreign", tailRowID: first.tailRowID, tailGUID: first.tailGUID),
        .init(chatID: first.chatID, guid: first.guid, available: false, tailRowID: first.tailRowID, tailGUID: first.tailGUID),
        .init(chatID: first.chatID, guid: first.guid, tailRowID: try IMessageRowID(0), tailGUID: "nonempty"),
        .init(chatID: first.chatID, guid: first.guid, tailRowID: first.tailRowID, tailGUID: ""),
    ]
    for first in replacements {
        let checkpoint = IMessageSetupApprovalCheckpoint(sourceHighWater: valid.sourceHighWater, observedAt: valid.observedAt,
            chats: [first, valid.chats[1]])
        #expect(throws: IMessageSetupApprovalError.invalidEvidence) {
            try IMessageSetupApprovalEvidence(verification: verification, checkpoint: checkpoint, readEnabled: true, sendEnabled: false)
        }
    }
    for checkpoint in [IMessageSetupApprovalCheckpoint(sourceHighWater: valid.sourceHighWater, observedAt: valid.observedAt, chats: Array(valid.chats.reversed())),
                       .init(sourceHighWater: try IMessageRowID(1), observedAt: valid.observedAt, chats: valid.chats)] {
        #expect(throws: IMessageSetupApprovalError.invalidEvidence) {
            try IMessageSetupApprovalEvidence(verification: verification, checkpoint: checkpoint, readEnabled: true, sendEnabled: false)
        }
    }
    let unavailable = IMessageGatewaySetupConversation(conversationID: "missing", metadata: .init(id: try IMessageRowID(9), guid: "", name: "",
        service: "", isGroup: false, available: false, participants: [], accountID: nil, accountLogin: nil))
    #expect(throws: IMessageSetupApprovalError.selectionUnavailable) {
        try IMessageSetupApprovalEvidence(verification: .init(conversations: [unavailable]), checkpoint: valid, readEnabled: true, sendEnabled: false)
    }
}
