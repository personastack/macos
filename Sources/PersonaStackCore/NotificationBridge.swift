import Foundation

public enum NotificationBridge {
    public static func isNewConcernEvent(_ body: Any) -> Bool {
        guard let payload = body as? [String: Any], payload.count == 2,
              payload["version"] as? String == "1",
              payload["event"] as? String == "created" else {
            return false
        }
        return true
    }
}
