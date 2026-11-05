import Foundation
import PersonaStackCore
import Testing

private let draftReference = String(repeating: "A", count: 43)
private let draftExpiry = "2030-01-02T03:04:05.123456789Z"

private func draftSelection(_ row: String = "1", _ guid: String = "iMessage;-;private-guid") throws -> IMessageSetupDraft.Selection {
    try IMessageSetupDraft.Selection(nativeChatRowID: row, expectedGUID: guid)
}

private func draftFixture(reference: String = draftReference, user: String = "draft-user", workspace: String = "draft-workspace",
                          environment: String = "app|gateway|mcp", expiry: String = draftExpiry,
                          account: String? = "private-account", source: String? = "private-source",
                          selections: [IMessageSetupDraft.Selection]? = nil) throws -> IMessageSetupDraft {
    let selected = try selections ?? [draftSelection()]
    return try IMessageSetupDraft(setupReference: reference, naturalUserID: user, workspaceID: workspace,
        environmentIdentity: environment, expiresAt: expiry, expectedAccountID: account,
        sourceGeneration: source, selectedConversations: selected)
}

@Test func iMessageSetupDraftRoundTripPreservesOnlyOriginalIdentityAndSelectedIntent() throws {
    let draft = try draftFixture(selections: [draftSelection(), draftSelection("9223372036854775807", "iMessage;+;second-guid")])
    let data = try JSONEncoder().encode(draft)
    let restored = try JSONDecoder().decode(IMessageSetupDraft.self, from: data)
    #expect(restored == draft)
    #expect(restored.expiresAt == draftExpiry)
    #expect(restored.selectedConversations.map(\.nativeChatRowID) == ["1", "9223372036854775807"])
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["version", "setup_reference", "natural_user_id", "workspace_id", "environment_identity",
        "expires_at", "expected_account_id", "source_generation", "selected_conversations"])
    #expect(object["version"] as? Int == 1)
    let selected = try #require(object["selected_conversations"] as? [[String: Any]])
    #expect(Set(selected[0].keys) == ["native_chat_row_id", "expected_guid"])
    #expect(selected[0]["native_chat_row_id"] as? String == "1")
    for forbidden in ["body", "participants", "label", "session_id", "enrollment_ticket", "authorization_id", "snapshot_revision", "page_token", "local_consent", "machine_credential"] {
        #expect(object[forbidden] == nil)
        #expect(selected[0][forbidden] == nil)
    }
}

@Test func iMessageSetupDraftAllowsAnUnselectedJourneyBeforeAccountDiscovery() throws {
    let draft = try draftFixture(account: nil, source: nil, selections: [])
    let data = try JSONEncoder().encode(draft)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["expected_account_id"] == nil)
    #expect(object["source_generation"] == nil)
    #expect(try JSONDecoder().decode(IMessageSetupDraft.self, from: data) == draft)
    #expect(try draftFixture(selections: []).selectedConversations.isEmpty)
}

@Test(arguments: ["", "0", "-1", "+1", "01", "1.0", "1e2", " 1", "1\n", "١", "9223372036854775808"])
func iMessageSetupDraftRejectsNoncanonicalOrNonpositiveNativeRows(row: String) {
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftSelection(row) }
}

@Test(arguments: ["", " padded", "padded ", "private\nidentifier", "private\u{0}identifier", String(repeating: "g", count: 257)])
func iMessageSetupDraftBoundsPrivateIdentityWithoutControls(value: String) {
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftSelection("1", value) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(account: value) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(source: value) }
}

@Test func iMessageSetupDraftRequiresAccountAndSourceAsOneExpectedIdentity() throws {
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(account: nil) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(source: nil) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(account: nil, source: nil) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(account: nil, selections: []) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(source: nil, selections: []) }
}

@Test func iMessageSetupDraftBoundsAndDeduplicatesBothSelectedSelectors() throws {
    let selected = try (1...32).map { try draftSelection(String($0), "private-guid-\($0)") }
    #expect(try draftFixture(selections: selected).selectedConversations.count == 32)
    #expect(throws: IMessageSetupDraftError.invalidRecord) {
        try draftFixture(selections: selected + [draftSelection("33", "private-guid-33")])
    }
    #expect(throws: IMessageSetupDraftError.invalidRecord) {
        try draftFixture(selections: [draftSelection(), draftSelection("1", "another-guid")])
    }
    #expect(throws: IMessageSetupDraftError.invalidRecord) {
        try draftFixture(selections: [draftSelection(), draftSelection("2", "iMessage;-;private-guid")])
    }
}

@Test func iMessageSetupDraftUsesTheExistingPendingJourneyIdentityValidator() {
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(reference: String(repeating: "A", count: 42)) }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(user: "user\n") }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(workspace: "") }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(environment: "") }
    #expect(throws: IMessageSetupDraftError.invalidRecord) { try draftFixture(expiry: "2030-02-30T03:04:05Z") }
}

@Test func iMessageSetupDraftRequiresExactOriginalJourneyAndEnvironment() throws {
    let draft = try draftFixture()
    try draft.requireJourney(setupReference: draftReference, naturalUserID: "draft-user", workspaceID: "draft-workspace",
        environmentIdentity: "app|gateway|mcp", expiresAt: draftExpiry)
    #expect(throws: IMessageSetupDraftError.scopeMismatch) { try draft.requireEnvironment("another-profile") }
    let anotherReference = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    for changed in [(anotherReference, "draft-user", "draft-workspace", draftExpiry),
                    (draftReference, "other-user", "draft-workspace", draftExpiry),
                    (draftReference, "draft-user", "other-workspace", draftExpiry),
                    (draftReference, "draft-user", "draft-workspace", "2030-01-02T03:04:06Z")] {
        #expect(throws: IMessageSetupDraftError.conflictingJourney) {
            try draft.requireJourney(setupReference: changed.0, naturalUserID: changed.1, workspaceID: changed.2,
                environmentIdentity: "app|gateway|mcp", expiresAt: changed.3)
        }
    }
}

