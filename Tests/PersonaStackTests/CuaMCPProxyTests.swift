import Darwin
import Foundation
import Testing
@testable import PersonaStackCore

@Suite
struct CuaMCPProxyTests {
    @Test
    func acceptsLocalScreenshotResponseLargerThanRelayFrame() async throws {
        let script = #"""
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "notifications/initialized":
                continue
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
            else:
                result = {"content":[{"type":"image","mimeType":"image/png","data":"A" * (9 * 1024 * 1024)}]}
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let executable = try executableScript(script)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let proxy = CuaMCPProxy(executableURL: executable)
        _ = try await proxy.start()
        let response = try await proxy.callTool(name: "get_desktop_state", argumentsJSON: Data("{}".utf8))
        #expect(response.count > 8 * 1024 * 1024)
        await proxy.stop()
    }

    @Test
    func stopKillsAnUnresponsiveProxyWithinItsDeadline() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cua-proxy-unresponsive-\(UUID().uuidString)")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("method") == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
                print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
            elif request.get("method") == "notifications/initialized":
                pathlib.Path("\#(marker.path)").write_text("ready")
                while True:
                    time.sleep(1)
        """#
        let executable = try executableScript(script)
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
        }
        let proxy = CuaMCPProxy(executableURL: executable)
        _ = try await proxy.start()
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let started = Date()
        await proxy.stop()
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test
    func fullChildStdinIsInterruptibleAndBounded() async throws {
        for interruptWrite in [true, false] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cua-proxy-idle-child-\(UUID().uuidString)")
            let script = #"""
            #!/usr/bin/python3
            import json, time, sys
            for line in sys.stdin:
                request = json.loads(line)
                if request.get("method") == "initialize":
                    result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
                    print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
                elif request.get("method") == "notifications/initialized":
                    with open("\#(marker.path)", "w") as output:
                        output.write("idle")
                    time.sleep(4)
                    break
            """#
            let executable = try executableScript(script)
            defer {
                try? FileManager.default.removeItem(at: marker)
                try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            }
            let proxy = CuaMCPProxy(executableURL: executable)
            _ = try await proxy.start()
            let readyDeadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let arguments = Data("{\"padding\":\"\(String(repeating: "x", count: 1024 * 1024))\"}".utf8)
            let call = Task { try await proxy.callTool(name: "click", argumentsJSON: arguments, timeout: 1) }
            try await Task.sleep(for: .milliseconds(100))
            let started = Date()
            if interruptWrite {
                proxy.interrupt()
                await #expect(throws: CuaMCPProxyError.interrupted) { try await call.value }
                #expect(Date().timeIntervalSince(started) < 1)
            } else {
                await #expect(throws: CuaMCPProxyError.timeout) { try await call.value }
                #expect(Date().timeIntervalSince(started) < 2)
            }
            await proxy.stop()
        }
    }

    @Test
    func interruptionWakesAnInFlightGuiCallWithoutStoppingTheDaemon() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cua-proxy-call-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = #"""
        #!/usr/bin/python3
        import json, sys, time
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1"}}
            elif method == "tools/call":
                with open("\#(marker.path)", "w") as output:
                    output.write("started")
                time.sleep(20)
                result = {"content":[]}
            else:
                continue
            print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let executable = try executableScript(script)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let proxy = CuaMCPProxy(executableURL: executable)
        _ = try await proxy.start()
        let call = Task {
            try await proxy.callTool(name: "click", argumentsJSON: Data("{}".utf8))
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let interruptedAt = Date()
        proxy.interrupt()
        await #expect(throws: CuaMCPProxyError.interrupted) { try await call.value }
        #expect(Date().timeIntervalSince(interruptedAt) < 1)
        await proxy.stop()
    }

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
                result = {"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"cua","version":"0.29.1","telemetry":__import__("os").environ.get("CUA_DRIVER_RS_TELEMETRY_ENABLED"),"update_check":__import__("os").environ.get("CUA_DRIVER_RS_UPDATE_CHECK"),"argv":sys.argv[1:]}}
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
            #expect(serverInfo["argv"] as? [String] == ["mcp"])
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

    @Test
    func explicitSocketIsPassedToThePinnedMCPProxy() async throws {
        let script = #"""
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("method") == "initialize":
                result = {"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"cua","version":"0.29.1","argv":sys.argv[1:]}}
                print(json.dumps({"jsonrpc":"2.0","id":request["id"],"result":result}), flush=True)
        """#
        let executable = try executableScript(script)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("cua named socket-\(UUID().uuidString).sock")
        let proxy = CuaMCPProxy(executableURL: executable, socketURL: socket)

        do {
            let response = try await proxy.start()
            let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let result = try #require(object["result"] as? [String: Any])
            let serverInfo = try #require(result["serverInfo"] as? [String: Any])
            #expect(serverInfo["argv"] as? [String] == ["mcp", "--socket", socket.path, "--embedded"])
            await proxy.stop()
        } catch {
            await proxy.stop()
            throw error
        }
    }

    @Test
    func socketIdentityUsesTheKernelPeerAndRejectsAnotherDaemonPID() async throws {
        let socketURL = URL(fileURLWithPath: "/tmp/cua-peer-\(UUID().uuidString.prefix(8)).sock")
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CuaMCPProxyError.processExited }
        defer {
            _ = Darwin.close(listener)
            _ = Darwin.unlink(socketURL.path)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(Darwin.listen(listener, 2) == 0)
        #expect(CuaSocketIdentity.peerPID(at: socketURL) == Darwin.getpid())

        let proxy = CuaMCPProxy(
            executableURL: URL(fileURLWithPath: "/nonexistent/fake-cua"),
            socketURL: socketURL,
            expectedDaemonPID: Darwin.getpid() + 1
        )
        await #expect(throws: CuaMCPProxyError.serviceMismatch) { try await proxy.start() }
    }

    @Test
    func missingSelectedSocketCannotStartTheMCPProxy() async {
        let socketURL = URL(fileURLWithPath: "/tmp/cua-missing-\(UUID().uuidString.prefix(8)).sock")
        let proxy = CuaMCPProxy(
            executableURL: URL(fileURLWithPath: "/nonexistent/fake-cua"),
            socketURL: socketURL,
            expectedDaemonPID: Darwin.getpid()
        )
        await #expect(throws: CuaMCPProxyError.serviceMismatch) { try await proxy.start() }
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
