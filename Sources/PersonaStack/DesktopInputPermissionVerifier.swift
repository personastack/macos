import Foundation
import PersonaStackCore

enum DesktopInputPermissionVerificationError: LocalizedError {
    case busy
    var errorDescription: String? {
        "Desktop Control is busy or recovering. Wait for the remote task to finish, then retry Setup Accessibility."
    }
}

@MainActor
protocol DesktopInputPermissionTarget: AnyObject {
    var pid: Int32 { get }
    var windowID: Int { get }
    var clickCount: Int { get }
    var text: String { get }
    var expectedText: String { get }
    func present() throws
    func requireCurrent() throws
    func invalidate()
}

/// Explicit native setup only. Every action uses the exact owned window and
/// a fresh upstream element token. Native controls provide the effect proof.
@MainActor
enum DesktopInputPermissionVerifier {
    static let buttonLabel = "Verify Desktop Control Click"
    static let fieldLabel = "Desktop Control Verification Text"
    typealias ToolCall = @MainActor (String, Data) async throws -> Data

    static func verify(target: any DesktopInputPermissionTarget, call: ToolCall,
                       isCurrent: @MainActor () throws -> Void) async throws {
        defer { target.invalidate() }
        try isCurrent()
        try Task.checkCancellation()
        try target.present()
        let pid = target.pid
        let windowID = target.windowID
        let expected = target.expectedText
        guard pid > 0, windowID > 0, !expected.isEmpty, expected.count <= 128,
              target.clickCount == 0, target.text.isEmpty else { throw CuaMCPProxyError.functionalProbeFailed }
        let session = "permissions-\(UUID().uuidString)"
        func requireCurrent() throws {
            try Task.checkCancellation()
            try isCurrent()
            try target.requireCurrent()
            guard target.pid == pid, target.windowID == windowID, target.expectedText == expected else {
                throw CancellationError()
            }
        }
        func invoke(_ name: String, _ extra: [String: Any]) async throws -> Data {
            try requireCurrent()
            var arguments: [String: Any] = ["session": session, "pid": pid, "window_id": windowID]
            arguments.merge(extra) { _, value in value }
            let response = try await call(name, JSONSerialization.data(withJSONObject: arguments))
            try requireCurrent()
            return response
        }
        let observation: [String: Any] = ["include_screenshot": false, "include_accessibility_tree": true,
                                        "max_elements": 32, "max_depth": 8, "timeout_ms": 1000]
        let first = try decode(Snapshot.self, from: await invoke("get_window_state", observation))
        let button = try first.token(pid: pid, windowID: windowID, role: "AXButton", label: buttonLabel, action: "AXPress")
        let clicked = try decode(Action.self, from: await invoke("click", ["element_token": button, "action": "press",
                                                                         "button": "left", "delivery_mode": "background"]))
        guard clicked.path == "ax", clicked.effect == "unverifiable", clicked.verified == false,
              target.clickCount == 1, target.text.isEmpty else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
        let second = try decode(Snapshot.self, from: await invoke("get_window_state", observation))
        guard second.snapshot_id != first.snapshot_id else { throw CuaMCPProxyError.functionalProbeFailed }
        let field = try second.token(pid: pid, windowID: windowID, role: "AXTextField", label: fieldLabel)
        guard target.clickCount == 1, target.text.isEmpty else { throw CuaMCPProxyError.functionalProbeFailed }
        let typed = try decode(Action.self, from: await invoke("type_text", ["element_token": field, "text": expected,
                                                                            "scope": "window", "delay_ms": 0,
                                                                            "delivery_mode": "background"]))
        guard typed.path == "ax", typed.effect == "confirmed", typed.verified == true,
              typed.characters == expected.count, typed.requested_chars == expected.count,
              target.clickCount == 1, target.text == expected else { throw CuaMCPProxyError.functionalProbeFailed }
        try requireCurrent()
    }

    private struct Reply<Payload: Decodable>: Decodable {
        struct Result: Decodable {
            let isError: Bool?
            let structuredContent: Payload
        }
        let result: Result
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws -> Payload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["error"] == nil,
              let reply = try? JSONDecoder().decode(Reply<Payload>.self, from: data), reply.result.isError != true else {
            throw CuaMCPProxyError.functionalProbeFailed
        }
        return reply.result.structuredContent
    }

    private struct Action: Decodable {
        let path: String
        let effect: String
        let verified: Bool?
        let characters: Int?
        let requested_chars: Int?
    }

    private struct Snapshot: Decodable {
        struct Element: Decodable {
            let element_index: Int
            let element_token: String?
            let role: String
            let label: String?
            let enabled: Bool?
            let actions: [String]?
        }
        let pid: Int32
        let window_id: Int
        let snapshot_id: String
        let truncated: Bool
        let degraded: Bool?
        let elements: [Element]

        func token(pid expectedPID: Int32, windowID: Int, role: String, label: String, action: String? = nil) throws -> String {
            guard pid == expectedPID, window_id == windowID, !truncated, degraded != true,
                  snapshot_id.range(of: "^s[0-9a-f]{8}$", options: .regularExpression) != nil,
                  elements.count <= 32 else { throw CuaMCPProxyError.functionalProbeFailed }
            let matches = elements.filter { $0.role == role && $0.label == label }
            guard matches.count == 1, let element = matches.first, element.enabled == true,
                  element.element_index >= 0, let token = element.element_token,
                  token == "\(snapshot_id):\(element.element_index)",
                  action.map({ element.actions?.contains($0) == true }) ?? true else {
                throw CuaMCPProxyError.functionalProbeFailed
            }
            return token
        }
    }
}
