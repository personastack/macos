import Foundation
import PersonaStackCore

/// Compatibility typing uses the reviewed typed browser route. No raw CDP,
/// arbitrary JavaScript, CSS approximation or legacy-mutation flag is used.
@MainActor
enum DesktopCuaPageAdapter {
    static let typingActions: Set<String> = ["insert_text", "type_keystrokes"]
    typealias Call = @MainActor (String, Data) async throws -> Data

    static func type(_ fields: [String: DesktopControlJSONValue], call: Call,
                     requireCurrent: () throws -> Void) async throws -> [String: Any] {
        let permitted: Set<String> = ["session", "pid", "window_id", "action", "text", "target_url_contains"]
        guard Set(fields.keys).isSubset(of: permitted),
              case .string(let action)? = fields["action"], typingActions.contains(action),
              case .string(let text)? = fields["text"],
              case .string(let session)? = fields["session"], !session.isEmpty,
              let pid = fields["pid"], let window = fields["window_id"] else { throw unavailable() }
        let selectedURL: String?
        if let value = fields["target_url_contains"] {
            guard case .string(let substring) = value, !substring.isEmpty else { throw unavailable() }
            selectedURL = substring
        } else { selectedURL = nil }

        func invoke(_ name: String, _ arguments: [String: DesktopControlJSONValue]) async throws -> [String: Any] {
            try Task.checkCancellation()
            try requireCurrent()
            var owned = arguments
            owned["session"] = .string(session)
            try CuaToolCatalog.validate(tool: name, arguments: .object(owned))
            let data = try await call(name, JSONEncoder().encode(DesktopControlJSONValue.object(owned)))
            try Task.checkCancellation()
            try requireCurrent()
            guard data.count <= 8 * 1024 * 1024,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
                  let result = root["result"] as? [String: Any] else { throw unavailable() }
            guard result["isError"] as? Bool != true else { throw DesktopCuaFailure.from(result, tool: name) }
            return result
        }
        let binding = try body(await invoke("get_browser_state", ["pid": pid, "window_id": window]))
        let (target, tab) = try exactTab(binding, matching: selectedURL)
        let snapshot = try body(await invoke("get_browser_state", ["target_id": .string(target),
            "tab_id": .string(tab), "snapshot_format": .string("semantic_v2"), "include_screenshot": .bool(false)]))
        let ref = try focusedRef(snapshot, target: target, tab: tab)
        return try await invoke("browser_type", ["target_id": .string(target), "tab_id": .string(tab),
            "ref": .string(ref), "text": .string(text), "replace": .bool(false),
            "mode": .string(action == "insert_text" ? "insert_text" : "keystrokes")])
    }

    private static func body(_ result: [String: Any]) throws -> [String: Any] {
        guard let body = result["structuredContent"] as? [String: Any], body["status"] as? String == "ok" else {
            throw unavailable()
        }
        return body
    }

    private static func exactTab(_ body: [String: Any], matching substring: String?) throws -> (String, String) {
        guard body["mode"] as? String == "bind", body["binding_quality"] as? String == "exact",
              body["binding_route"] as? String == "native_cdp_window", body["mutation_allowed"] as? Bool == true,
              let target = body["target_id"] as? String, !target.isEmpty,
              let tabs = body["tabs"] as? [[String: Any]], tabs.count <= 256 else { throw unavailable() }
        let matches = tabs.filter { tab in
            if let substring { return (tab["url"] as? String)?.contains(substring) == true }
            return tab["active"] as? Bool == true
        }
        guard matches.count == 1, let tab = matches[0]["tab_id"] as? String, !tab.isEmpty else { throw unavailable() }
        return (target, tab)
    }

    private static func focusedRef(_ body: [String: Any], target: String, tab: String) throws -> String {
        guard body["mode"] as? String == "snapshot", body["target_id"] as? String == target,
              body["tab_id"] as? String == tab, let snapshot = body["snapshot"] as? [String: Any],
              snapshot["format"] as? String == "semantic_v2", snapshot["complete"] as? Bool == true,
              let id = snapshot["id"] as? String, !id.isEmpty,
              let refs = body["refs"] as? [[String: Any]], refs.count <= 300 else { throw unavailable() }
        let focused = refs.filter { ($0["states"] as? [String: Any])?["focused"] as? Bool == true }
        guard focused.count == 1, let ref = focused[0]["ref"] as? String, ref.hasPrefix(id + ":"),
              let index = Int(ref.dropFirst(id.count + 1)), index >= 0,
              (focused[0]["actions"] as? [String])?.contains("type") == true,
              (focused[0]["states"] as? [String: Any])?["disabled"] as? Bool != true,
              ["in_viewport", "near_viewport"].contains(focused[0]["visibility"] as? String ?? "") else { throw unavailable() }
        return ref
    }

    private static func unavailable() -> DesktopCuaFailure {
        DesktopCuaFailure(code: "browser_route_unavailable",
                          message: "CUA could not identify one current focused editable field in the exact approved browser window. Read current browser state and use a typed browser action.")
    }
}
