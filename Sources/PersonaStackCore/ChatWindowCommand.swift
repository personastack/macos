import Foundation
import CoreFoundation

/// Window presentation only. The hosted page retains all product authorization.
public enum ChatWindowCommand: Equatable, Sendable {
    case sync(String)
    case open(String, String)
    case minimize, close, collapse, expand, pin
    case drag(Double, Double)

    public static func parse(_ body: Any, main: Bool) -> ChatWindowCommand? {
        guard let value = body as? [String: Any], value["version"] as? String == "1",
              let action = value["action"] as? String else { return nil }
        func keys(_ extra: Set<String> = []) -> Bool {
            Set(value.keys) == Set(["version", "action"]).union(extra)
        }
        if main {
            guard let scope = value["scope"] as? String, scope.count <= 512 else { return nil }
            if action == "sync", keys(["scope"]) { return .sync(scope) }
            if action == "open_persona_chat", !scope.isEmpty, keys(["scope", "persona_id"]),
               let persona = value["persona_id"] as? String, validPersonaID(persona) { return .open(persona, scope) }
            return nil
        }
        if action == "drag", keys(["dx", "dy"]),
           let x = value["dx"] as? NSNumber, let y = value["dy"] as? NSNumber,
           CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
           x.doubleValue.isFinite, y.doubleValue.isFinite,
           abs(x.doubleValue) <= 10_000, abs(y.doubleValue) <= 10_000 { return .drag(x.doubleValue, y.doubleValue) }
        guard keys() else { return nil }
        switch action {
        case "minimize": return .minimize
        case "close": return .close
        case "collapse": return .collapse
        case "expand": return .expand
        case "pin": return .pin
        default: return nil
        }
    }

    public static func validPersonaID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }
    }

    public static func popoutURL(appURL: URL, personaID: String) -> URL? {
        guard validPersonaID(personaID), var parts = URLComponents(url: appURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/user/personas/chat/desktop-popout"
        parts.queryItems = [URLQueryItem(name: "persona_id", value: personaID)]
        parts.fragment = nil
        return parts.url
    }

    public static func sameOrigin(_ url: URL, _ appURL: URL) -> Bool {
        permitsBridge(scheme: url.scheme ?? "", host: url.host ?? "", port: url.port ?? 0, mainFrame: true, appURL: appURL)
    }

    public static func permitsBridge(scheme: String, host: String, port: Int, mainFrame: Bool, appURL: URL) -> Bool {
        let actualPort = port == 0 ? (scheme == "https" ? 443 : 80) : port
        let expectedPort = appURL.port ?? (appURL.scheme == "https" ? 443 : 80)
        return mainFrame && scheme == appURL.scheme && host == appURL.host && actualPort == expectedPort
    }
}
