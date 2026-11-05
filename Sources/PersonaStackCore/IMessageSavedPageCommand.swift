import Foundation

/// Untrusted page intentions. Neither an opaque config locator nor a version
/// supplies current workspace, Mac ownership, consent or execution authority.
public struct IMessageSavedPageCommand: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case edit = "edit_connection", resume = "resume_connection", resumeFromNow = "resume_from_now"
        case repair = "repair_connection", check = "check_connection", sendTest = "send_test", pause = "pause_connection"
    }
    public let action: Action
    public let scope: String
    public let configID: String
    public let expectedConfigVersion: Int64
    public let clientRequestID: String?

    public static func parse(_ body: Any) throws -> Self {
        guard let object = body as? [String: Any], object["version"] as? String == "1",
              let raw = object["action"] as? String, let action = Action(rawValue: raw),
              let scope = object["scope"] as? String, UUID(uuidString: scope)?.uuidString.lowercased() == scope,
              let config = object["config_id"] as? String, validToken(config), config != ".", config != "..",
              let version = object["expected_config_version"] as? String,
              let parsed = Int64(version), parsed > 0, String(parsed) == version else {
            throw IMessageSetupPageCommandError.invalidRequest
        }
        let required: Set<String> = ["version", "action", "scope", "config_id", "expected_config_version"]
        let keys = action == .sendTest ? required.union(["client_request_id"]) : required
        guard Set(object.keys) == keys else { throw IMessageSetupPageCommandError.invalidRequest }
        let key = object["client_request_id"] as? String
        guard action != .sendTest || (key.map(validToken) == true && key!.unicodeScalars.count <= 128) else { throw IMessageSetupPageCommandError.invalidRequest }
        return .init(action: action, scope: scope, configID: config, expectedConfigVersion: parsed, clientRequestID: key)
    }

    public static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.trimmingCharacters(in: .whitespacesAndNewlines) == value
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
