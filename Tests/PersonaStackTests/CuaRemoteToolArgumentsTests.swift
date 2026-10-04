import Foundation
import Testing
@testable import PersonaStackCore

struct CuaRemoteToolArgumentsTests {
    @Test func extensionInstallationRequiresNativeArtifactReview() throws {
        #expect(throws: CuaRemoteToolArguments.PolicyError.nativeSetupRequired) {
            try CuaRemoteToolArguments.prepare(name: "install_extension", arguments: .object([
                "name": .string("perception"), "confirm": .bool(true)]), session: "owned")
        }
        #expect(try CuaRemoteToolArguments.prepare(name: "install_extension", arguments: .object([
            "name": .string("perception")]), session: "owned") == .object([
                "name": .string("perception"), "confirm": .bool(false), "session": .string("owned")]))
    }

    @Test func toolsRequiringSessionUseHostAuthorityDuringValidation() throws {
        let cases: [(String, [String: DesktopControlJSONValue])] = [
            ("browser_download", ["target_id": .string("target"), "tab_id": .string("tab"),
                                  "ref": .string("ref"), "destination_root": .string("/tmp/downloads")]),
            ("browser_pointer", ["target_id": .string("target"), "tab_id": .string("tab"), "action": .string("hover")]),
            ("escalate_session", ["reason": .string("other")]),
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

    @Test func remotePermissionChecksNeverRequestConsent() throws {
        #expect(try CuaRemoteToolArguments.prepare(name: "check_permissions", arguments: .object([:]), session: "owned") ==
            .object(["session": .string("owned"), "prompt": .bool(false), "probe_direct_capture": .bool(false)]))
        for key in ["prompt", "probe_direct_capture"] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "check_permissions", arguments: .object([key: .bool(true)]), session: "owned")
            }
        }
    }

    @Test func callersCannotChooseSessionAuthority() {
        for key in ["session", "_session_id", "_transport_session_id", "unknown"] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "start_session", arguments: .object([key: .string("foreign")]), session: "owned")
            }
        }
    }

    @Test func sessionPaginationAndImageDimensionsKeepUpstreamBounds() throws {
        for fields: [String: DesktopControlJSONValue] in [
            ["limit": .number(0)], ["limit": .number(101)], ["cursor": .string("foreign")],
        ] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "list_sessions", arguments: .object(fields), session: "owned")
            }
        }
        _ = try CuaRemoteToolArguments.prepare(name: "list_sessions", arguments: .object([
            "limit": .null, "cursor": .string("o:0")]), session: "owned")
        for value in [-1.0, Double(UInt32.max) + 1] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "set_config", arguments: .object([
                    "max_image_dimension": .number(value)]), session: "owned")
            }
        }
    }

    @Test func configurationAliasesNormalizeOnlyKnownTypedFields() throws {
        #expect(try CuaRemoteToolArguments.prepare(name: "set_config", arguments: .object([
            "key": .string("experimental_pip"), "value": .bool(true)]), session: "owned") ==
            .object(["experimental_pip": .bool(true), "session": .string("owned")]))
        for fields: [String: DesktopControlJSONValue] in [
            ["key": .string("permission_mode"), "value": .string("unrestricted")],
            ["key": .string("max_image_dimension"), "value": .string("large")],
            ["key": .string("experimental_pip"), "value": .bool(true), "max_image_dimension": .number(100)],
            ["value": .bool(true)],
        ] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "set_config", arguments: .object(fields), session: "owned")
            }
        }
    }

    @Test func browserVariantsKeepConfirmationAndTargetRequirements() throws {
        let profile: DesktopControlJSONValue = .object(["mode": .string("isolated_named"), "name": .string("research")])
        #expect(try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object([
            "confirm": .bool(true), "profile": profile, "allow_launch": .bool(true)]), session: "owned") ==
            .object(["profile": profile, "allow_launch": .bool(true), "session": .string("owned")]))
        let existing: DesktopControlJSONValue = .object(["kind": .string("existing_profile")])
        _ = try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object([
            "confirm": .bool(true), "strategy": existing, "pid": .number(123), "window_id": .number(456)]), session: "owned")
        for fields: [String: DesktopControlJSONValue] in [
            ["confirm": .bool(true), "strategy": existing],
            ["confirm": .bool(true), "profile": .object(["mode": .string("isolated_named"), "name": .string("../escape")]), "allow_launch": .bool(true)],
            ["confirm": .bool(true), "strategy": existing, "pid": .number(-1), "window_id": .number(456)],
            ["confirm": .bool(true), "strategy": existing, "pid": .number(123), "window_id": .number(456), "allow_launch": .bool(true)],
        ] {
            #expect(throws: (any Error).self) {
                try CuaRemoteToolArguments.prepare(name: "browser_prepare", arguments: .object(fields), session: "owned")
            }
        }
    }
}
