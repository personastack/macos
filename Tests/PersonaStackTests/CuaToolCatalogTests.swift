import Foundation
import Testing
@testable import PersonaStackCore

struct CuaToolCatalogTests {
    @Test(arguments: [true, false])
    func relocatedApplicationUsesOnlyItsPackagedCatalog(hasCatalog: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-package-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Relocated PersonaStack.app")
        let resources = app.appendingPathComponent("Contents/Resources/PersonaStackDesktop_PersonaStackCore.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "ai.personastack.catalog-fixture.\(UUID().uuidString)",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "PersonaStack"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let source = try #require(CuaToolCatalog.catalogURL())
        let catalog = resources.appendingPathComponent("cua-tools-0.29.1.json")
        if hasCatalog { try FileManager.default.copyItem(at: source, to: catalog) }
        let bundle = try #require(Bundle(url: app))
        let selected = CuaToolCatalog.catalogURL(application: bundle, developmentResource: {
            Issue.record("An installed app must never use SwiftPM's absolute build-path fallback")
            return source
        })
        if hasCatalog {
            #expect(selected?.standardizedFileURL == catalog.standardizedFileURL)
            let data = try Data(contentsOf: #require(selected))
            let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((manifest["tools"] as? [String: Any])?.count == 58)
            #expect(manifest["archive_sha256"] as? String == CuaDriverCompatibility.archiveSHA256)
        } else {
            #expect(selected == nil)
        }
    }

    @Test func pinnedCatalogIncludesTheWholeArtifact() {
        #expect(CuaToolCatalog.names.count == 58)
        #expect(CuaDriverCompatibility.requiredTools == CuaToolCatalog.names)
        #expect(CuaToolCatalog.names.isSuperset(of: ["start_recording", "page", "install_extension", "replay_trajectory", "list_sessions"]))
    }

    @Test func finiteArgumentValidationRejectsUnknownReservedAndWrongTypes() throws {
        try CuaToolCatalog.validate(tool: "start_recording", arguments: .object(["output_dir": .string("/tmp/fixture"), "record_video": .bool(true)]))
        for value: DesktopControlJSONValue in [
            .object([:]), .object(["output_dir": .number(1)]),
            .object(["output_dir": .string("/tmp/fixture"), "_session_id": .string("foreign")]),
            .object(["output_dir": .string("/tmp/fixture"), "unknown": .bool(true)]),
        ] {
            #expect(throws: CuaToolCatalog.ValidationError.invalidArguments) {
                try CuaToolCatalog.validate(tool: "start_recording", arguments: value)
            }
        }
        #expect(throws: CuaToolCatalog.ValidationError.unavailable) {
            try CuaToolCatalog.validate(tool: "unreviewed_tool", arguments: .object([:]))
        }
    }

    @Test func nestedSchemasAndNumericBoundsAreEnforced() throws {
        try CuaToolCatalog.validate(tool: "browser_prepare", arguments: .object([
            "allow_launch": .bool(true), "profile": .object(["mode": .string("isolated_named"), "name": .string("fixture")])]))
        #expect(throws: CuaToolCatalog.ValidationError.invalidArguments) {
            try CuaToolCatalog.validate(tool: "browser_prepare", arguments: .object([
                "profile": .object(["mode": .string("unrestricted")])]))
        }
        for delay in [-1.0, 10_001, 0.5, Double.infinity] {
            #expect(throws: CuaToolCatalog.ValidationError.invalidArguments) {
                try CuaToolCatalog.validate(tool: "replay_trajectory", arguments: .object([
                    "dir": .string("/tmp/fixture"), "delay_ms": .number(delay)]))
            }
        }
    }
}
