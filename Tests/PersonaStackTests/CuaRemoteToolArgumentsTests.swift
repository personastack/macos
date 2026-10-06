import Foundation
import Testing
@testable import PersonaStackCore

struct CuaRemoteToolArgumentsTests {
    @Test(arguments: ["install_extension", "install_ffmpeg", "set_config", "check_permissions", "start_session", "end_session", "escalate_session", "list_sessions"])
    func administrativeToolsAreNotRemoteArguments(name: String) {
        #expect(throws: (any Error).self) {
            try CuaRemoteToolArguments.prepare(name: name, arguments: .object([:]), session: "owned")
        }
    }

    @Test func toolsRequiringSessionUseHostAuthorityDuringValidation() throws {
        let cases: [(String, [String: DesktopControlJSONValue])] = [
            ("browser_download", ["target_id": .string("target"), "tab_id": .string("tab"),
                                  "ref": .string("ref"), "destination_root": .string("/tmp/downloads")]),
            ("browser_pointer", ["target_id": .string("target"), "tab_id": .string("tab"), "action": .string("hover")]),
            ("get_agent_cursor_state", [:]),
            ("set_agent_cursor_enabled", ["enabled": .bool(true)]),
            ("set_agent_cursor_motion", [:]),
            ("set_agent_cursor_theme", ["theme_id": .string("default")]),
        ]
        for (name, fields) in cases {
            var expected = fields
            expected["session"] = .string("owned")
            #expect(try CuaRemoteToolArguments.prepare(name: name, arguments: .object(fields), session: "owned") == .object(expected))
            var foreign = fields
            foreign["session"] = .string("foreign")
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: name, arguments: .object(foreign), session: "owned")
            }
        }
    }

    @Test func callersCannotChooseSessionAuthority() {
        for key in ["session", "_session_id", "_transport_session_id", "unknown"] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "get_config", arguments: .object([key: .string("foreign")]), session: "owned")
            }
        }
    }

    @Test func browserArgumentsUseTheReviewedUpstreamContract() throws {
        let fields: [String: DesktopControlJSONValue] = ["profile": .object(["mode": .string("isolated_new")]), "allow_launch": .bool(true)]
        var expected = fields
        expected["session"] = .string("owned")
        #expect(try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object(fields), session: "owned") == .object(expected))
        var oldFacade = fields
        oldFacade["confirm"] = .bool(true)
        #expect(try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object(oldFacade), session: "owned") == .object(expected))
        #expect(try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object(["confirm": .bool(true)]), session: "owned") == .object(expected))
        for invalid in [DesktopControlJSONValue.bool(false), .string("true"), .null] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object(["confirm": invalid]), session: "owned")
            }
        }
    }
}
