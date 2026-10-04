import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

@MainActor private final class PerceptionWindowFixture: DesktopInputPermissionTarget {
    var pid: Int32 = 123
    var windowID = 45
    var clickCount = 0
    var text = ""
    var expectedText = "disposable"
    var invalidated = false
    func present() throws {}
    func requireCurrent() throws { if invalidated { throw CancellationError() } }
    func invalidate() { invalidated = true }
}

private func perceptionReply(_ body: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["result": ["structuredContent": body]])
}

@MainActor @Test(arguments: ["success", "foreignCapture", "foreignWindow", "fixtureParser", "emptyRegions", "cleanupFailure", "cancelAfterCapture"])
func perceptionOwnedWindowQualification(mode: String) async throws {
    let target = PerceptionWindowFixture()
    var calls: [String] = []
    var session: String?
    var current = true
    do {
        try await DesktopPerceptionPermissionVerifier.verify(target: target, call: { name, data in
            calls.append(name)
            let args = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let label = try #require(args["session"] as? String)
            if let session { #expect(label == session) } else { session = label }
            switch name {
            case "get_window_state":
                #expect(args["pid"] as? Int == 123)
                #expect(args["window_id"] as? Int == 45)
                #expect(args["include_screenshot"] as? Bool == true)
                #expect(args["include_accessibility_tree"] as? Bool == true)
                if mode == "cancelAfterCapture" { current = false }
                return try perceptionReply(["pid": 123, "window_id": 45, "capture_id": "capture-owned",
                                            "snapshot_id": "s1234abcd", "truncated": false])
            case "parse_visual_regions":
                #expect(args["capture_id"] as? String == "capture-owned")
                return try perceptionReply([
                    "schema": "cua.visual_regions_v1",
                    "capture": ["capture_id": mode == "foreignCapture" ? "capture-foreign" : "capture-owned",
                                "source": ["kind": "window", "pid": 123, "window_id": mode == "foreignWindow" ? 99 : 45]],
                    "parser": ["extension_id": "cua-perception", "extension_version": "0.2.1",
                               "runtime": "onnx_runtime_cpu", "backend": mode == "fixtureParser" ? "deterministic_fixture" : "onnx_runtime_cpu"],
                    "regions": mode == "emptyRegions" ? [] : [["text": "Verify Desktop Control Click"]],
                ])
            case "end_session":
                #expect(args.count == 1)
                #expect(DesktopControlExecution.deadline != nil)
                if mode == "cleanupFailure" { throw CuaPerceptionError.commandFailed }
                return try perceptionReply(["session": label, "active": false])
            default:
                Issue.record("Unexpected tool \(name)")
                throw CuaPerceptionError.commandFailed
            }
        }, isCurrent: { if !current { throw CancellationError() } })
        #expect(mode == "success")
    } catch {
        #expect(mode != "success")
    }
    #expect(target.invalidated)
    #expect(calls.last == "end_session")
    #expect(calls.count == (mode == "cancelAfterCapture" ? 2 : 3))
}

@Test func perceptionProcessRunnerCancellationStopsOwnedCommand() async throws {
    let started = ProcessInfo.processInfo.systemUptime
    let task = Task.detached {
        try SystemCuaProcessRunner(timeout: 180).run(URL(fileURLWithPath: "/bin/sh"),
                                                   arguments: ["-c", "while :; do :; done"])
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ProcessInfo.processInfo.systemUptime - started < 3)
}
