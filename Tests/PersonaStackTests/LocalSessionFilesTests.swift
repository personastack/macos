import CryptoKit
import Foundation
import Testing
@testable import PersonaStackCore

final class HarnessFilesFixture: @unchecked Sendable {
    let root: URL
    let profile: URL
    let executable: URL
    let harness: LocalSessionHarness
    var calls: [[String]] = []
    var marketplaces: [String: String] = [:]
    var installed: Set<String> = []
    var servers: [String: String] = [:]
    var failLogin = false
    var failLogout = false
    var failPlugin = false
    var failPluginRemoval = false
    var failMCPRead = false
    var transportEdits: [String: Any] = [:]
    let source = LocalSessionBundleTests()
    private let ownsRoot: Bool

    init(_ harness: LocalSessionHarness, home: URL? = nil, profileRelative: String = "profile") throws {
        self.harness = harness
        ownsRoot = home == nil
        root = home ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("connections-" + UUID().uuidString)
        profile = root.appendingPathComponent(profileRelative)
        executable = root.appendingPathComponent("cli")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    deinit { if ownsRoot { try? FileManager.default.removeItem(at: root) } }
    var probe: LocalSessionHarnessProbe { .init(executable: executable, home: root, profile: profile, shell: URL(fileURLWithPath: "/bin/zsh")) }
    func bundle(_ id: UUID, persona: String = "persona-a") throws -> LocalSessionBundle {
        var body = source.fixture()
        let connection = id.uuidString.lowercased()
        body["harness"] = harness.rawValue; body["connection_id"] = connection; body["persona_id"] = persona
        body["persona_name"] = persona
        body["mcp_url"] = "https://mcp.personastack.ai/v1/mcp?connection_id=" + connection + "&persona_id=" + persona + "&workspace_id=ws_11111111111111111111111111111111"
        return try LocalSessionBundle.decode(JSONSerialization.data(withJSONObject: body), appURL: source.appURL, now: source.now)
    }
    func installLegacy() throws -> String {
        let profileKey = SHA256.hash(data: Data(profile.resolvingSymlinksInPath().path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let marketplace = "personastack-desktop-" + profileKey
        let plugin = "personastack-local-" + profileKey
        let folder = root.appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/" + (harness == .codex ? "codex" : "claude-code") + "/" + profileKey)
        let directory = folder.appendingPathComponent(UUID().uuidString.lowercased())
        let market = directory.appendingPathComponent("marketplace")
        let pluginRoot = market.appendingPathComponent("plugins/" + plugin)
        try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent("skills/personastack"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let token = String(repeating: "b", count: 64)
        let server: [String: Any] = ["type": "http", "url": "https://mcp.personastack.ai/v1/mcp", "headers": ["Authorization": "Bearer " + token]]
        let mcp: [String: Any] = harness == .codex ? ["mcpServers": ["personastack_local": server]] : ["personastack_local": server]
        try JSONSerialization.data(withJSONObject: mcp).write(to: pluginRoot.appendingPathComponent(".mcp.json"))
        try Data("Old context".utf8).write(to: pluginRoot.appendingPathComponent("skills/personastack/SKILL.md"))
        let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])!
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var content: [(String, Data)] = []
        for case let path as URL in entries {
            let isDirectory = try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: path.path)
            if !isDirectory {
                let relative = path.path.components(separatedBy: "/" + directory.lastPathComponent + "/").last!
                content.append((relative, try Data(contentsOf: path)))
            }
        }
        var digest = SHA256()
        for (path, data) in content.sorted(by: { $0.0 < $1.0 }) {
            digest.update(data: Data(path.utf8)); digest.update(data: Data([0])); digest.update(data: data); digest.update(data: Data([0]))
        }
        let owner: [String: Any] = ["format": 1, "harness": harness == .codex ? "codex" : "claude-code", "marketplace": marketplace, "plugin": plugin, "profile": profile.resolvingSymlinksInPath().path, "source": directory.path, "digest": digest.finalize().map { String(format: "%02x", $0) }.joined()]
        for path in [folder.appendingPathComponent("active.json"), directory.appendingPathComponent(".personastack-plugin-owner.json")] {
            try JSONSerialization.data(withJSONObject: owner).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        marketplaces[marketplace] = market.path; installed.insert(plugin + "@" + marketplace)
        let cache = profile.appendingPathComponent("plugins/cache/" + marketplace + "/" + plugin + "/1.0.0")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pluginRoot, to: cache)
        return token
    }

    var files: LocalSessionFiles {
        LocalSessionFiles(manager: .default, commandRunner: { [self] _, args, env, _ in
            #expect(env[harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] == profile.path)
            calls.append(args)
            if args.starts(with: ["plugin", "marketplace", "add"]) {
                let path = args[3]
                let manifestPath = harness == .codex ? ".agents/plugins/marketplace.json" : ".claude-plugin/marketplace.json"
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(manifestPath))) as! [String: Any]
                marketplaces[value["name"] as! String] = path
            } else if args.starts(with: ["plugin", "marketplace", "remove"]) {
                marketplaces.removeValue(forKey: args[3])
            } else if args.starts(with: ["plugin", "add"]) || args.starts(with: ["plugin", "install"]) {
                if failPlugin { throw LocalSessionError.unsafeFiles }
                let identifier = harness == .codex ? args[2] + "@" + args[4] : args[2]
                let parts = identifier.split(separator: "@").map(String.init)
                let source = URL(fileURLWithPath: marketplaces[parts[1]]!).appendingPathComponent("plugins/" + parts[0])
                let cache = profile.appendingPathComponent("plugins/cache/" + parts[1] + "/" + parts[0] + "/1.0.0")
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: cache)
                installed.insert(identifier)
            } else if args.starts(with: ["plugin", "remove"]) || args.starts(with: ["plugin", "uninstall"]) {
                if failPluginRemoval { throw LocalSessionError.unsafeFiles }
                let parts = args[2].split(separator: "@").map(String.init)
                try? FileManager.default.removeItem(at: profile.appendingPathComponent("plugins/cache/" + parts[1] + "/" + parts[0] + "/1.0.0"))
                installed.remove(args[2])
            } else if args.starts(with: ["mcp", "add"]) {
                let name = harness == .codex ? args[2] : args[6]
                guard servers[name] == nil else { throw LocalSessionError.unsafeFiles }
                servers[name] = args.last!
            } else if args.starts(with: ["mcp", "login"]) {
                if failLogin { throw LocalSessionError.unsafeFiles }
            } else if args.starts(with: ["mcp", "logout"]) {
                if failLogout { throw LocalSessionError.unsafeFiles }
            } else if args.starts(with: ["mcp", "remove"]) {
                servers.removeValue(forKey: args[2])
            } else if args == ["features", "enable", "hooks"] {
                #expect(harness == .codex)
            } else { Issue.record("Unexpected mutation: \(args.prefix(2))"); throw LocalSessionError.invalidRequest }
        }, commandOutputReader: { [self] _, args, _ in
            if args.starts(with: ["mcp", "get"]) {
                if failMCPRead { throw LocalSessionError.unsafeFiles }
                guard let url = servers[args[2]] else { throw LocalSessionError.missingMCP }
                if harness == .claudeCode { return "\(args[2]):\nType: http\nURL: \(url)\n" }
                var transport: [String: Any] = ["type": "streamable_http", "url": url]
                transport.merge(transportEdits) { _, edit in edit }
                return try json(["name": args[2], "transport": transport])
            }
            if args.starts(with: ["mcp", "list"]) { return try json(servers.keys.map { ["name": $0] }) }
            if args.starts(with: ["plugin", "marketplace", "list"]) {
                let records = marketplaces.map { ["name": $0.key, harness == .codex ? "root" : "path": $0.value] }
                return try json(harness == .codex ? ["marketplaces": records] : records)
            }
            if args.starts(with: ["plugin", "list"]) {
                let records: [[String: Any]] = installed.map { identifier in
                    let parts = identifier.split(separator: "@").map(String.init)
                    let market = marketplaces[parts[1]]!
                    if harness == .codex {
                        return ["pluginId": identifier, "enabled": true, "version": "1.0.0", "source": ["path": market + "/plugins/" + parts[0]], "marketplaceSource": ["source": market]]
                    }
                    return ["id": identifier, "enabled": true, "scope": "user", "installPath": profile.appendingPathComponent("plugins/cache/" + parts[1] + "/" + parts[0] + "/1.0.0").path]
                }
                return try json(["installed": records])
            }
            Issue.record("Unexpected protected read: \(args.prefix(2))"); throw LocalSessionError.invalidRequest
        })
    }
    private func json(_ value: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
    func configure(_ id: UUID, persona: String = "persona-a") throws -> LocalSessionInstalledFiles {
        try files.configure(bundle: bundle(id, persona: persona), appURL: source.appURL, home: root, profile: profile, sessionID: UUID(), executable: executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: source.now)
    }
}

