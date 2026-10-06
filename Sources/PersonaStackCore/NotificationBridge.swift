import Foundation

public enum NotificationBridge {
    public static func isNewConcernEvent(_ body: Any) -> Bool {
        guard let payload = body as? [String: Any], payload["event"] as? String == "created" else { return false }
        if payload["version"] as? String == "1" { return payload.count == 2 }
        return payload["version"] as? String == "2" && payload.count == 4 && navigationIDs(payload) != nil
    }

    public static func notificationInfo(_ body: Any, appURL: URL) -> [String: String]? {
        guard isNewConcernEvent(body), let payload = body as? [String: Any],
              var origin = URLComponents(url: appURL, resolvingAgainstBaseURL: false),
              origin.user == nil, origin.password == nil else { return nil }
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let originURL = origin.url else { return nil }
        var info = ["app_origin": originURL.absoluteString]
        if let ids = navigationIDs(payload) {
            info["concern_id"] = ids.concern
            info["workspace_id"] = ids.workspace
        }
        return info
    }

    public static func concernDestination(_ info: [AnyHashable: Any], appURL: URL) -> URL? {
        let keys = Set(info.keys.compactMap { $0 as? String })
        guard keys.count == info.count,
              keys == ["app_origin"] || keys == ["app_origin", "concern_id", "workspace_id"],
              let origin = info["app_origin"] as? String, let originURL = URL(string: origin),
              originURL.user == nil, originURL.password == nil,
              ChatWindowCommand.sameOrigin(originURL, appURL),
              var parts = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/user/concerns"
        parts.query = nil
        parts.fragment = nil
        if keys.count == 3 {
            guard let concern = info["concern_id"] as? String, let workspace = info["workspace_id"] as? String,
                  let ids = navigationIDs(["concern_id": concern, "workspace_id": workspace]) else { return nil }
            parts.queryItems = [URLQueryItem(name: "workspace_id", value: ids.workspace),
                                URLQueryItem(name: "concern_id", value: ids.concern)]
        }
        return parts.url
    }

    private static func navigationIDs(_ payload: [String: Any]) -> (concern: String, workspace: String)? {
        guard let concern = payload["concern_id"] as? String,
              !concern.isEmpty, concern.utf8.count <= 512,
              concern.trimmingCharacters(in: .whitespacesAndNewlines) == concern,
              !concern.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let workspace = payload["workspace_id"] as? String,
              ChatWindowCommand.validPersonaID(workspace) else { return nil }
        return (concern, workspace)
    }
}
