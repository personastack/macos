import Foundation

public enum IMessageSetupPageCommandError: Error, Equatable { case invalidRequest }

/// Finite page intentions only. The native document and fresh hosted scope
/// remain authority. No command accepts a credential, account, row or URL.
public struct IMessageSetupPageCommand: Equatable, Sendable {
    public enum Action: String, Sendable {
        case begin, state, continueSetup = "continue", checkPermissions = "check_permissions"
        case openMessages = "open_messages", requestMessagesAccess = "request_messages_access"
        case openFullDiskAccess = "open_full_disk_access", openAutomationSettings = "open_automation_settings"
        case openLoginItems = "open_login_items", restart, enableBackground = "enable_background"
        case allowMetadata = "allow_metadata", list, setSelected = "set_selected", verify, confirm, cancel
        case startAgain = "start_again"
    }
    public let action: Action
    public let scope: String
    public let handoff: IMessageSetupHandoff?
    public let query: String
    public let snapshotToken: String?
    public let pageToken: String?
    public let conversationIDs: [String]

    public static func parse(_ body: Any) throws -> Self {
        guard let object = body as? [String: Any], object["version"] as? String == "1",
              let raw = object["action"] as? String, let action = Action(rawValue: raw) else { throw IMessageSetupPageCommandError.invalidRequest }
        if action == .begin {
            let handoff = try IMessageSetupHandoff.parsePageCommand(body)
            return .init(action: action, scope: "", handoff: handoff, query: "", snapshotToken: nil, pageToken: nil, conversationIDs: [])
        }
        guard let scope = object["scope"] as? String,
              (action == .state && scope.isEmpty) || UUID(uuidString: scope)?.uuidString.lowercased() == scope else {
            throw IMessageSetupPageCommandError.invalidRequest
        }
        let additional: Set<String> = action == .list ? ["query", "snapshot_token", "page_token"] : (action == .setSelected ? ["conversation_ids"] : [])
        guard Set(object.keys).isSubset(of: additional.union(["version", "action", "scope"])) else { throw IMessageSetupPageCommandError.invalidRequest }
        let page = try parsePage(object, action: action)
        let ids = try parseSelection(object, action: action)
        return .init(action: action, scope: scope, handoff: nil, query: page.query,
            snapshotToken: page.snapshot, pageToken: page.page, conversationIDs: ids)
    }

    private static func parsePage(_ object: [String: Any], action: Action) throws -> (query: String, snapshot: String?, page: String?) {
        guard action == .list else { return ("", nil, nil) }
        guard let query = object["query"] as? String, query.unicodeScalars.count <= 128, !controls(query) else {
            throw IMessageSetupPageCommandError.invalidRequest
        }
        let snapshot = try token(object, key: "snapshot_token"), page = try token(object, key: "page_token")
        guard page == nil || snapshot != nil else { throw IMessageSetupPageCommandError.invalidRequest }
        return (query, snapshot, page)
    }
    private static func parseSelection(_ object: [String: Any], action: Action) throws -> [String] {
        guard action == .setSelected else { return [] }
        guard let ids = object["conversation_ids"] as? [String], ids.count <= 32,
              Set(ids).count == ids.count, ids.allSatisfy(validToken) else { throw IMessageSetupPageCommandError.invalidRequest }
        return ids
    }
    private static func token(_ object: [String: Any], key: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw as? String, validToken(value) else { throw IMessageSetupPageCommandError.invalidRequest }
        return value
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !controls(value) && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    }
    private static func controls(_ value: String) -> Bool { value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }
}
