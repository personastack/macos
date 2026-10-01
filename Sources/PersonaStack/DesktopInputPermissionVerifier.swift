import Foundation

enum DesktopInputPermissionVerificationError: LocalizedError, Equatable {
    case busy
    case failed(Stage, Reason)

    enum Stage: String {
        case window = "preparing the test window"
        case button = "reading the test button"
        case click = "clicking the test button"
        case field = "reading the test text field"
        case text = "entering the test text"
    }

    enum Reason: String {
        case unavailable = "the test window was not ready"
        case rejected = "the desktop runtime rejected the operation"
        case response = "the desktop runtime returned an incompatible reply"
        case snapshot = "the accessibility snapshot was incomplete or unsafe"
        case control = "the test control was not found uniquely"
        case outcome = "the desktop runtime did not confirm the expected Accessibility operation"
        case effect = "the test control did not receive the expected input"
    }

    var errorDescription: String? {
        switch self {
        case .busy:
            "Desktop Control is busy or recovering. Wait for the remote task to finish, then retry Setup."
        case let .failed(stage, reason):
            "Accessibility verification stopped while \(stage.rawValue): \(reason.rawValue). Retry Setup Accessibility."
        }
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
    typealias Failure = DesktopInputPermissionVerificationError
    typealias ToolCall = @MainActor (String, Data) async throws -> Data
    typealias Settle = @MainActor () async throws -> Void

    static func verify(target: any DesktopInputPermissionTarget, call: ToolCall,
                       isCurrent: @MainActor () throws -> Void,
                       settle: Settle = { try await Task.sleep(for: .milliseconds(100)) }) async throws {
        defer { target.invalidate() }
        try isCurrent()
        try Task.checkCancellation()
        try target.present()
        let pid = target.pid
        let windowID = target.windowID
        let expected = target.expectedText
        guard pid > 0, windowID > 0, !expected.isEmpty, expected.count <= 128,
              target.clickCount == 0, target.text.isEmpty else { throw Failure.failed(.window, .unavailable) }
        let session = "permissions-\(UUID().uuidString)"
        func requireCurrent() throws {
            try Task.checkCancellation()
            try isCurrent()
            try target.requireCurrent()
            guard target.pid == pid, target.windowID == windowID, target.expectedText == expected else {
                throw CancellationError()
            }
        }
        func invoke(_ name: String, _ extra: [String: Any], stage: Failure.Stage) async throws -> Data {
            try requireCurrent()
            var arguments: [String: Any] = ["session": session, "pid": pid, "window_id": windowID]
            arguments.merge(extra) { _, value in value }
            let response: Data
            do { response = try await call(name, JSONSerialization.data(withJSONObject: arguments)) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try requireCurrent()
                throw Failure.failed(stage, .rejected)
            }
            try requireCurrent()
            return response
        }
        func observe(stage: Failure.Stage) async throws -> Snapshot {
            for attempt in 0..<3 {
                let data = try await invoke("get_window_state", [
                    "include_screenshot": false, "include_accessibility_tree": true,
                    "max_elements": 32, "max_depth": 8, "timeout_ms": 1000,
                ], stage: stage)
                let snapshot = try decode(Snapshot.self, from: data, stage: stage)
                try snapshot.requireOwner(pid: pid, windowID: windowID, stage: stage)
                // The pinned producer documents a just-created window's empty
                // or unresolved AX tree as transient. Retry reads only.
                if snapshot.isPendingWindow, attempt < 2 {
                    try await settle()
                    try requireCurrent()
                    continue
                }
                return snapshot
            }
            throw Failure.failed(stage, .snapshot)
        }
        func waitForEffect(stage: Failure.Stage, matches: () -> Bool) async throws {
            for _ in 0..<10 {
                try requireCurrent()
                if matches() { return }
                try await settle()
            }
            try requireCurrent()
            guard matches() else { throw Failure.failed(stage, .effect) }
        }

        let first = try await observe(stage: .button)
        let button = try first.token(role: "AXButton", label: buttonLabel, action: "AXPress", stage: .button)
        let clicked = try decode(Action.self, from: await invoke("click", ["element_token": button, "action": "press",
            "button": "left", "delivery_mode": "background"], stage: .click), stage: .click)
        guard clicked.isBackgroundAccessibility, clicked.effect == "unverifiable" else {
            throw Failure.failed(.click, .outcome)
        }
        try await waitForEffect(stage: .click) { target.clickCount == 1 && target.text.isEmpty }
        let second = try await observe(stage: .field)
        guard second.snapshot_id != first.snapshot_id else { throw Failure.failed(.field, .snapshot) }
        let field = try second.token(role: "AXTextField", label: fieldLabel, stage: .field)
        guard target.clickCount == 1, target.text.isEmpty else { throw Failure.failed(.field, .effect) }
        let typed = try decode(Action.self, from: await invoke("type_text", ["element_token": field, "text": expected,
            "scope": "window", "delay_ms": 0, "delivery_mode": "background"], stage: .text), stage: .text)
        guard typed.isBackgroundAccessibility, typed.effect == "confirmed",
              typed.evidence?.contains(where: { $0.kind == "value_readback" }) == true,
              typed.delivery?.delivered_count.map({ $0 == expected.unicodeScalars.count }) ?? true else {
            throw Failure.failed(.text, .outcome)
        }
        try await waitForEffect(stage: .text) { target.clickCount == 1 && target.text == expected }
    }

    private struct Reply<Payload: Decodable>: Decodable {
        struct Result: Decodable {
            let isError: Bool?
            let structuredContent: Payload
        }
        let result: Result
    }

    private static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data,
                                                   stage: Failure.Stage) throws -> Payload {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed(stage, .response)
        }
        if object["error"] != nil || (object["result"] as? [String: Any])?["isError"] as? Bool == true {
            throw Failure.failed(stage, .rejected)
        }
        guard let reply = try? JSONDecoder().decode(Reply<Payload>.self, from: data) else {
            throw Failure.failed(stage, .response)
        }
        return reply.result.structuredContent
    }

    // Cua 0.29.1's canonical MCP dispatcher publishes ActionResult, not the
    // platform handler's private path/verified/characters fields. See pinned
    // cua-driver-core/src/tool.rs::publish_action_result and contract/outputs.rs.
    private struct Action: Decodable {
        struct Delivery: Decodable {
            let mode: String
            let delivered_count: Int?
        }
        struct Evidence: Decodable { let kind: String }
        let route: String
        let effect: String
        let delivery: Delivery?
        let evidence: [Evidence]?
        let error: [String: String]?
        var isBackgroundAccessibility: Bool {
            route == "accessibility" && delivery?.mode == "background" && error == nil
        }
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
        let snapshot_id: String?
        let truncated: Bool
        let degraded: Bool?
        let degraded_reason: String?
        let elements: [Element]

        var isPendingWindow: Bool {
            degraded == true && elements.isEmpty &&
                (degraded_reason?.hasPrefix("ax_window_unresolved:") == true ||
                 degraded_reason?.hasPrefix("ax_tree_empty:") == true)
        }

        func requireOwner(pid expectedPID: Int32, windowID: Int, stage: Failure.Stage) throws {
            guard pid == expectedPID, window_id == windowID, !truncated, elements.count <= 32 else {
                throw Failure.failed(stage, .snapshot)
            }
        }

        func token(role: String, label: String, action: String? = nil, stage: Failure.Stage) throws -> String {
            guard degraded != true, let snapshot_id,
                  snapshot_id.range(of: "^s[0-9a-f]{8}$", options: .regularExpression) != nil else {
                throw Failure.failed(stage, .snapshot)
            }
            let matches = elements.filter { $0.role == role && $0.label == label }
            guard matches.count == 1, let element = matches.first, element.enabled == true,
                  element.element_index >= 0, let token = element.element_token,
                  token == "\(snapshot_id):\(element.element_index)",
                  action.map({ element.actions?.contains($0) == true }) ?? true else {
                throw Failure.failed(stage, .control)
            }
            return token
        }
    }
}
