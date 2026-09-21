import Foundation

/// Window presentation only. The hosted page retains all stack authorization.
public enum StackWindowView: String, Equatable, Sendable {
    case graph, stream
}

public enum StackWindowCommand: Equatable, Sendable {
    case open(StackWindowView, String)

    public static func parse(_ body: Any) -> StackWindowCommand? {
        guard let value = body as? [String: Any], value["version"] as? String == "1",
              value["action"] as? String == "open_stack_view",
              Set(value.keys) == Set(["version", "action", "stack_id", "view"]),
              let stackID = value["stack_id"] as? String, validStackID(stackID),
              let rawView = value["view"] as? String, let view = StackWindowView(rawValue: rawView) else { return nil }
        return .open(view, stackID)
    }

    public static func validStackID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }

    public static func popoutURL(appURL: URL, stackID: String, view: StackWindowView) -> URL? {
        guard validStackID(stackID), var parts = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/user/stacks/desktop-popout"
        parts.queryItems = [URLQueryItem(name: "stack_id", value: stackID), URLQueryItem(name: "view", value: view.rawValue)]
        parts.fragment = nil
        return parts.url
    }
}
