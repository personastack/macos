import Foundation
import Testing
import PersonaStackCore

private let iMessagePageScope = "f8b6e202-caf4-4dfb-a828-551039c16eda"

@Test func iMessageSetupPageCommandPinsFiniteVersionAndExistingHandoff() throws {
    let reference = String(repeating: "A", count: 43)
    let begin = try IMessageSetupPageCommand.parse(["version": "1", "action": "begin", "setup_reference": reference])
    #expect(begin.handoff?.setupReference == reference && begin.scope.isEmpty)
    for action in ["state", "continue", "check_permissions", "open_messages", "request_messages_access", "open_full_disk_access",
        "open_automation_settings", "open_login_items", "restart", "enable_background", "allow_metadata", "verify", "confirm", "cancel", "start_again"] {
        let command = try IMessageSetupPageCommand.parse(["version": "1", "action": action, "scope": iMessagePageScope])
        #expect(command.action.rawValue == action && command.scope == iMessagePageScope)
    }
    let state = try IMessageSetupPageCommand.parse(["version": "1", "action": "state", "scope": ""])
    #expect(state.action == .state)
}

@Test func iMessageSetupPageCommandBoundsLocalSelectionAndPagingWithoutAuthorityFields() throws {
    let ids = (0..<32).map { "option-\($0)" }
    let selected = try IMessageSetupPageCommand.parse(["version": "1", "action": "set_selected", "scope": iMessagePageScope, "conversation_ids": ids])
    #expect(selected.conversationIDs == ids)
    let page = try IMessageSetupPageCommand.parse(["version": "1", "action": "list", "scope": iMessagePageScope,
        "query": "Friends", "snapshot_token": "snapshot", "page_token": "next"])
    #expect(page.query == "Friends" && page.pageToken == "next")
    let empty = try IMessageSetupPageCommand.parse(["version": "1", "action": "set_selected", "scope": iMessagePageScope, "conversation_ids": [String]()])
    #expect(empty.conversationIDs.isEmpty)
}

@Test func iMessageSetupPageCommandRejectsUntrustedOrUnboundedIntent() {
    let bodies: [[String: Any]] = [
    ["version": 1, "action": "state", "scope": iMessagePageScope],
    ["version": "2", "action": "state", "scope": iMessagePageScope],
    ["version": "1", "action": "send", "scope": iMessagePageScope],
    ["version": "1", "action": "confirm", "scope": ""],
    ["version": "1", "action": "confirm", "scope": iMessagePageScope, "read_enabled": true],
    ["version": "1", "action": "continue", "scope": iMessagePageScope, "workspace_id": "foreign"],
    ["version": "1", "action": "continue", "scope": iMessagePageScope, "installation_id": "foreign"],
    ["version": "1", "action": "list", "scope": iMessagePageScope, "query": "", "page_token": "next"],
    ["version": "1", "action": "list", "scope": iMessagePageScope, "query": String(repeating: "a", count: 129)],
    ["version": "1", "action": "list", "scope": iMessagePageScope, "query": "a\n"],
    ["version": "1", "action": "list", "scope": iMessagePageScope, "query": "", "snapshot_token": NSNull()],
    ["version": "1", "action": "set_selected", "scope": iMessagePageScope, "conversation_ids": ["same", "same"]],
    ["version": "1", "action": "set_selected", "scope": iMessagePageScope, "conversation_ids": (0..<33).map { "option-\($0)" }],
    ]
    for body in bodies { #expect(throws: (any Error).self) { try IMessageSetupPageCommand.parse(body) } }
}
