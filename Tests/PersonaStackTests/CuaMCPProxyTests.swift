import Foundation
import Testing
@testable import PersonaStackCore

@Suite
struct CuaMCPProxyTests {
    @Test
    func initializesListsAndCallsOnlyApprovedTools() async throws {
        let stoppedMarker = FileManager.default.temporaryDirectory.appendingPathComponent("cua-proxy-stopped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stoppedMarker) }
        let script = #"""
        #!/usr/bin/python3
        import atexit, json, signal, sys
        def record_exit():
            with open("\#(stoppedMarker.path)", "w") as marker:
                marker.write("stopped")
        atexit.register(record_exit)
        def stop_handler(*_):
            record_exit()
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, stop_handler)
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "notifications/initialized":
                continue
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"cua","version":"0.28.2","telemetry":__import__("os").environ.get("CUA_DRIVER_RS_TELEMETRY_ENABLED"),"update_check":__import__("os").environ.get("CUA_DRIVER_RS_UPDATE_CHECK")}}
            elif method == "tools/list":
                names = ["get_desktop_state","get_accessibility_tree","get_window_state","move_cursor","click","type_text","press_key","launch_app","list_apps","list_windows"]
                result = {"tools":[{"name":name,"inputSchema":{"type":"object"}} for name in names]}
            elif method == "tools/call":
                result = {"content":[{"type":"text","text":request["params"]["name"]}]}
            else:
                result = {}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let url = try executableScript(script)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let proxy = CuaMCPProxy(executableURL: url)

        do {
            let initialize = try await proxy.start()
            let initializeObject = try #require(JSONSerialization.jsonObject(with: initialize) as? [String: Any])
            #expect(initializeObject["result"] != nil)
            let serverInfo = try #require((initializeObject["result"] as? [String: Any])?["serverInfo"] as? [String: Any])
            #expect(serverInfo["telemetry"] as? String == "0")
            #expect(serverInfo["update_check"] as? String == "false")
            let listed = try await proxy.listTools()
            let toolNames = try await proxy.validateToolCatalog(listed)
            #expect(toolNames.contains("get_desktop_state"))
            let args = Data(#"{"include_screenshots":false}"#.utf8)
            let called = try await proxy.callTool(name: "get_desktop_state", argumentsJSON: args)
            #expect(String(decoding: called, as: UTF8.self).contains("get_desktop_state"))
            await #expect(throws: CuaMCPProxyError.invalidToolName) {
                try await proxy.callTool(name: "permissions", argumentsJSON: Data("{}".utf8))
            }
            await proxy.stop()
            #expect(FileManager.default.fileExists(atPath: stoppedMarker.path))
        } catch {
            await proxy.stop()
            throw error
        }
    }

    private func executableScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-mcp-proxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = directory.appendingPathComponent("fake-cua")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
