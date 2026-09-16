import Foundation
import Testing
@testable import PersonaStackCore

struct LocalSessionFilesTests {
    private func fixture(_ harness: LocalSessionHarness) throws -> LocalSessionBundle {
        let base = LocalSessionBundleTests()
        var object = base.fixture()
        object["harness"] = harness.rawValue
        let files = [LocalSessionSkillFile(relativePath: "SKILL.md", content: "---\nname: original\ndescription: Test skill\nlicense: MIT\n---\nUse references/asset.txt\n"),
                     LocalSessionSkillFile(relativePath: "references/asset.txt", content: "Keep original bytes.\r\n")]
        let skill = LocalSessionSkill(skillID: "skill-a", slug: "original", digest: LocalSessionSkill.digest(files), files: files)
        object["skills"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([skill]))
        return try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: object), appURL: base.appURL, now: base.now)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("personastack-files-" + UUID().uuidString + " user's $ ü", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func install(_ bundle: LocalSessionBundle, home: URL, id: UUID = UUID()) throws -> LocalSessionInstalledFiles {
        let base = LocalSessionBundleTests()
        return try LocalSessionFiles().install(bundle: bundle, appURL: base.appURL, home: home,
            profile: home.appendingPathComponent(".codex"), sessionID: id, executable: home.appendingPathComponent("bin/cli"),
            helper: URL(fileURLWithPath: "/Applications/PersonaStack.app/Contents/MacOS/PersonaStackLocalSession"),
            loginShell: URL(fileURLWithPath: "/bin/zsh"), now: base.now)
    }

    @Test func localSessionFilesPreserveProfilesAndReuseOwnedSkills() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        let profile = home.appendingPathComponent("profile")
        try manager.createDirectory(at: profile, withIntermediateDirectories: false)
        let original = Data("[mcp_servers.mine]\nurl = 'https://example.test'\n".utf8)
        try original.write(to: profile.appendingPathComponent("config.toml"))
        for name in [".codex", ".claude"] {
            try manager.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: profile)
        }
        let bundle = try fixture(.codex)
        let first = try #require(try? install(bundle, home: home), "Initial install must succeed")
        let second = try #require(try? install(bundle, home: home), "Owned snapshot reuse must succeed")
        #expect(first.directory != second.directory)
        #expect(first.skillDirectories == second.skillDirectories)
        #expect(try Data(contentsOf: profile.appendingPathComponent("config.toml")) == original)
        for name in [".codex", ".claude"] {
            #expect(try manager.destinationOfSymbolicLink(atPath: home.appendingPathComponent(name).path) == profile.path)
        }
        let skill = first.skillDirectories[0]
        #expect(try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("license: MIT"))
        #expect(try String(contentsOf: skill.appendingPathComponent("references/asset.txt"), encoding: .utf8) == "Keep original bytes.\r\n")
        for file in [first.directory.appendingPathComponent("bundle.json"), skill.appendingPathComponent("SKILL.md")] {
            #expect((try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        }
        #expect((try manager.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? Int) == 0o700)
        #expect(!(try String(contentsOf: first.launcher, encoding: .utf8)).contains(bundle.bearerToken))
        #expect(!(try String(contentsOf: first.directory.appendingPathComponent("persona.md"), encoding: .utf8)).contains(bundle.bearerToken))
        let invocation = try LocalSessionHelper.invocation(sessionID: UUID(uuidString: first.directory.lastPathComponent)!, environment: ["HOME": home.path, "UNCHANGED": "provider config stays local"], now: LocalSessionBundleTests().now)
        #expect(invocation.workingDirectory == home)
        #expect(invocation.environment["UNCHANGED"] == "provider config stays local")
        #expect(invocation.environment.values.contains(bundle.bearerToken))
        #expect(throws: LocalSessionError.staleRequest) {
            try LocalSessionHelper.invocation(sessionID: UUID(uuidString: first.directory.lastPathComponent)!, environment: ["HOME": home.path, "CODEX_HOME": home.appendingPathComponent("different-profile").path], now: LocalSessionBundleTests().now)
        }
        // Altered snapshots are never silently replaced.
        try Data("user change".utf8).write(to: skill.appendingPathComponent("references/asset.txt"))
        #expect(throws: LocalSessionError.unsafeFiles) { try install(bundle, home: home) }
        #expect(try String(contentsOf: skill.appendingPathComponent("references/asset.txt"), encoding: .utf8) == "user change")
    }

    @Test func localSessionHelperRejectsExposedOrSymlinkedCredentialFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try install(fixture(.codex), home: home)
        let id = UUID(uuidString: result.directory.lastPathComponent)!
        let file = result.directory.appendingPathComponent("bundle.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: LocalSessionError.unsafeFiles) {
            try LocalSessionHelper.invocation(sessionID: id, environment: ["HOME": home.path], now: LocalSessionBundleTests().now)
        }
        // Only disposable fixture data is removed here.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: result.directory.appendingPathComponent("context.json"))
        #expect(throws: LocalSessionError.unsafeFiles) {
            try LocalSessionHelper.invocation(sessionID: id, environment: ["HOME": home.path], now: LocalSessionBundleTests().now)
        }
    }

    @Test func localSessionClaudePluginAndPrivateMCP() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = try fixture(.claudeCode)
        let result = try install(bundle, home: home)
        #expect(result.skillDirectories[0].path.hasPrefix(result.directory.appendingPathComponent("plugin/skills").path + "/"))
        #expect(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("plugin/.claude-plugin/plugin.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents").path))
        let mcp = try String(contentsOf: result.directory.appendingPathComponent("mcp.json"), encoding: .utf8)
        #expect(mcp.contains("Bearer " + bundle.bearerToken))
        #expect(mcp.contains("personastack_local_"))
        #expect((try FileManager.default.attributesOfItem(atPath: result.directory.appendingPathComponent("mcp.json").path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func localSessionRejectsDirectorySymlinksAndDuplicateLaunchIDs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bundle = try fixture(.codex)
        let id = UUID()
        _ = try install(bundle, home: home, id: id)
        #expect(throws: LocalSessionError.unsafeFiles) { try install(bundle, home: home, id: id) }
        let secondHome = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: secondHome) }
        try FileManager.default.createSymbolicLink(at: secondHome.appendingPathComponent(".agents"), withDestinationURL: home)
        #expect(throws: LocalSessionError.unsafeFiles) { try install(bundle, home: secondHome) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("skills").path))
    }

    @Test func localSessionRejectsRetargetedProfileAndExposedSnapshots() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        let firstProfile = home.appendingPathComponent("first")
        let secondProfile = home.appendingPathComponent("second")
        for url in [firstProfile, secondProfile] { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
        let link = home.appendingPathComponent(".codex")
        try manager.createSymbolicLink(at: link, withDestinationURL: firstProfile)
        let bundle = try fixture(.codex)
        let result = try install(bundle, home: home)
        let id = UUID(uuidString: result.directory.lastPathComponent)!
        try manager.removeItem(at: link)
        try manager.createSymbolicLink(at: link, withDestinationURL: secondProfile)
        #expect(throws: LocalSessionError.staleRequest) {
            try LocalSessionHelper.invocation(sessionID: id, environment: ["HOME": home.path], now: LocalSessionBundleTests().now)
        }
        try manager.removeItem(at: link)
        try manager.createSymbolicLink(at: link, withDestinationURL: firstProfile)
        let root = result.skillDirectories[0]
        for (url, unsafeMode, originalMode) in [(root, 0o755, 0o700), (root.appendingPathComponent("references"), 0o770, 0o700), (root.appendingPathComponent("references/asset.txt"), 0o644, 0o600)] {
            try manager.setAttributes([.posixPermissions: unsafeMode], ofItemAtPath: url.path)
            #expect(throws: LocalSessionError.unsafeFiles) { try install(bundle, home: home) }
            try manager.setAttributes([.posixPermissions: originalMode], ofItemAtPath: url.path)
        }
        _ = try install(bundle, home: home)
    }
}
