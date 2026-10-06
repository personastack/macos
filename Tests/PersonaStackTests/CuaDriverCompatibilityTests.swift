import Foundation
import Testing
@testable import PersonaStackCore

struct CuaDriverCompatibilityTests {
    @Test func pinnedReleaseAndRequiredToolSetValidate() throws {
        let manifest = Data(#"{"binary_version":"0.29.1","schema_version":"1"}"#.utf8)
        try CuaDriverCompatibility.validate(manifestData: manifest,
                                            toolNames: CuaDriverCompatibility.requiredTools)
        #expect(CuaDriverCompatibility.archiveSHA256 == "ee376d59ef37afac29a10c60c71469ac85fdc8844d1884bd317edd8def29055a")
        #expect(CuaDriverCompatibility.exposedTools.isSubset(of: CuaDriverCompatibility.requiredTools))
        #expect(CuaDriverCompatibility.licenseNotice.contains("Copyright (c) 2025 Cua AI, Inc."))
        #expect(CuaDriverCompatibility.licenseNotice.contains("permission notice shall be included"))
        #expect(CuaDriverCompatibility.managedServiceEnvironment["CUA_DRIVER_EMBEDDED"] == nil)
        let probe = try JSONSerialization.jsonObject(with: CuaDriverCompatibility.permissionProbeArgumentsJSON) as? [String: Bool]
        #expect(probe == ["prompt": false, "probe_direct_capture": false])
        #expect(CuaDriverCompatibility.processEnvironment(from: [
            "HOME": "/tmp/profile",
            "PERSONASTACK_MACHINE_TOKEN": "do-not-forward",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "1",
        ]) == ["HOME": "/tmp/profile", "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0", "CUA_DRIVER_RS_UPDATE_CHECK": "false"])
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
            "attribution": "driver-daemon", "bundle_id": "com.trycua.driver",
            "disclaim_env": false, "pid": Int32(1234), "responsible_ppid": Int32(1000),
        ]
        let payload: [String: Any] = ["accessibility": false, "screen_recording": true, "source": source]
        let snapshot = try CuaDriverPermissionSnapshot.parseStandalone(payload, daemonPID: 1234,
                                                             verificationKey: "owned-generation")
        #expect(!snapshot.accessibility)
        #expect(snapshot.screenRecording)
        #expect(snapshot.standaloneAttributionValid)
        #expect(snapshot.verificationKey == "owned-generation")
        for field in ["attribution", "bundle_id", "pid"] {
            var invalidSource = source
            invalidSource.removeValue(forKey: field)
            let invalid: [String: Any] = ["accessibility": true, "screen_recording": true, "source": invalidSource]
            #expect(try !CuaDriverPermissionSnapshot.parseStandalone(invalid, daemonPID: 1234).standaloneAttributionValid)
        }
        #expect(throws: CuaMCPProxyError.functionalProbeFailed) {
            try CuaDriverPermissionSnapshot.parseStandalone(["accessibility": true, "screen_recording": true], daemonPID: 1234)
        }
    }

    @Test func passiveReadinessNeedsCUAsOwnDirectCaptureEvidence() throws {
        var payload: [String: Any] = ["accessibility": true, "screen_recording": true,
            "source": ["attribution": "driver-daemon", "bundle_id": "com.trycua.driver", "pid": 1234]]
        #expect(try !CuaDriverPermissionSnapshot.parseStandalone(payload, daemonPID: 1234).directCaptureVerified)
        payload["direct_capture_verification"] = ["bundle_id": "com.trycua.driver", "source": "permissions_grant", "verified_at": "2026-10-06T12:00:00Z"]
        #expect(try CuaDriverPermissionSnapshot.parseStandalone(payload, daemonPID: 1234).directCaptureVerified)
        payload["screen_recording_capturable"] = false
        #expect(try !CuaDriverPermissionSnapshot.parseStandalone(payload, daemonPID: 1234).directCaptureVerified)
        payload["screen_recording_capturable"] = NSNull()
        payload["direct_capture_verification_error"] = ["code": "unavailable"]
        #expect(try !CuaDriverPermissionSnapshot.parseStandalone(payload, daemonPID: 1234).directCaptureVerified)
    }

}
