import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor @Test(arguments: ["success", "keystrokes", "heuristic", "multipleTabs", "incomplete", "multipleFocus", "foreignTarget", "staleRef", "revoked"])
func pageTypingUsesOnlyExactTypedBrowserRoute(mode: String) async throws {
    var calls: [String] = []
    var current = true
    let fields: [String: DesktopControlJSONValue] = ["action": .string(mode == "keystrokes" ? "type_keystrokes" : "insert_text"),
        "pid": .number(123), "window_id": .number(45), "text": .string("sample"), "session": .string("owned")]
    do {
        _ = try await DesktopCuaPageAdapter.type(fields, call: { name, data in
            calls.append(name)
            let arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(arguments["session"] as? String == "owned")
            let body: [String: Any]
            if calls.count == 1 {
                #expect(name == "get_browser_state")
                #expect(arguments["pid"] as? Int == 123)
                #expect(arguments["window_id"] as? Int == 45)
                var tabs: [[String: Any]] = [["tab_id": "tab-1", "active": true, "url": "https://example.test"]]
                if mode == "multipleTabs" { tabs.append(["tab_id": "tab-2", "active": true]) }
                body = ["status": "ok", "mode": "bind", "binding_quality": mode == "heuristic" ? "heuristic" : "exact",
                        "binding_route": "native_cdp_window", "mutation_allowed": true, "target_id": "target-1", "tabs": tabs]
            } else if calls.count == 2 {
                #expect(name == "get_browser_state")
                #expect(arguments["target_id"] as? String == "target-1")
                #expect(arguments["tab_id"] as? String == "tab-1")
                #expect(arguments["snapshot_format"] as? String == "semantic_v2")
                var refs: [[String: Any]] = [["ref": mode == "staleRef" ? "p0:1" : "p1:1", "states": ["focused": true],
                                             "actions": ["type"], "visibility": "in_viewport"]]
                if mode == "multipleFocus" { refs.append(refs[0]) }
                if mode == "revoked" { current = false }
                body = ["status": "ok", "mode": "snapshot", "target_id": mode == "foreignTarget" ? "foreign" : "target-1",
                        "tab_id": "tab-1", "snapshot": ["format": "semantic_v2", "id": "p1", "complete": mode != "incomplete"], "refs": refs]
            } else {
                #expect(name == "browser_type")
                #expect(arguments["target_id"] as? String == "target-1")
                #expect(arguments["tab_id"] as? String == "tab-1")
                #expect(arguments["ref"] as? String == "p1:1")
                #expect(arguments["text"] as? String == "sample")
                #expect(arguments["replace"] as? Bool == false)
                #expect(arguments["mode"] as? String == (mode == "keystrokes" ? "keystrokes" : "insert_text"))
                body = ["status": "ok"]
            }
            return try JSONSerialization.data(withJSONObject: ["result": ["structuredContent": body]])
        }, requireCurrent: { if !current { throw CancellationError() } })
        #expect(["success", "keystrokes"].contains(mode))
    } catch {
        #expect(!["success", "keystrokes"].contains(mode))
    }
    #expect(calls.filter { $0 == "browser_type" }.count == (["success", "keystrokes"].contains(mode) ? 1 : 0))
}
