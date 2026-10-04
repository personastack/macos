import Foundation
import PersonaStackCore

@MainActor
enum DesktopPerceptionPermissionVerifier {
    enum Failure: Error, LocalizedError {
        case unavailable, invalidCapture, invalidParse
        var errorDescription: String? {
            switch self {
            case .unavailable: "The owned visual perception test window is unavailable."
            case .invalidCapture: "CUA did not return a current capture of the owned test window."
            case .invalidParse: "CUA could not verify visual perception on the owned test window."
            }
        }
    }
    typealias ToolCall = @MainActor (String, Data) async throws -> Data

    static func verify(target: any DesktopInputPermissionTarget, call: @escaping ToolCall,
                       isCurrent: @MainActor () throws -> Void) async throws {
        defer { target.invalidate() }
        try Task.checkCancellation()
        try isCurrent()
        try target.present()
        let pid = target.pid
        let window = target.windowID
        guard pid > 0, window > 0 else { throw Failure.unavailable }
        let session = "permissions-perception-\(UUID().uuidString)"
        func current() throws {
            try Task.checkCancellation()
            try isCurrent()
            try target.requireCurrent()
            guard target.pid == pid, target.windowID == window else { throw CancellationError() }
        }
        func invoke(_ name: String, _ fields: [String: Any]) async throws -> [String: Any] {
            try current()
            var arguments = fields
            arguments["session"] = session
            let data = try await call(name, JSONSerialization.data(withJSONObject: arguments))
            try current()
            return try structured(data)
        }
        // Cleanup owns only this setup session. It must still be attempted after
        // cancellation or target disappearance and must not start another capture.
        func endSession() async throws {
            let data = try JSONSerialization.data(withJSONObject: ["session": session])
            _ = try await Task { @MainActor in
                try await DesktopControlExecution.$deadline.withValue(Date().addingTimeInterval(5)) {
                    let result = try structured(await call("end_session", data))
                    guard result["session"] as? String == session, result["active"] as? Bool == false else {
                        throw Failure.invalidParse
                    }
                }
            }.value
        }
        do {
            let snapshot = try await invoke("get_window_state", ["pid": pid, "window_id": window,
                "include_screenshot": true, "include_accessibility_tree": true,
                "max_elements": 32, "max_depth": 8, "timeout_ms": 1000])
            let captureID = try capture(snapshot, pid: pid, window: window)
            let parsed = try await invoke("parse_visual_regions", ["capture_id": captureID,
                "options": ["kinds": ["text"], "max_regions": 128]])
            try validate(parsed, captureID: captureID, pid: pid, window: window)
            try current()
        } catch {
            try? await endSession()
            throw error
        }
        try await endSession()
        try current()
    }

    private static func structured(_ data: Data) throws -> [String: Any] {
        guard data.count <= 32 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let result = root["result"] as? [String: Any], result["isError"] as? Bool != true,
              let body = result["structuredContent"] as? [String: Any] else { throw Failure.invalidParse }
        return body
    }

    private static func capture(_ body: [String: Any], pid: Int32, window: Int) throws -> String {
        guard (body["pid"] as? NSNumber)?.int64Value == Int64(pid),
              (body["window_id"] as? NSNumber)?.int64Value == Int64(window),
              body["degraded"] as? Bool != true, body["truncated"] as? Bool == false,
              let snapshot = body["snapshot_id"] as? String, !snapshot.isEmpty,
              let capture = body["capture_id"] as? String, !capture.isEmpty, capture.count <= 256 else {
            throw Failure.invalidCapture
        }
        return capture
    }

    private static func validate(_ body: [String: Any], captureID: String, pid: Int32, window: Int) throws {
        guard body["schema"] as? String == "cua.visual_regions_v1",
              let capture = body["capture"] as? [String: Any], capture["capture_id"] as? String == captureID,
              let source = capture["source"] as? [String: Any], source["kind"] as? String == "window",
              (source["pid"] as? NSNumber)?.int64Value == Int64(pid),
              (source["window_id"] as? NSNumber)?.int64Value == Int64(window) else { throw Failure.invalidParse }
        guard let parser = body["parser"] as? [String: Any],
              parser["extension_id"] as? String == "cua-perception",
              parser["extension_version"] as? String == CuaPerceptionCompatibility.version,
              parser["runtime"] as? String == "onnx_runtime_cpu",
              parser["backend"] as? String == "onnx_runtime_cpu", parser["fixture_sha256"] == nil,
              let regions = body["regions"] as? [[String: Any]], !regions.isEmpty, regions.count <= 128 else {
            throw Failure.invalidParse
        }
        let text = regions.compactMap { $0["text"] as? String }.joined(separator: " ").lowercased()
        guard text.count <= 32_768, ["verify", "desktop", "control"].allSatisfy(text.contains) else {
            throw Failure.invalidParse
        }
    }
}