@Test func iMessageSetupDraftExpiredIntentRemainsReadableWithoutBecomingUsable() throws {
    let draft = try draftFixture()
    try draft.requireUsable(now: draft.expiry.addingTimeInterval(-1))
    #expect(throws: IMessageSetupDraftError.expired) { try draft.requireUsable(now: draft.expiry) }
    #expect(throws: IMessageSetupDraftError.expired) { try draft.requireUsable(now: draft.expiry.addingTimeInterval(1)) }
    let restored = try JSONDecoder().decode(IMessageSetupDraft.self, from: JSONEncoder().encode(draft))
    #expect(restored == draft)
    #expect(restored.expiresAt == draftExpiry)
}

@Test func iMessageSetupDraftRejectsForeignSchemaAndPartialExpectedIdentity() throws {
    let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draftFixture())) as? [String: Any])
    let mutations: [(String, Any?)] = [("version", 2), ("version", nil), ("setup_reference", 7),
        ("expected_account_id", nil), ("source_generation", nil), ("source_generation", NSNull()),
        ("selected_conversations", NSNull()), ("machine_credential", "must-never-persist"),
        ("session_id", "must-never-persist"), ("authorization_id", "must-never-persist"),
        ("snapshot_revision", 7), ("local_consent", true), ("page_token", "must-never-persist")]
    for (key, value) in mutations {
        var changed = original
        changed[key] = value
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(IMessageSetupDraft.self, from: data) }
    }
    for selection in [["native_chat_row_id": 1, "expected_guid": "private-guid"],
                      ["native_chat_row_id": "1", "expected_guid": "private-guid", "label": "must-never-persist"],
                      ["native_chat_row_id": "1"]] as [[String: Any]] {
        var changed = original
        changed["selected_conversations"] = [selection]
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(IMessageSetupDraft.self, from: data) }
    }
}

@Test func iMessageSetupDraftAndSelectedMappingsRedactDescriptionsAndReflection() throws {
    let draft = try draftFixture()
    var reflected = ""
    dump(draft, to: &reflected)
    for text in [String(describing: draft), String(reflecting: draft), reflected] {
        for privateValue in [draft.setupReference, draft.naturalUserID, draft.workspaceID, draft.environmentIdentity,
                             draft.expiresAt, draft.expectedAccountID!, draft.sourceGeneration!, draft.selectedConversations[0].expectedGUID] {
            #expect(!text.contains(privateValue))
        }
        #expect(text.contains("<redacted>"))
    }
    let selection = draft.selectedConversations[0]
    reflected = ""
    dump(selection, to: &reflected)
    for text in [String(describing: selection), String(reflecting: selection), reflected] {
        #expect(!text.contains(selection.nativeChatRowID))
        #expect(!text.contains(selection.expectedGUID))
        #expect(text.contains("<redacted>"))
    }
}

@Test(arguments: [IMessageSavedPageCommand.Action.edit, .resume, .resumeFromNow, .repair])
func iMessageSavedDraftIntentionSurvivesRestartWithoutPersistingAuthority(action: IMessageSavedPageCommand.Action) throws {
    let intent = try IMessageSetupDraft.SavedIntention(action: action, configID: "private-config", expectedConfigVersion: Int64.max)
    let draft = try IMessageSetupDraft(setupReference: draftReference, naturalUserID: "human", workspaceID: "workspace",
        environmentIdentity: "app|gateway|mcp", expiresAt: draftExpiry, savedIntention: intent)
    let data = try JSONEncoder().encode(draft)
    let restored = try JSONDecoder().decode(IMessageSetupDraft.self, from: data)
    #expect(restored == draft && restored.savedIntention?.expectedConfigVersion == Int64.max)
    #expect(!String(describing: restored.savedIntention!).contains("private-config"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let saved = try #require(object["saved_intention"] as? [String: Any])
    #expect(Set(saved.keys) == ["flow", "config_id", "expected_config_version"])
    #expect(saved["expected_config_version"] as? String == "9223372036854775807")
    let old = try draftFixture()
    #expect(try JSONDecoder().decode(IMessageSetupDraft.self, from: JSONEncoder().encode(old)).savedIntention == nil)
}

@Test(arguments: ["zero", "float", "overflow", "number", "unknown", "null", "send_flow"])
func iMessageSavedDraftIntentionRejectsMalformedOrExecutionAuthority(fault: String) throws {
    var raw: [String: Any] = ["flow": "edit_connection", "config_id": "config", "expected_config_version": "1"]
    switch fault {
    case "zero": raw["expected_config_version"] = "0"
    case "float": raw["expected_config_version"] = "1.0"
    case "overflow": raw["expected_config_version"] = "9223372036854775808"
    case "number": raw["expected_config_version"] = 1
    case "unknown": raw["native_approval_receipt"] = "forged"
    case "null": raw["config_id"] = NSNull()
    default: raw["flow"] = "send_test"
    }
    let data = try JSONSerialization.data(withJSONObject: raw)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(IMessageSetupDraft.SavedIntention.self, from: data) }
}