struct LocalSessionFilesTests {
    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func multiplePersonasCoexistAndRemovalPreservesSiblingAndUnrelatedServers(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        fixture.servers["unrelated"] = "https://other.example/mcp"
        let a = UUID(), b = UUID()
        let first = try fixture.configure(a)
        let second = try fixture.configure(b, persona: "persona-b")
        #expect(fixture.servers.count == 3)
        #expect(fixture.installed.count == 2)
        #expect(try fixture.files.connections(harness, probe: fixture.probe, appURL: fixture.source.appURL).count == 2)
        for (connection, installed) in [(a, first), (b, second)] {
            let plugin = try #require(FileManager.default.contentsOfDirectory(at: installed.directory.appendingPathComponent("marketplace/plugins"), includingPropertiesForKeys: nil).first)
            let hookData = try Data(contentsOf: plugin.appendingPathComponent("hooks/hooks.json"))
            let document = try #require(JSONSerialization.jsonObject(with: hookData) as? [String: Any])
            let hooks = try #require(document["hooks"] as? [String: [[String: Any]]])
            let events = harness == .codex ? ["UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"] : ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
            #expect(Set(hooks.keys) == Set(events))
            for event in events {
                let commands = try #require(hooks[event]?.first?["hooks"] as? [[String: Any]])
                let command = try #require(commands.first?["command"] as? String)
                #expect(command.contains("--connection '" + connection.uuidString.lowercased() + "' --event " + event))
            }
        }
        try fixture.files.remove(a.uuidString, harness: harness, probe: fixture.probe, appURL: fixture.source.appURL)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
        #expect(fixture.servers[LocalSessionFiles.serverName(a.uuidString)] == nil)
        #expect(fixture.servers[LocalSessionFiles.serverName(b.uuidString)] != nil)
        #expect(fixture.servers["unrelated"] == "https://other.example/mcp")
        #expect(try fixture.files.connections(harness, probe: fixture.probe, appURL: fixture.source.appURL).count == 1)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func generatedPluginHasNamespacedContextHooksAndNoMCPCredential(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        let id = UUID(); let result = try fixture.configure(id)
        let plugin = try #require(FileManager.default.contentsOfDirectory(at: result.directory.appendingPathComponent("marketplace/plugins"), includingPropertiesForKeys: nil).first)
        #expect(!FileManager.default.fileExists(atPath: plugin.appendingPathComponent(".mcp.json").path))
        let hook = try String(contentsOf: plugin.appendingPathComponent("hooks/hooks.json"), encoding: .utf8)
        #expect(hook.contains(id.uuidString.lowercased()))
        #expect(!hook.contains(String(repeating: "a", count: 64)))
        let context = try String(contentsOf: result.skillDirectories[0].appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(context.contains(LocalSessionFiles.serverName(id.uuidString)))
        #expect(context.contains("explicitly requested"))
        #expect(fixture.calls.contains(["mcp", "login", LocalSessionFiles.serverName(id.uuidString)]))
        #expect(!FileManager.default.fileExists(atPath: fixture.profile.appendingPathComponent("AGENTS.md").path))
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func repairsOnlySameConnectionAndRejectsAlteredOwnedFiles(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        let a = UUID(), b = UUID()
        let first = try fixture.configure(a)
        _ = try fixture.configure(b, persona: "persona-b")
        let repaired = try fixture.configure(a)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(fixture.installed.count == 2)
        try Data("User changes".utf8).write(to: repaired.skillDirectories[0].appendingPathComponent("SKILL.md"))
        let count = fixture.calls.count
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(a.uuidString, harness: harness, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(fixture.calls.count == count)
        #expect(fixture.servers.count == 2)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func partialOAuthFailureIsVisibleAndCanRepair(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        let id = UUID(); fixture.failLogin = true
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.configure(id) }
        #expect(try fixture.files.connections(harness, probe: fixture.probe, appURL: fixture.source.appURL).count == 1)
        fixture.failLogin = false
        _ = try fixture.configure(id)
        #expect(fixture.servers.count == 1)
        #expect(fixture.installed.count == 1)
    }

    @Test func logoutFailureDoesNotClaimRemovalOrDeleteOwnedSource() throws {
        let fixture = try HarnessFilesFixture(.codex)
        let id = UUID(); let source = try fixture.configure(id)
        fixture.failLogout = true
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(id.uuidString, harness: .codex, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(FileManager.default.fileExists(atPath: source.directory.path))
        #expect(fixture.installed.count == 1)
        #expect(fixture.servers.count == 1)
    }

    @Test func rejectsRepointedMCPAndMarketplaceBeforeRemoval() throws {
        let fixture = try HarnessFilesFixture(.codex)
        let id = UUID(); _ = try fixture.configure(id)
        fixture.servers[LocalSessionFiles.serverName(id.uuidString)] = "https://other.example/mcp"
        let mutations = fixture.calls.count
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(id.uuidString, harness: .codex, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(fixture.calls.count == mutations)
        #expect(fixture.installed.count == 1)
    }
    @Test func partialRemovalRetriesOnlyRemainingSteps() throws {
        let fixture = try HarnessFilesFixture(.codex)
        let id = UUID(); _ = try fixture.configure(id)
        fixture.failPluginRemoval = true
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(id.uuidString, harness: .codex, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(fixture.servers.isEmpty)
        #expect(fixture.installed.count == 1)
        fixture.failPluginRemoval = false
        try fixture.files.remove(id.uuidString, harness: .codex, probe: fixture.probe, appURL: fixture.source.appURL)
        #expect(fixture.calls.filter { $0.starts(with: ["mcp", "remove"]) }.count == 1)
        #expect(try fixture.files.connections(.codex, probe: fixture.probe, appURL: fixture.source.appURL).isEmpty)
    }

    @Test func canonicalProfileSymlinkRemainsUnchanged() throws {
        let fixture = try HarnessFilesFixture(.codex)
        let alias = fixture.root.appendingPathComponent(".codex")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.profile)
        let id = UUID()
        _ = try fixture.files.configure(bundle: fixture.bundle(id), appURL: fixture.source.appURL, home: fixture.root, profile: alias, sessionID: UUID(), executable: fixture.executable, loginShell: URL(fileURLWithPath: "/bin/zsh"), now: fixture.source.now)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == fixture.profile.path)
        #expect(fixture.servers.count == 1)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func legacyRemovalUsesOnlyVerifiedOldBearerAndPreservesNewConnections(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        let token = try fixture.installLegacy()
        _ = try fixture.configure(UUID(), persona: "persona-b")
        let records = try fixture.files.connections(harness, probe: fixture.probe, appURL: fixture.source.appURL)
        let legacyRecord = records.first { $0.legacy }
        let legacy = try #require(legacyRecord)
        #expect(legacy.personaName == "Previous PersonaStack connection")
        #expect(legacy.connectionID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil)
        let storedCredential = try fixture.files.legacyCredential(legacy.connectionID, harness: harness, probe: fixture.probe, appURL: fixture.source.appURL)
        let credential = try #require(storedCredential)
        #expect(credential.activityToken == token)
        #expect(!credential.routingEnabled)
        try fixture.files.remove(legacy.connectionID, harness: harness, probe: fixture.probe, appURL: fixture.source.appURL)
        let remaining = try fixture.files.connections(harness, probe: fixture.probe, appURL: fixture.source.appURL)
        #expect(remaining.count == 1 && !remaining[0].legacy)
        #expect(fixture.servers.count == 1 && fixture.installed.count == 1)
    }

    @Test(arguments: [LocalSessionHarness.codex, .claudeCode])
    func externallyRemovedMCPDoesNotStrandOwnedHooks(_ harness: LocalSessionHarness) throws {
        let fixture = try HarnessFilesFixture(harness)
        let removed = UUID(), sibling = UUID()
        let source = try fixture.configure(removed)
        _ = try fixture.configure(sibling, persona: "persona-b")
        fixture.servers.removeValue(forKey: LocalSessionFiles.serverName(removed.uuidString))
        let before = fixture.calls.count
        try fixture.files.remove(removed.uuidString, harness: harness, probe: fixture.probe, appURL: fixture.source.appURL)
        #expect(!FileManager.default.fileExists(atPath: source.directory.path))
        #expect(fixture.installed.count == 1 && fixture.servers.count == 1)
        #expect(!fixture.calls.dropFirst(before).contains { $0.starts(with: ["mcp", "logout"]) || $0.starts(with: ["mcp", "remove"]) })
    }

    @Test func genericMCPReadFailureCannotAuthorizeRemoval() throws {
        let fixture = try HarnessFilesFixture(.claudeCode)
        let id = UUID(), source = try fixture.configure(id)
        fixture.failMCPRead = true
        let before = fixture.calls.count
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(id.uuidString, harness: .claudeCode, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(fixture.calls.count == before)
        #expect(FileManager.default.fileExists(atPath: source.directory.path))
    }

    @Test func missingMCPDiagnosticsRequireExactNamedGetFailure() {
        let args = ["mcp", "get", "personastack-fixture"]
        #expect(LocalSessionFiles.documentedMissingMCP(args, output: "", error: "Error: No MCP server named 'personastack-fixture' found.\n"))
        #expect(LocalSessionFiles.documentedMissingMCP(args, output: "No MCP server named \"personastack-fixture\". Configured servers: other\n", error: ""))
        #expect(!LocalSessionFiles.documentedMissingMCP(args, output: "", error: "Network connection failed"))
        #expect(!LocalSessionFiles.documentedMissingMCP(args, output: "No MCP server named \"personastack-fixture\". Network connection failed", error: ""))
        #expect(!LocalSessionFiles.documentedMissingMCP(args, output: "", error: "Error: No MCP server named 'other' found."))
        #expect(!LocalSessionFiles.documentedMissingMCP(["mcp", "remove", "personastack-fixture"], output: "", error: "Error: No MCP server named 'personastack-fixture' found."))
    }

    @Test(arguments: ["env_http_headers", "http_headers_helper"])
    func userAddedHeaderAuthorityPreventsRemoval(_ field: String) throws {
        let fixture = try HarnessFilesFixture(.codex)
        let id = UUID(), source = try fixture.configure(id)
        fixture.transportEdits[field] = field == "env_http_headers" ? ["Authorization": "USER_TOKEN"] : "user-header-helper"
        let before = fixture.calls.count
        #expect(throws: LocalSessionError.unsafeFiles) { try fixture.files.remove(id.uuidString, harness: .codex, probe: fixture.probe, appURL: fixture.source.appURL) }
        #expect(fixture.calls.count == before)
        #expect(FileManager.default.fileExists(atPath: source.directory.path))
    }

}
