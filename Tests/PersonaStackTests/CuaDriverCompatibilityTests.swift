import Foundation
import Testing
@testable import PersonaStackCore

struct CuaDriverCompatibilityTests {
    @Test func pinnedReleaseAndRequiredToolSetValidate() throws {
        let manifest = Data(#"{"binary_version":"0.28.2","schema_version":"1"}"#.utf8)
        try CuaDriverCompatibility.validate(manifestData: manifest,
                                            toolNames: CuaDriverCompatibility.requiredTools)
        #expect(CuaDriverCompatibility.archiveSHA256 == "e273181b26709c88b1d809474deb3c592b4efae3530b11d76318f1887fc3fbb1")
        #expect(CuaDriverCompatibility.exposedTools.isSuperset(of: CuaDriverCompatibility.requiredTools))
        #expect(CuaDriverCompatibility.licenseNotice.contains("Copyright (c) 2025 Cua AI, Inc."))
        #expect(CuaDriverCompatibility.licenseNotice.contains("permission notice shall be included"))
        #expect(CuaDriverCompatibility.managedServiceEnvironment == [
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
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
        ])
    }

    @Test func mismatchedVersionSchemaAndCatalogFailClosed() throws {
        let wrongVersion = Data(#"{"binary_version":"0.28.3","schema_version":"1"}"#.utf8)
        #expect(throws: CuaDriverCompatibility.ValidationError.unsupportedVersion) {
            try CuaDriverCompatibility.validate(manifestData: wrongVersion,
                                                toolNames: CuaDriverCompatibility.requiredTools)
        }
        let wrongSchema = Data(#"{"binary_version":"0.28.2","schema_version":"2"}"#.utf8)
        #expect(throws: CuaDriverCompatibility.ValidationError.unsupportedSchema) {
            try CuaDriverCompatibility.validate(manifestData: wrongSchema,
                                                toolNames: CuaDriverCompatibility.requiredTools)
        }
        #expect(throws: CuaDriverCompatibility.ValidationError.missingRequiredTools(["click"])) {
            try CuaDriverCompatibility.validate(manifestData: Data(#"{"binary_version":"0.28.2","schema_version":"1"}"#.utf8),
                                                toolNames: CuaDriverCompatibility.requiredTools.subtracting(["click"]))
        }
    }

    @Test func toolNamesParseFromReviewedCliOutput() {
        let output = "get_desktop_state: Capture desktop\nclick: Click\nmalformed output\n"
        #expect(CuaDriverCompatibility.parseToolNames(output) == ["get_desktop_state", "click"])
    }
}
