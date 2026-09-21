import CryptoKit
import Foundation
import Testing
@testable import PersonaStackCore

private final class LocalSessionCommandRecorder: @unchecked Sendable {
    var calls: [[String]] = []
    var failedPluginAdds = 0
    var marketplace = ""
}

struct LocalSessionFilesTests {
    private func fixture(_ harness: LocalSessionHarness) throws -> LocalSessionBundle {
        let base = LocalSessionBundleTests()
        var object = base.fixture()
        object["harness"] = harness.rawValue
        let files = [LocalSessionSkillFile(relativePath: "SKILL.md", content: "---\nname: source\ndescription: Test skill\n---\n\nUse it.\n"),
                     LocalSessionSkillFile(relativePath: "references/asset.txt", content: "selected bytes\n")]
        let skill = LocalSessionSkill(skillID: "skill-a", slug: "source", digest: LocalSessionSkill.digest(files), files: files)
        object["skills"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([skill]))
        return try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: object), appURL: base.appURL, now: base.now)
    }

    private func home() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("personastack-plugin-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }

    private func configure(_ harness: LocalSessionHarness, home: URL, recorder: LocalSessionCommandRecorder) throws -> LocalSessionInstalledFiles {
        let executable = home.appendingPathComponent("cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = home.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let marketplaceName = "personastack-desktop-" + profileKey
        let pluginName = "personastack-local-" + profileKey
        let plugins = home.appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/" + (harness == .codex ? "codex" : "claude-code") + "/" + profileKey)
        let sourceKey = harness == .codex ? "root" : "path"
        return try LocalSessionFiles(manager: .default, commandRunner: { _, arguments, environment, _ in
            #expect(environment["HOME"] == home.path)
            #expect(environment[harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == profile.path)
            recorder.calls.append(arguments)
            if Array(arguments.prefix(3)) == ["plugin", "marketplace", "add"] {
                guard let added = arguments.last else { throw LocalSessionError.unsafeFiles }
                recorder.marketplace = added
            }
            if Array(arguments.prefix(2)) == ["plugin", "remove"] || Array(arguments.prefix(2)) == ["plugin", "uninstall"] {
                try? FileManager.default.removeItem(at: profile.appendingPathComponent("plugins/cache/" + marketplaceName + "/" + pluginName + "/1.0.0"))
            }
            if Array(arguments.prefix(2)) == ["plugin", "add"] || Array(arguments.prefix(2)) == ["plugin", "install"] {
                let source = URL(fileURLWithPath: recorder.marketplace).appendingPathComponent("plugins/" + pluginName)
                let cache = profile.appendingPathComponent("plugins/cache/" + marketplaceName + "/" + pluginName + "/1.0.0")
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: cache)
            }
        }, commandOutputReader: { _, arguments, _ in
            if Array(arguments.prefix(2)) == ["plugin", "list"] {
                let cache = profile.appendingPathComponent("plugins/cache/" + marketplaceName + "/" + pluginName + "/1.0.0")
                let record: [String: Any]
                if harness == .codex {
                    record = ["pluginId": pluginName + "@" + marketplaceName, "version": "1.0.0", "enabled": true,
                              "source": ["path": URL(fileURLWithPath: recorder.marketplace).appendingPathComponent("plugins/" + pluginName).path],
                              "marketplaceSource": ["source": recorder.marketplace]]
                } else {
                    record = ["id": pluginName + "@" + marketplaceName, "version": "1.0.0", "enabled": true, "scope": "user", "installPath": cache.path]
                }
                return String(data: try JSONSerialization.data(withJSONObject: ["installed": [record]]), encoding: .utf8)!
            }
            if recorder.marketplace.isEmpty {
                let object: Any = harness == .codex ? ["marketplaces": []] : []
                return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            }
            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: plugins.appendingPathComponent("active.json"))) as? [String: Any]
            guard let source = active?["source"] as? String else { throw LocalSessionError.unsafeFiles }
            let record: [String: Any] = ["name": marketplaceName, sourceKey: URL(fileURLWithPath: source).appendingPathComponent("marketplace").path]
            let object: Any = harness == .codex ? ["marketplaces": [record]] : [record]
            return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }).configure(bundle: fixture(harness), appURL: LocalSessionBundleTests().appURL, home: home,
                     profile: profile, sessionID: UUID(), executable: executable,
                     loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func configureWritesPrivatePluginAndOnlyUsesPluginManager(_ harness: LocalSessionHarness) throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let result = try configure(harness, home: root, recorder: recorder)
        let pluginRoot = result.directory.appendingPathComponent("marketplace/plugins")
        let plugin = try #require(FileManager.default.contentsOfDirectory(at: pluginRoot, includingPropertiesForKeys: nil).first)
        let mcp = try String(contentsOf: plugin.appendingPathComponent(".mcp.json"), encoding: .utf8)
        #expect(mcp.contains("Bearer "))
        #expect(mcp.contains("personastack_local"))
        #expect(mcp.contains("https://mcp.personastack.ai"))
        #expect(FileManager.default.fileExists(atPath: result.pluginManifest.path))
        #expect(FileManager.default.fileExists(atPath: plugin.appendingPathComponent("skills/personastack/SKILL.md").path))
        #expect(result.skillDirectories.count == 2)
        #expect(recorder.calls.count == 2)
        #expect(Array(recorder.calls[0].prefix(3)) == ["plugin", "marketplace", "add"])
        #expect(Array(recorder.calls[1].prefix(2)) == ["plugin", harness == .codex ? "add" : "install"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path))
    }

    @Test func configureRejectsAnUnownedMarketplaceBeforeAnyPluginCommand() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let recorder = LocalSessionCommandRecorder()
        let files = LocalSessionFiles(manager: .default, commandRunner: { _, arguments, _, _ in recorder.calls.append(arguments) },
                                      commandOutputReader: { _, _, _ in
            let record: [String: Any] = ["name": "personastack-desktop-" + profileKey, "root": root.appendingPathComponent("unowned").path]
            return String(data: try JSONSerialization.data(withJSONObject: ["marketplaces": [record]]), encoding: .utf8)!
        })
        #expect(throws: LocalSessionError.unsafeFiles) {
            try files.configure(bundle: fixture(.codex), appURL: LocalSessionBundleTests().appURL, home: root, profile: profile,
                                sessionID: UUID(), executable: executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test func configureReplacesOnlyRecordedPersonaStackSource() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(.codex, home: root, recorder: recorder)
        let second = try configure(.codex, home: root, recorder: recorder)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
        #expect(recorder.calls.suffix(4).map { Array($0.prefix(2)) } == [["plugin", "remove"], ["plugin", "marketplace"], ["plugin", "marketplace"], ["plugin", "add"]])
    }

    @Test func configureRefusesToRemoveModifiedPersonaStackSource() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(.codex, home: root, recorder: recorder)
        let plugin = try #require(FileManager.default.contentsOfDirectory(at: first.directory.appendingPathComponent("marketplace/plugins"), includingPropertiesForKeys: nil).first)
        let skill = plugin.appendingPathComponent("skills/personastack/SKILL.md")
        try Data("modified\n".utf8).write(to: skill)

        #expect(throws: LocalSessionError.unsafeFiles) { try configure(.codex, home: root, recorder: recorder) }
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(recorder.calls.count == 2)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func configureRefusesToRemoveModifiedInstalledPlugin(_ harness: LocalSessionHarness) throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(harness, home: root, recorder: recorder)
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let plugin = "personastack-local-" + profileKey
        let cache = profile.appendingPathComponent("plugins/cache/personastack-desktop-" + profileKey + "/" + plugin + "/1.0.0")
        try Data("modified\n".utf8).write(to: cache.appendingPathComponent("skills/personastack/SKILL.md"))

        #expect(throws: LocalSessionError.unsafeFiles) { try configure(harness, home: root, recorder: recorder) }
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(recorder.calls.count == 2)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func configureRefusesToRemoveInstalledPluginWithExtraFiles(_ harness: LocalSessionHarness) throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(harness, home: root, recorder: recorder)
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let cache = profile.appendingPathComponent("plugins/cache/personastack-desktop-" + profileKey + "/personastack-local-" + profileKey + "/1.0.0")
        try Data("extra\n".utf8).write(to: cache.appendingPathComponent("user-note.txt"))

        #expect(throws: LocalSessionError.unsafeFiles) { try configure(harness, home: root, recorder: recorder) }
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(recorder.calls.count == 2)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func configureRefusesToRemoveInstalledPluginWithOwnershipMarkerCollision(_ harness: LocalSessionHarness) throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(harness, home: root, recorder: recorder)
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let cache = profile.appendingPathComponent("plugins/cache/personastack-desktop-" + profileKey + "/personastack-local-" + profileKey + "/1.0.0")
        try Data("user marker\n".utf8).write(to: cache.appendingPathComponent(".personastack-plugin-owner.json"))

        #expect(throws: LocalSessionError.unsafeFiles) { try configure(harness, home: root, recorder: recorder) }
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(recorder.calls.count == 2)
    }

    @Test func configureRefusesToRemoveRepointedMarketplace() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = LocalSessionCommandRecorder()
        let first = try configure(.codex, home: root, recorder: recorder)
        let executable = root.appendingPathComponent("cli")
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let marketplaceName = "personastack-desktop-" + profileKey
        let files = LocalSessionFiles(manager: .default, commandRunner: { _, arguments, _, _ in recorder.calls.append(arguments) },
                                      commandOutputReader: { _, _, _ in
            let record: [String: Any] = ["name": marketplaceName, "root": root.appendingPathComponent("someone-elses-marketplace").path]
            return String(data: try JSONSerialization.data(withJSONObject: ["marketplaces": [record]]), encoding: .utf8)!
        })

        #expect(throws: LocalSessionError.unsafeFiles) {
            try files.configure(bundle: fixture(.codex), appURL: LocalSessionBundleTests().appURL, home: root, profile: profile,
                                sessionID: UUID(), executable: executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
        }
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(recorder.calls.count == 2)
    }

    @Test func configureRetainsStagedSourceAfterPluginManagerFailure() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let recorder = LocalSessionCommandRecorder()
        let files = LocalSessionFiles(manager: .default, commandRunner: { _, arguments, _, _ in
            recorder.calls.append(arguments)
            if Array(arguments.prefix(2)) == ["plugin", "add"] { throw LocalSessionError.unsafeFiles }
        }, commandOutputReader: { _, _, _ in
            String(data: try JSONSerialization.data(withJSONObject: ["marketplaces": []]), encoding: .utf8)!
        })

        #expect(throws: LocalSessionError.unsafeFiles) {
            try files.configure(bundle: fixture(.codex), appURL: LocalSessionBundleTests().appURL, home: root,
                                profile: root.appendingPathComponent("profile"), sessionID: UUID(), executable: executable,
                                loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
        }
        let staged = root.appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/codex")
        #expect(try FileManager.default.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil).count == 1)
        #expect(recorder.calls.contains(where: { Array($0.prefix(2)) == ["plugin", "add"] }))
    }

    @Test func configureRetriesAfterMarketplaceRegistrationAndPluginFailure() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let profile = root.appendingPathComponent("profile")
        let profileKey = SHA256.hash(data: Data(profile.path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let marketplaceName = "personastack-desktop-" + profileKey
        let plugins = root.appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/codex/" + profileKey)
        let recorder = LocalSessionCommandRecorder()
        recorder.failedPluginAdds = 1
        let files = LocalSessionFiles(manager: .default, commandRunner: { _, arguments, _, _ in
            recorder.calls.append(arguments)
            if Array(arguments.prefix(2)) == ["plugin", "add"], recorder.failedPluginAdds > 0 {
                recorder.failedPluginAdds -= 1
                throw LocalSessionError.unsafeFiles
            }
            if Array(arguments.prefix(3)) == ["plugin", "marketplace", "add"] {
                guard let source = arguments.last else { throw LocalSessionError.unsafeFiles }
                recorder.marketplace = source
            }
            if Array(arguments.prefix(2)) == ["plugin", "add"] && recorder.failedPluginAdds == 0 {
                let source = URL(fileURLWithPath: recorder.marketplace).appendingPathComponent("plugins/personastack-local-" + profileKey)
                let cache = profile.appendingPathComponent("plugins/cache/" + marketplaceName + "/personastack-local-" + profileKey + "/1.0.0")
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: cache)
            }
        }, commandOutputReader: { _, arguments, _ in
            if Array(arguments.prefix(2)) == ["plugin", "list"] {
                let plugin = "personastack-local-" + profileKey
                let cache = profile.appendingPathComponent("plugins/cache/" + marketplaceName + "/" + plugin + "/1.0.0")
                guard FileManager.default.fileExists(atPath: cache.path) else {
                    return String(data: try JSONSerialization.data(withJSONObject: ["installed": []]), encoding: .utf8)!
                }
                let record: [String: Any] = ["pluginId": plugin + "@" + marketplaceName, "version": "1.0.0", "enabled": true,
                                              "source": ["path": URL(fileURLWithPath: recorder.marketplace).appendingPathComponent("plugins/" + plugin).path],
                                              "marketplaceSource": ["source": recorder.marketplace]]
                return String(data: try JSONSerialization.data(withJSONObject: ["installed": [record]]), encoding: .utf8)!
            }
            guard FileManager.default.fileExists(atPath: plugins.appendingPathComponent("active.json").path) else {
                return String(data: try JSONSerialization.data(withJSONObject: ["marketplaces": []]), encoding: .utf8)!
            }
            let active = try JSONSerialization.jsonObject(with: Data(contentsOf: plugins.appendingPathComponent("active.json"))) as? [String: Any]
            guard let source = active?["source"] as? String else { throw LocalSessionError.unsafeFiles }
            let record: [String: Any] = ["name": marketplaceName, "root": URL(fileURLWithPath: source).appendingPathComponent("marketplace").path]
            return String(data: try JSONSerialization.data(withJSONObject: ["marketplaces": [record]]), encoding: .utf8)!
        })

        #expect(throws: LocalSessionError.unsafeFiles) {
            try files.configure(bundle: fixture(.codex), appURL: LocalSessionBundleTests().appURL, home: root, profile: profile,
                                sessionID: UUID(), executable: executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
        }
        _ = try files.configure(bundle: fixture(.codex), appURL: LocalSessionBundleTests().appURL, home: root, profile: profile,
                                sessionID: UUID(), executable: executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: LocalSessionBundleTests().now)
        #expect(recorder.calls.count == 5)
    }
}
