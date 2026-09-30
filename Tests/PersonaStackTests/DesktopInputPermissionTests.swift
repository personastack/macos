import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

@MainActor
private final class InputPermissionTarget: DesktopInputPermissionTarget {
    let pid: Int32 = 123
    var windowID = 456
    var clickCount = 0
    var text = ""
    let expectedText = "PersonaStack permission check test"
    var presented = false
    var invalidated = false
    func present() throws { presented = true }
    func requireCurrent() throws {
        guard presented, !invalidated else { throw CancellationError() }
    }
    func invalidate() { invalidated = true }
}

@MainActor
private final class InputPermissionCalls {
    let target: InputPermissionTarget
    var names: [String] = []
    var session: String?
    var transform: ((String, [String: Any]) throws -> [String: Any])?
    var afterCall: ((String) -> Void)?
    var deliverClick = true
    var deliverText = true

    init(_ target: InputPermissionTarget) { self.target = target }

    func call(_ name: String, _ data: Data) async throws -> Data {
        let arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(arguments["pid"] as? Int == Int(target.pid))
        #expect(arguments["window_id"] as? Int == target.windowID)
        let label = try #require(arguments["session"] as? String)
        #expect(label.hasPrefix("permissions-"))
        if let session { #expect(session == label) } else { session = label }
        let index = names.count
        names.append(name)
        var payload: [String: Any]
        switch (index, name) {
        case (0, "get_window_state"), (2, "get_window_state"):
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "include_screenshot", "include_accessibility_tree",
                                          "max_elements", "max_depth", "timeout_ms"])
            #expect(arguments["include_screenshot"] as? Bool == false)
            #expect(arguments["include_accessibility_tree"] as? Bool == true)
            #expect(arguments["max_elements"] as? Int == 32)
            #expect(arguments["max_depth"] as? Int == 8)
            #expect(arguments["timeout_ms"] as? Int == 1000)
            let snapshot = index == 0 ? "s00000001" : "s00000002"
            payload = ["pid": target.pid, "window_id": target.windowID, "snapshot_id": snapshot,
                       "truncated": false, "elements_complete": false,
                       "elements": [
                        ["element_index": 3, "element_token": "\(snapshot):3", "role": "AXButton",
                         "label": DesktopInputPermissionVerifier.buttonLabel, "enabled": true, "actions": ["AXPress"]],
                        ["element_index": 4, "element_token": "\(snapshot):4", "role": "AXTextField",
                         "label": DesktopInputPermissionVerifier.fieldLabel, "enabled": true],
                       ]]
        case (1, "click"):
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "element_token", "action", "button", "delivery_mode"])
            #expect(arguments["element_token"] as? String == "s00000001:3")
            #expect(arguments["action"] as? String == "press")
            #expect(arguments["button"] as? String == "left")
            #expect(arguments["delivery_mode"] as? String == "background")
            if deliverClick { target.clickCount += 1 }
            payload = ["path": "ax", "verified": false, "effect": "unverifiable"]
        case (3, "type_text"):
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "element_token", "text", "scope", "delay_ms", "delivery_mode"])
            #expect(arguments["element_token"] as? String == "s00000002:4")
            #expect(arguments["text"] as? String == target.expectedText)
            #expect(arguments["scope"] as? String == "window")
            #expect(arguments["delay_ms"] as? Int == 0)
            #expect(arguments["delivery_mode"] as? String == "background")
            if deliverText { target.text = target.expectedText }
            payload = ["path": "ax", "effect": "confirmed", "verified": true,
                       "characters": target.expectedText.count, "requested_chars": target.expectedText.count]
        default:
            Issue.record("Unexpected permission tool call: \(name)")
            throw CuaMCPProxyError.invalidToolName
        }
        var response: [String: Any] = ["jsonrpc": "2.0", "id": index + 1,
                                      "result": ["structuredContent": payload]]
        if let transform { response = try transform(name, response) }
        afterCall?(name)
        return try JSONSerialization.data(withJSONObject: response)
    }
}

