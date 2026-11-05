import Foundation

/// A navigation locator only. Resolution always uses the configured origin and
/// freshly authorized current human/workspace. Opening it executes no action.
public struct IMessageSavedHandoff: Equatable, Sendable {
    public let configID: String
    public init(configID: String) throws {
        guard IMessageSavedPageCommand.validToken(configID), configID != ".", configID != ".." else { throw IMessageSetupHandoffError.invalidRequest }
        self.configID = configID
    }
    public static func parseDeepLink(_ url: URL) throws -> Self {
        let prefix = "personastack://manage-imessage?config_id="
        guard url.absoluteString.hasPrefix(prefix), url.absoluteString.utf8.count <= 850,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "personastack", parts.host == "manage-imessage", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let raw = parts.percentEncodedQuery, raw.hasPrefix("config_id="),
              let id = String(raw.dropFirst("config_id=".count)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
            throw IMessageSetupHandoffError.invalidRequest
        }
        let result = try Self(configID: id)
        guard prefix + Self.queryEscape(id) == url.absoluteString else { throw IMessageSetupHandoffError.invalidRequest }
        return result
    }
    public static func queryEscape(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: String(UnicodeScalar(byte))
            case 32: "+"
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
