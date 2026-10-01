import AppKit
import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

// Cua tag cua-driver-rs-v0.29.1, commit 7a8f66ad04e62fccb18cca9965f2964fcaee124e.
// Public MCP projection: cua-driver-core/src/tool.rs::publish_action_result and
// action_record.rs::from_legacy/public_result. These intentionally omit the
// platform handler's private path, verified, characters and requested_chars.
private enum Cua0291InputReplies {
    static let click = Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"Accessibility action delivered; verify its effect."}],"structuredContent":{"route":"accessibility","effect":"unverifiable","delivery":{"mode":"background"},"summary":"Accessibility action delivered; verify its effect."}}}"#.utf8)
    static let typeText = Data(#"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"Text value confirmed."}],"structuredContent":{"route":"accessibility","effect":"confirmed","delivery":{"mode":"background","delivered_count":34},"evidence":[{"kind":"value_readback"}],"summary":"Text value confirmed."}}}"#.utf8)

    static func payload(_ data: Data) throws -> [String: Any] {
        let reply = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(reply["result"] as? [String: Any])
        return try #require(result["structuredContent"] as? [String: Any])
    }
}

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
    var snapshotCount = 0
    var currentSnapshot = ""

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
        switch name {
        case "get_window_state":
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "include_screenshot", "include_accessibility_tree",
                                          "max_elements", "max_depth", "timeout_ms"])
            #expect(arguments["include_screenshot"] as? Bool == false)
            #expect(arguments["include_accessibility_tree"] as? Bool == true)
            #expect(arguments["max_elements"] as? Int == 32)
            #expect(arguments["max_depth"] as? Int == 8)
            #expect(arguments["timeout_ms"] as? Int == 1000)
            snapshotCount += 1
            let snapshot = String(format: "s%08x", snapshotCount)
            currentSnapshot = snapshot
            payload = ["pid": target.pid, "window_id": target.windowID, "snapshot_id": snapshot,
                       "truncated": false, "elements_complete": false,
                       "elements": [
                        ["element_index": 3, "element_token": "\(snapshot):3", "role": "AXButton",
                         "label": DesktopInputPermissionVerifier.buttonLabel, "enabled": true, "actions": ["AXPress"]],
                        ["element_index": 4, "element_token": "\(snapshot):4", "role": "AXTextField",
                         "label": DesktopInputPermissionVerifier.fieldLabel, "enabled": true],
                       ]]
        case "click":
            #expect(names.filter { $0 == "click" }.count == 1)
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "element_token", "action", "button", "delivery_mode"])
            #expect(arguments["element_token"] as? String == "\(currentSnapshot):3")
            #expect(arguments["action"] as? String == "press")
            #expect(arguments["button"] as? String == "left")
            #expect(arguments["delivery_mode"] as? String == "background")
            if deliverClick { target.clickCount += 1 }
            payload = try Cua0291InputReplies.payload(Cua0291InputReplies.click)
        case "type_text":
            #expect(names.filter { $0 == "type_text" }.count == 1)
            #expect(Set(arguments.keys) == ["session", "pid", "window_id", "element_token", "text", "scope", "delay_ms", "delivery_mode"])
            #expect(arguments["element_token"] as? String == "\(currentSnapshot):4")
            #expect(arguments["text"] as? String == target.expectedText)
            #expect(arguments["scope"] as? String == "window")
            #expect(arguments["delay_ms"] as? Int == 0)
            #expect(arguments["delivery_mode"] as? String == "background")
            if deliverText { target.text = target.expectedText }
            payload = try Cua0291InputReplies.payload(Cua0291InputReplies.typeText)
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
    @Test func completedCaptureProofCannotMoveToAnotherOwnerOrGrant() {
        let initial = DesktopPermissionObservation(.ready, detail: "", verificationKey: "owner:daemon:grant", requiresVerification: true)
        let stable = DesktopPermissionChecklist.finishCuaVerification(.screenRecording, initial: initial, current: initial)
        #expect(stable.state == .ready && stable.verified && stable.verificationKey == initial.verificationKey)
        let changed = DesktopPermissionObservation(.ready, detail: "", verificationKey: "new-owner:daemon:grant", requiresVerification: true)
        let fenced = DesktopPermissionChecklist.finishCuaVerification(.screenRecording, initial: initial, current: changed)
        #expect(fenced.state == .checking && !fenced.verified)
        let revoked = DesktopPermissionObservation(.notGranted, detail: "grant revoked")
        #expect(DesktopPermissionChecklist.finishCuaVerification(.screenRecording, initial: initial, current: revoked) == revoked)
        let unknown = DesktopPermissionObservation(.ready, detail: "")
        #expect(DesktopPermissionChecklist.finishCuaVerification(.screenRecording, initial: unknown, current: unknown).state == .checking)
    }
    @Test func ownedWindowInputRequiresFreshTokensAndNativeEffects() async throws {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        try await DesktopInputPermissionVerifier.verify(target: target, call: { name, arguments in
            let reply = try await calls.call(name, arguments)
            switch name {
            case "click": return Cua0291InputReplies.click
            case "type_text": return Cua0291InputReplies.typeText
            default: return reply
            }
        }, isCurrent: {}, settle: {})
        #expect(calls.names == ["get_window_state", "click", "get_window_state", "type_text"])
        #expect(target.clickCount == 1)
        #expect(target.text == target.expectedText)
        #expect(target.invalidated)
    }

    @Test func nativeTextCellExportsTheLabelConsumedByThePinnedDriver() throws {
        let field = DesktopInputPermissionWindow.makeVerificationField()
        let children = try #require(field.accessibilityChildren())
        let cell = try #require(children.first as? NSTextFieldCell)
        #expect(cell.accessibilityRole() == .textField)
        #expect(cell.accessibilityTitle() == DesktopInputPermissionVerifier.fieldLabel)
        #expect(cell.accessibilityLabel() == DesktopInputPermissionVerifier.fieldLabel)
        #expect(cell.isAccessibilityEnabled())
        // Exercise AppKit's real cell-backed value, not a mirrored fake string.
        cell.setAccessibilityValue("Disposable native value")
        #expect(field.stringValue == "Disposable native value")
    }

    @Test func verificationWindowExportsDialogScopeWithoutPresentingIt() {
        _ = NSApplication.shared
        let window = DesktopInputPermissionWindow.makeVerificationWindow()
        #expect(window.accessibilitySubrole() == .dialog)
        #expect(!window.isVisible)
    }

    @Test func nativeCallbacksMaySettleAfterTheToolReplyWithoutRepeatingInput() async throws {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.deliverClick = false
        calls.deliverText = false
        var waits = 0
        try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {
            waits += 1
            #expect(!target.invalidated)
            if calls.names.last == "click" { target.clickCount = 1 }
            if calls.names.last == "type_text" { target.text = target.expectedText }
        })
        #expect(waits == 2)
        #expect(calls.names == ["get_window_state", "click", "get_window_state", "type_text"])
        #expect(target.invalidated)
    }

    @Test(arguments: ["ax_window_unresolved:", "ax_tree_empty:"])
    func newlyPresentedWindowMaySettleBeforeAnyInput(reason: String) async throws {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.transform = { name, original in
            guard name == "get_window_state", calls.names.count == 1 else { return original }
            return ["result": ["structuredContent": ["pid": target.pid, "window_id": target.windowID,
                "truncated": false, "degraded": true, "degraded_reason": reason, "elements": [] as [String]]]]
        }
        var waits = 0
        try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {
            waits += 1
            #expect(target.clickCount == 0 && target.text.isEmpty && !target.invalidated)
        })
        #expect(waits == 1)
        #expect(calls.names == ["get_window_state", "get_window_state", "click", "get_window_state", "type_text"])
    }

    @Test func unresolvedWindowStopsAfterBoundedReadsWithNoInput() async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.transform = { _, _ in
            ["result": ["structuredContent": ["pid": target.pid, "window_id": target.windowID,
                "truncated": false, "degraded": true, "degraded_reason": "ax_window_unresolved:", "elements": [] as [String]]]]
        }
        await #expect(throws: DesktopInputPermissionVerificationError.failed(.button, .snapshot)) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {})
        }
        #expect(calls.names == ["get_window_state", "get_window_state", "get_window_state"])
        #expect(target.clickCount == 0 && target.text.isEmpty && target.invalidated)
    }

    @Test func cancellationDuringNativeSettleStopsBeforeTextAndInvalidatesWindow() async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.deliverClick = false
        let task = Task { @MainActor in
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.names == ["get_window_state", "click"])
        #expect(target.text.isEmpty && target.invalidated)
    }

    @Test func failureNamesTheStageWithoutEchoingRuntimeContent() async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.deliverClick = false
        calls.transform = { name, reply in
            if name == "click" { return ["result": ["isError": true, "content": [["type": "text", "text": "private upstream content"]]]] }
            return reply
        }
        let failure = DesktopInputPermissionVerificationError.failed(.click, .rejected)
        await #expect(throws: failure) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {})
        }
        #expect(failure.localizedDescription == "Accessibility verification stopped while clicking the test button: the desktop runtime rejected the operation. Retry Setup Accessibility.")
        #expect(calls.names == ["get_window_state", "click"])
        #expect(target.clickCount == 0 && target.text.isEmpty)
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
        await #expect(throws: DesktopInputPermissionVerificationError.self) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {})
        }
        #expect(calls.names == ["get_window_state"])
        #expect(target.clickCount == 0)
        #expect(target.text.isEmpty)
        #expect(target.invalidated)
    }

    @Test(arguments: ["native_click", "native_text", "click_path", "click_noop", "click_delivery", "text_path", "text_unverified", "text_count", "text_evidence", "text_refused", "legacy_reply", "reused_snapshot"])
    func toolAcknowledgmentAloneDoesNotProveInput(reason: String) async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.deliverClick = reason != "native_click"
        calls.deliverText = reason != "native_text"
        calls.transform = { name, original in
            var response = original
            var result = try #require(response["result"] as? [String: Any])
            var payload = try #require(result["structuredContent"] as? [String: Any])
            if name == "click", reason == "click_path" { payload["route"] = "synthetic_events" }
            if name == "click", reason == "click_noop" { payload["effect"] = "suspected_noop" }
            if name == "type_text", reason == "text_path" { payload["route"] = "synthetic_events" }
            if name == "type_text", reason == "text_unverified" { payload["effect"] = "unverifiable" }
            if name == "type_text", reason == "text_count" { payload["delivery"] = ["mode": "background", "delivered_count": 1] }
            if name == "click", reason == "click_delivery" { payload["delivery"] = ["mode": "foreground"] }
            if name == "click", reason == "legacy_reply" { payload = ["path": "ax", "verified": false, "effect": "unverifiable"] }
            if name == "type_text", reason == "text_evidence" { payload.removeValue(forKey: "evidence") }
            if name == "type_text", reason == "text_refused" { payload["effect"] = "refused"; payload["error"] = ["code": "permission_denied"] }
            if name == "get_window_state", calls.names.count == 3, reason == "reused_snapshot" { payload["snapshot_id"] = "s00000001" }
            result["structuredContent"] = payload
            response["result"] = result
            return response
        }
        await #expect(throws: DesktopInputPermissionVerificationError.self) {
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {})
        }
        #expect(target.invalidated)
        if ["native_click", "click_path", "click_noop", "click_delivery", "legacy_reply"].contains(reason) { #expect(calls.names.count == 2) }
        if reason == "reused_snapshot" { #expect(calls.names.count == 3) }
    }

    @Test func cancellationAfterClickPreventsAnyFurtherInput() async {
        let target = InputPermissionTarget()
        let calls = InputPermissionCalls(target)
        calls.afterCall = { name in if name == "click" { withUnsafeCurrentTask { $0?.cancel() } } }
        let task = Task { @MainActor in
            try await DesktopInputPermissionVerifier.verify(target: target, call: calls.call, isCurrent: {}, settle: {})
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