@Suite
@MainActor
struct DesktopInputPermissionTests {
    @Test func completedInputProofCannotMoveToAnotherOwnerOrGrant() {
        let initial = DesktopPermissionObservation(.ready, detail: "", verificationKey: "owner:daemon:grant", requiresVerification: true)
        let stable = DesktopPermissionChecklist.finishCuaVerification(.accessibility, initial: initial, current: initial)
        #expect(stable.state == .ready && stable.verified && stable.verificationKey == initial.verificationKey)
        let changed = DesktopPermissionObservation(.ready, detail: "", verificationKey: "new-owner:daemon:grant", requiresVerification: true)
        let fenced = DesktopPermissionChecklist.finishCuaVerification(.accessibility, initial: initial, current: changed)
        #expect(fenced.state == .checking && !fenced.verified)
        let revoked = DesktopPermissionObservation(.notGranted, detail: "grant revoked")
        #expect(DesktopPermissionChecklist.finishCuaVerification(.accessibility, initial: initial, current: revoked) == revoked)
        let unknown = DesktopPermissionObservation(.ready, detail: "")
        #expect(DesktopPermissionChecklist.finishCuaVerification(.accessibility, initial: unknown, current: unknown).state == .checking)
    }
    @Test func ownedWindowInputRequiresFreshTokensAndNativeEffects() async throws {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {})
        #expect(calls.names == ["get_window_state", "click", "get_window_state", "type_text"])
        #expect(target.clickCount == 1)
        #expect(target.text == target.expectedText)
        #expect(target.invalidated)
    }

    @Test(arguments: ["pid", "window", "truncated", "degraded", "missing_token", "wrong_token", "duplicate", "disabled", "no_press", "wrong_role", "rpc_error", "tool_error", "wrong_type"])
    func unsafeSnapshotCausesNoInput(reason: String) async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.transform = { _, original in
            var response = original
            var result = try #require(response["result"] as? [String: Any])
            var payload = try #require(result["structuredContent"] as? [String: Any])
            var elements = try #require(payload["elements"] as? [[String: Any]])
            switch reason {
            case "pid": payload["pid"] = 999
            case "window": payload["window_id"] = 999
            case "truncated": payload["truncated"] = true
            case "degraded": payload["degraded"] = true
            case "missing_token": elements[0].removeValue(forKey: "element_token")
            case "wrong_token": elements[0]["element_token"] = "s00000002:3"
            case "duplicate": elements.append(elements[0])
            case "disabled": elements[0]["enabled"] = false
            case "no_press": elements[0]["actions"] = [] as [String]
            case "wrong_role": elements[0]["role"] = "AXTextField"
            case "rpc_error": response["error"] = ["code": -1]
            case "tool_error": result["isError"] = true
            default: payload["pid"] = true
            }
            payload["elements"] = elements
            result["structuredContent"] = payload
            response["result"] = result
            return response
        }
        await #expect(throws: CuaMCPProxyError.functionalProbeFailed) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {})
        }
        #expect(calls.names == ["get_window_state"])
        #expect(target.clickCount == 0)
        #expect(target.text.isEmpty)
        #expect(target.invalidated)
    }

    @Test(arguments: ["native_click", "native_text", "click_path", "click_noop", "text_path", "text_unverified", "text_count", "reused_snapshot"])
    func toolAcknowledgmentAloneDoesNotProveInput(reason: String) async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.deliverClick = reason != "native_click"
        calls.deliverText = reason != "native_text"
        calls.transform = { name, original in
            var response = original
            var result = try #require(response["result"] as? [String: Any])
            var payload = try #require(result["structuredContent"] as? [String: Any])
            if name == "click", reason == "click_path" { payload["path"] = "cgevent" }
            if name == "click", reason == "click_noop" { payload["effect"] = "suspected_noop" }
            if name == "type_text", reason == "text_path" { payload["path"] = "key_events" }
            if name == "type_text", reason == "text_unverified" { payload["verified"] = false }
            if name == "type_text", reason == "text_count" { payload["characters"] = 1 }
            if name == "get_window_state", calls.names.count == 3, reason == "reused_snapshot" { payload["snapshot_id"] = "s00000001" }
            result["structuredContent"] = payload
            response["result"] = result
            return response
        }
        await #expect(throws: CuaMCPProxyError.functionalProbeFailed) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {})
        }
        #expect(target.invalidated)
        if ["native_click", "click_path", "click_noop"].contains(reason) { #expect(calls.names.count == 2) }
        if reason == "reused_snapshot" { #expect(calls.names.count == 3) }
    }

    @Test func cancellationAfterClickPreventsAnyFurtherInput() async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.afterCall = { name in if name == "click" { withUnsafeCurrentTask { $0?.cancel() } } }
        let task = Task { @MainActor in
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {})
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.names == ["get_window_state", "click"])
        #expect(target.text.isEmpty)
        #expect(target.invalidated)
    }

    @Test(arguments: ["lifecycle", "window"])
    func changedOwnerPreventsInput(reason: String) async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        var current = true
        calls.afterCall = { _ in
            if reason == "window" { target.windowID += 1 } else { current = false }
        }
        await #expect(throws: CancellationError.self) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {
                guard current else { throw CancellationError() }
            })
        }
        #expect(calls.names == ["get_window_state"])
        #expect(target.clickCount == 0)
        #expect(target.invalidated)
    }
}
