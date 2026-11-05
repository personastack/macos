import Foundation
import Testing
import PersonaStackCore

private let savedPageScope = UUID().uuidString.lowercased()
private func savedPageBody(_ action: IMessageSavedPageCommand.Action = .edit) -> [String: Any] {
    var body: [String: Any] = ["version": "1", "action": action.rawValue, "scope": savedPageScope,
        "config_id": "opaque-config", "expected_config_version": "9223372036854775807"]
    if action == .sendTest { body["client_request_id"] = "opaque-key" }
    return body
}

@Test(arguments: IMessageSavedPageCommand.Action.allCases)
func iMessageSavedPageCommandsKeepExactInt64AndFiniteFields(action: IMessageSavedPageCommand.Action) throws {
    let command = try IMessageSavedPageCommand.parse(savedPageBody(action))
    #expect(command.action == action && command.expectedConfigVersion == Int64.max)
    #expect(command.configID == "opaque-config" && command.scope == savedPageScope)
    #expect(command.clientRequestID == (action == .sendTest ? "opaque-key" : nil))
}

@Test(arguments: ["number", "bool", "float", "zero", "leading", "overflow", "null", "text", "receipt", "scope", "foreign_action", "key_on_check", "missing_key"])
func iMessageSavedPageCommandsRejectAuthorityAndMalformedVersion(fault: String) {
    var body = savedPageBody(fault == "missing_key" ? .sendTest : .check)
    switch fault {
    case "number": body["expected_config_version"] = Int64.max
    case "bool": body["expected_config_version"] = true
    case "float": body["expected_config_version"] = "1.0"
    case "zero": body["expected_config_version"] = "0"
    case "leading": body["expected_config_version"] = "01"
    case "overflow": body["expected_config_version"] = "9223372036854775808"
    case "null": body["expected_config_version"] = NSNull()
    case "text": body["text"] = "page cannot confirm this"
    case "receipt": body["native_approval_receipt"] = "untrusted"
    case "scope": body["scope"] = savedPageScope.uppercased()
    case "foreign_action": body["action"] = "execute"
    case "key_on_check": body["client_request_id"] = "key"
    default: body.removeValue(forKey: "client_request_id")
    }
    #expect(throws: IMessageSetupPageCommandError.invalidRequest) { try IMessageSavedPageCommand.parse(body) }
}

@Test(arguments: ["opaque-config", "with space", "with+plus", "with/slash", "café", "with&equals="])
func iMessageSavedHandoffOnlyCarriesCanonicalNavigationLocator(configID: String) throws {
    let url = try #require(URL(string: "personastack://manage-imessage?config_id=" + IMessageSavedHandoff.queryEscape(configID)))
    #expect(try IMessageSavedHandoff.parseDeepLink(url).configID == configID)
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSetupHandoff.parseDeepLink(url) }
}

@Test(arguments: ["personastack://manage-imessage/?config_id=c", "personastack://manage-imessage?config_id=c&config_id=c",
    "personastack://manage-imessage?config_id=c&action=send", "personastack://manage-imessage?config_id=c#fragment",
    "personastack://user@manage-imessage?config_id=c", "personastack://manage-imessage:443?config_id=c",
    "personastack://manage-imessage?config_id=.", "personastack://manage-imessage?config_id=..",
    "personastack://manage-imessage?config_id=%63", "personastack://manage-imessage?config_id=with%20space"])
func iMessageSavedHandoffRejectsAlternateAuthorityAndAmbiguousEncoding(raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(throws: IMessageSetupHandoffError.invalidRequest) { try IMessageSavedHandoff.parseDeepLink(url) }
}

@Test func iMessageLocalPauseIntentPersistsOnlyScopedRestrictiveLocatorsAndRejectsMalformedRecords() throws {
    let record = try IMessageLocalPauseIntent(installationID: "mac", configID: "saved", naturalUserID: "human", workspaceID: "workspace")
    #expect(try IMessageLocalPauseIntent.parse(record.preferences) == record)
    #expect(!String(reflecting: record).contains("human") && !String(describing: record).contains("saved"))
    let invalid: [[String: Any]] = [["generation": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"], ["generation": record.generation.uuidString.lowercased(), "ticket": "no"],
        ["generation": record.generation.uuidString.lowercased(), "natural_user_id": "human"], ["generation": NSNull()]]
    for bad in invalid {
        #expect(throws: (any Error).self) { try IMessageLocalPauseIntent.parse(bad) }
    }
}
