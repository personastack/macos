import Foundation
import Testing
@testable import PersonaStackCore

struct CuaDriverCompatibilityTests {
    @Test func pinnedReleaseAndRequiredToolSetValidate() throws {
        let manifest = Data(#"{"binary_version":"0.29.1","schema_version":"1"}"#.utf8)
        try CuaDriverCompatibility.validate(manifestData: manifest,
                                            toolNames: CuaDriverCompatibility.requiredTools)
        #expect(CuaDriverCompatibility.archiveSHA256 == "ee376d59ef37afac29a10c60c71469ac85fdc8844d1884bd317edd8def29055a")
        #expect(CuaDriverCompatibility.exposedTools.isSuperset(of: CuaDriverCompatibility.requiredTools))
        #expect(CuaDriverCompatibility.licenseNotice.contains("Copyright (c) 2025 Cua AI, Inc."))
        #expect(CuaDriverCompatibility.licenseNotice.contains("permission notice shall be included"))
        #expect(CuaDriverCompatibility.managedServiceEnvironment == [
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": "ai.personastack.desktop",
        ])
        let probe = try JSONSerialization.jsonObject(with: CuaDriverCompatibility.permissionProbeArgumentsJSON) as? [String: Bool]
        #expect(probe == ["prompt": false, "probe_direct_capture": false])
        #expect(CuaDriverCompatibility.processEnvironment(from: [
            "HOME": "/tmp/profile",
            "PERSONASTACK_MACHINE_TOKEN": "do-not-forward",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "1",
        ]) == [
            "HOME": "/tmp/profile",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": "ai.personastack.desktop",
        ])
    }

    @Test func mismatchedVersionSchemaAndCatalogFailClosed() throws {
        let wrongVersion = Data(#"{"binary_version":"0.28.2","schema_version":"1"}"#.utf8)
        #expect(throws: CuaDriverCompatibility.ValidationError.unsupportedVersion) {
            try CuaDriverCompatibility.validate(manifestData: wrongVersion,
                                                toolNames: CuaDriverCompatibility.requiredTools)
        }
        let wrongSchema = Data(#"{"binary_version":"0.29.1","schema_version":"2"}"#.utf8)
        #expect(throws: CuaDriverCompatibility.ValidationError.unsupportedSchema) {
            try CuaDriverCompatibility.validate(manifestData: wrongSchema,
                                                toolNames: CuaDriverCompatibility.requiredTools)
        }
        #expect(throws: CuaDriverCompatibility.ValidationError.missingRequiredTools(["click"])) {
            try CuaDriverCompatibility.validate(manifestData: Data(#"{"binary_version":"0.29.1","schema_version":"1"}"#.utf8),
                                                toolNames: CuaDriverCompatibility.requiredTools.subtracting(["click"]))
        }
    }

    @Test func toolNamesParseFromReviewedCliOutput() {
        let output = "get_desktop_state: Capture desktop\nclick: Click\nmalformed output\n"
        #expect(CuaDriverCompatibility.parseToolNames(output) == ["get_desktop_state", "click"])
    }

    @Test func permissionSnapshotSeparatesDeniedGrantsFromVerifiedHostAttribution() throws {
        let source: [String: Any] = [
            "attribution": "host", "host_bundle_id": "ai.personastack.desktop", "embedded": true,
            "disclaim_env": false, "pid": Int32(1234), "responsible_ppid": Int32(1000),
        ]
        let payload: [String: Any] = ["accessibility": false, "screen_recording": true, "source": source]
        let snapshot = try CuaDriverPermissionSnapshot.parse(payload, daemonPID: 1234, hostPID: 1000,
                                                             verificationKey: "owned-generation")
        #expect(!snapshot.accessibility)
        #expect(snapshot.screenRecording)
        #expect(snapshot.hostAttributionValid)
        #expect(snapshot.verificationKey == "owned-generation")
        for field in ["attribution", "host_bundle_id", "embedded", "disclaim_env", "pid", "responsible_ppid"] {
            var invalidSource = source
            invalidSource.removeValue(forKey: field)
            let invalid: [String: Any] = ["accessibility": true, "screen_recording": true, "source": invalidSource]
            #expect(try !CuaDriverPermissionSnapshot.parse(invalid, daemonPID: 1234, hostPID: 1000).hostAttributionValid)
        }
        #expect(throws: CuaMCPProxyError.functionalProbeFailed) {
            try CuaDriverPermissionSnapshot.parse(["accessibility": true, "screen_recording": true], daemonPID: 1234, hostPID: 1000)
        }
    }
}
