import Foundation

/// Window presentation only. The hosted page retains all stack authorization.
public enum StackWindowView: String, Equatable, Sendable {
    case graph, stream
}

public enum StackWindowCommand: Equatable, Sendable {
    case open(StackWindowView, String)
    case openPersonaActivity(String)

    public static func parse(_ body: Any) -> StackWindowCommand? {
        guard let value = body as? [String: Any], value["version"] as? String == "1",
              let action = value["action"] as? String else { return nil }
        if action == "open_stack_view", Set(value.keys) == Set(["version", "action", "stack_id", "view"]),
           let stackID = value["stack_id"] as? String, validStackID(stackID),
           let rawView = value["view"] as? String, let view = StackWindowView(rawValue: rawView) {
            return .open(view, stackID)
        }
        if action == "open_persona_activity", Set(value.keys) == Set(["version", "action", "persona_id"]),
           let personaID = value["persona_id"] as? String, validStackID(personaID) {
            return .openPersonaActivity(personaID)
        }
        return nil
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

    public static func personaActivityURL(appURL: URL, personaID: String) -> URL? {
        guard validStackID(personaID), var parts = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/user/personas/activity/desktop-popout"
        parts.queryItems = [URLQueryItem(name: "persona_id", value: personaID)]
        parts.fragment = nil
        return parts.url
    }
}
