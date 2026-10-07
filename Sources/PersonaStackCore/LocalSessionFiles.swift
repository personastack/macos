import CryptoKit
import Darwin
import Foundation
import OSLog

public struct LocalSessionInstalledFiles: Sendable {
    public let directory: URL
    public let pluginManifest: URL
    public let skillDirectories: [URL]
    public init(directory: URL, pluginManifest: URL, skillDirectories: [URL]) {
        self.directory = directory; self.pluginManifest = pluginManifest; self.skillDirectories = skillDirectories
    }
}

private struct LocalSkillOwnership: Codable, Equatable {
    let format: Int
    let origin: String
    let workspace: String
    let persona: String
    let profile: String
    let skill: String
    let digest: String
}

private struct LocalHarnessPluginOwnership: Codable, Equatable {
    let format: Int
    let harness: String
    let marketplace: String
    let plugin: String
    let profile: String
    let source: String
    let digest: String
    let connectionID: String
    let origin: String
    let workspaceID: String
    let personaID: String
    let personaName: String
    let mcpURL: String
    var mcpReady: Bool
    var hookReady: Bool
}

private struct LegacyHarnessPluginOwnership: Codable, Equatable {
    let format: Int
    let harness: String
    let marketplace: String
    let plugin: String
    let profile: String
    let source: String
    let digest: String
}

private struct LocalCodexMarketplace: Encodable {
    struct Plugin: Encodable {
        struct Source: Encodable { let source = "local"; let path: String }
        let name: String
        let source: Source
    }
    let name: String
    let plugins: [Plugin]
}

private struct LocalClaudeMarketplace: Encodable {
    struct Plugin: Encodable { let name: String; let source: String; let version: String }
    struct Owner: Encodable { let name: String }
    let name: String
    let description: String
    let owner: Owner
    let plugins: [Plugin]
}

private struct LocalPluginManifest: Encodable {
    let name: String
    let version: String
    let description: String
}

private enum LocalMarketplaceRegistration {
    case matches
    case missing
    case mismatch
}

/// Filesystem ownership is local to the desktop. No server-supplied destination is used.
public struct LocalSessionFiles {
    public typealias CommandRunner = @Sendable (URL, [String], [String: String], Bool) throws -> Void
    typealias CommandOutputReader = @Sendable (URL, [String], [String: String]) throws -> String

    private let helperURL: URL
    private let manager: FileManager
    private let commandRunner: CommandRunner
    private let commandOutputReader: CommandOutputReader
    private let logger = Logger(subsystem: "ai.personastack.desktop", category: "local-session")
    public init(manager: FileManager = .default, helperURL: URL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("PersonaStackHarnessHook")) {
        self.helperURL = helperURL
        self.manager = manager
        self.commandRunner = Self.run
        self.commandOutputReader = Self.readOutput
    }
    init(manager: FileManager, commandRunner: @escaping CommandRunner) {
        self.helperURL = URL(fileURLWithPath: "/usr/bin/true")
        self.manager = manager; self.commandRunner = commandRunner; self.commandOutputReader = Self.readOutput
    }
    init(manager: FileManager, commandRunner: @escaping CommandRunner,
         commandOutputReader: @escaping CommandOutputReader, helperURL: URL = URL(fileURLWithPath: "/usr/bin/true")) {
        self.helperURL = helperURL
        self.manager = manager; self.commandRunner = commandRunner; self.commandOutputReader = commandOutputReader
    }

    /// Read-only preflight runs before the hosted request can issue a credential.
    public func preflight(_ harnessValue: LocalSessionHarness, probe: LocalSessionHarnessProbe) throws {
        try requireDirectory(probe.home.resolvingSymlinksInPath().standardizedFileURL)
        try requireDirectory(probe.profile.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// Writes one private plugin source and installs it through the selected CLI's
    /// plugin manager. It never edits user instruction files or raw CLI config.
    public func configure(bundle: LocalSessionBundle, appURL: URL, home: URL, profile: URL,
                          sessionID: UUID, executable: URL, loginShell: URL, harnessEnvironment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws -> LocalSessionInstalledFiles {
        try bundle.validate(appURL: appURL, now: now)
        guard executable.isFileURL, loginShell.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalSessionError.missingHarness }
        let root = home.resolvingSymlinksInPath().standardizedFileURL
        try requireDirectory(root)
        let harness = bundle.harness == .codex ? "codex" : "claude-code"
        let profilePath = profile.resolvingSymlinksInPath().standardizedFileURL.path
        let profileKey = profileHash(profilePath)
        let connectionKey = bundle.connectionID.lowercased().replacingOccurrences(of: "-", with: "")
        let marketplaceName = "personastack-desktop-" + connectionKey
        let pluginName = "personastack-persona-" + connectionKey
        let plugins = try directories(["Library", "Application Support", "PersonaStack", "LocalHarnessPlugins", harness, profileKey], below: root)
        let activeURL = plugins.appendingPathComponent(connectionKey + ".json")
        logger.notice("local session plugin ownership validation started")
        let previous = try activeOwnership(at: activeURL, under: plugins, harness: harness, profile: profilePath, marketplace: marketplaceName, plugin: pluginName)
        logger.notice("local session plugin ownership validation completed")
        if previous == nil {
            let environment = pluginEnvironment(harness: bundle.harness, home: root, profile: profile, inherited: harnessEnvironment)
            logger.notice("local session initial marketplace preflight started")
            switch try marketplaceRegistration(bundle.harness, executable: executable, environment: environment, marketplace: marketplaceName, expectedRoot: nil) {
            case .missing: logger.notice("local session initial marketplace preflight completed")
            case .matches, .mismatch: throw LocalSessionError.unsafeFiles
            }
        }
        let directory = plugins.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        guard !exists(directory) else { throw LocalSessionError.unsafeFiles }
        var pluginManagerMutated = false
        var marketplaceRegistered = false
        var stagedOwnership: LocalHarnessPluginOwnership?
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let marketplace = try directories(["marketplace"], below: directory)
            let plugin = try directories(["plugins", pluginName], below: marketplace)
            let pluginMetadata = try directories([bundle.harness == .codex ? ".codex-plugin" : ".claude-plugin"], below: plugin)
            try write(JSONEncoder().encode(LocalPluginManifest(name: pluginName, version: "1.0.0", description: "Active PersonaStack local persona context and MCP connection.")), to: pluginMetadata.appendingPathComponent("plugin.json"))
            let serverName = Self.serverName(bundle.connectionID)
            let skillName = "personastack-" + connectionKey
            let skillRoot = try directories(["skills", skillName], below: plugin)
            let description = String(data: try JSONEncoder().encode("PersonaStack context for " + bundle.personaName + ". Use this context only when this persona is explicitly requested."), encoding: .utf8)!
            let skill = "---\nname: " + skillName + "\ndescription: " + description + "\n---\n\nMCP server: `" + serverName + "`.\nWorkspace: `" + bundle.workspaceID + "`.\nPersona: `" + bundle.personaID + "`.\n\n" + bundle.personaPrompt + "\n"
            try write(Data(skill.utf8), to: skillRoot.appendingPathComponent("SKILL.md"))
            try installHooks(bundle: bundle, plugin: plugin)
            var skillDirectories = [skillRoot]
            for selected in try preparedSkills(bundle: bundle, appURL: appURL, profile: profile) {
                let destination = try directories(["skills", selected.name], below: plugin)
                for file in selected.files { try writeArtifact(file, below: destination) }
                try write(selected.ownership, to: destination.appendingPathComponent(".personastack-owner.json"))
                skillDirectories.append(destination)
            }
            if bundle.harness == .codex {
                let manifest = LocalCodexMarketplace(name: marketplaceName, plugins: [.init(name: pluginName, source: .init(path: "./plugins/" + pluginName))])
                let metadata = try directories([".agents", "plugins"], below: marketplace)
                try write(JSONEncoder().encode(manifest), to: metadata.appendingPathComponent("marketplace.json"))
            } else {
                let metadata = try directories([".claude-plugin"], below: marketplace)
                let manifest = LocalClaudeMarketplace(name: marketplaceName, description: "Desktop-managed PersonaStack local harness plugin.", owner: .init(name: "PersonaStack"), plugins: [.init(name: pluginName, source: "./plugins/" + pluginName, version: "1.0.0")])
                try write(JSONEncoder().encode(manifest), to: metadata.appendingPathComponent("marketplace.json"))
            }
            var ownership = LocalHarnessPluginOwnership(format: 2, harness: harness, marketplace: marketplaceName, plugin: pluginName,
                                                        profile: profilePath, source: directory.path, digest: try ownedSourceDigest(directory),
                                                        connectionID: bundle.connectionID, origin: Self.origin(appURL), workspaceID: bundle.workspaceID,
                                                        personaID: bundle.personaID, personaName: bundle.personaName, mcpURL: bundle.mcpURL, mcpReady: false, hookReady: false)
            stagedOwnership = ownership
            try write(JSONEncoder().encode(ownership), to: directory.appendingPathComponent(".personastack-plugin-owner.json"))
            try installPlugin(bundle.harness, executable: executable, home: root, profile: profile, marketplace: marketplace,
                              harnessEnvironment: harnessEnvironment, ownership: ownership, previous: previous,
                              willMutate: { pluginManagerMutated = true },
                              marketplaceRegistered: { marketplaceRegistered = true })
            ownership.hookReady = true
            stagedOwnership = ownership
            try saveOwnership(ownership, at: activeURL)
            if bundle.harness == .codex { try commandRunner(executable, ["features", "enable", "hooks"], pluginEnvironment(harness: bundle.harness, home: root, profile: profile, inherited: harnessEnvironment), false) }
            try configureMCP(bundle, executable: executable, environment: pluginEnvironment(harness: bundle.harness, home: root, profile: profile, inherited: harnessEnvironment), previous: previous)
            ownership.mcpReady = true
            stagedOwnership = ownership
            try saveOwnership(ownership, at: activeURL)

            let installed = LocalSessionInstalledFiles(directory: directory, pluginManifest: pluginMetadata.appendingPathComponent("plugin.json"), skillDirectories: skillDirectories)
            // The new plugin is active. A stale owned source can be cleaned on a later Configure.
            if let previous { try? manager.removeItem(at: URL(fileURLWithPath: previous.source)) }
            return installed
        } catch {
            // Once a CLI command has begun, it may retain the supplied path even when it fails.
            // Preserve this private source so a subsequent Configure can repair that registration.
            if marketplaceRegistered, let stagedOwnership { try? replaceActiveOwnership(stagedOwnership, at: activeURL) }
            if !pluginManagerMutated { try? manager.removeItem(at: directory) }
            throw LocalSessionError.unsafeFiles
        }
    }

    public struct Connection: Codable, Sendable {
        public let connectionID: String
        public let workspaceID: String
        public let personaID: String
        public let personaName: String
        public let profile: String
        public let mcpURL: String
        public let legacy: Bool
        public let mcpReady: Bool
        public let hookReady: Bool
        enum CodingKeys: String, CodingKey {
            case connectionID = "connection_id", workspaceID = "workspace_id", personaID = "persona_id", personaName = "persona_name", profile, mcpURL = "mcp_url", legacy, mcpReady = "mcp_ready", hookReady = "hook_ready"
        }
    }

    public static func serverName(_ connectionID: String) -> String {
        "personastack-" + connectionID.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private static func origin(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? (url.scheme == "http" ? 80 : 443))"
    }

    private func connectionRoot(_ harness: LocalSessionHarness, probe: LocalSessionHarnessProbe) -> URL {
        probe.home.resolvingSymlinksInPath().appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/" + (harness == .codex ? "codex" : "claude-code") + "/" + profileHash(probe.profile.resolvingSymlinksInPath().path))
    }

    public func connections(_ harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws -> [Connection] {
        let root = connectionRoot(harness, probe: probe)
        guard exists(root) else { return [] }
        try requireOwnedDirectory(root)
        let names = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard names.count <= 256 else { throw LocalSessionError.unsafeFiles }
        var records: [Connection] = []
        for path in names where path.pathExtension == "json" && path.lastPathComponent != "active.json" {
            guard path.deletingPathExtension().lastPathComponent.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { continue }
            try requireOwnedFile(path)
            let value = try JSONDecoder().decode(LocalHarnessPluginOwnership.self, from: Data(contentsOf: path))
            _ = try activeOwnership(at: path, under: root, harness: harness == .codex ? "codex" : "claude-code", profile: probe.profile.resolvingSymlinksInPath().path, marketplace: value.marketplace, plugin: value.plugin)
            guard value.origin == Self.origin(appURL) else { continue }
            records.append(Connection(connectionID: value.connectionID, workspaceID: value.workspaceID, personaID: value.personaID, personaName: value.personaName, profile: value.profile, mcpURL: value.mcpURL, legacy: false, mcpReady: value.mcpReady, hookReady: value.hookReady))
        }
        if let (_, owner, url, _) = try legacyConnection(harness, probe: probe, appURL: appURL) {
            records.append(Connection(connectionID: legacyID(probe.profile), workspaceID: "", personaID: "", personaName: "Previous PersonaStack connection", profile: owner.profile, mcpURL: url, legacy: true, mcpReady: false, hookReady: false))
        }
        return records.sorted { $0.personaName < $1.personaName }
    }

    private struct RemovalProgress: Codable {
        var mcpRemoved = false
        var pluginRemoved = false
        var marketplaceRemoved = false
    }

    public func remove(_ connectionID: String, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws {
        if connectionID.lowercased() == legacyID(probe.profile), let (path, owner, _, _) = try legacyConnection(harness, probe: probe, appURL: appURL) {
            try removeLegacy(path, owner: owner, harness: harness, probe: probe)
            return
        }
        let (path, owner) = try ownedConnection(connectionID, harness: harness, probe: probe, appURL: appURL)
        let progressPath = path.deletingPathExtension().appendingPathExtension("remove.json")
        var progress = RemovalProgress()
        if exists(progressPath) {
            try requireOwnedFile(progressPath)
            progress = try JSONDecoder().decode(RemovalProgress.self, from: Data(contentsOf: progressPath))
        }
        func save() throws {
            if exists(progressPath) { try requireOwnedFile(progressPath) }
            try JSONEncoder().encode(progress).write(to: progressPath, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: progressPath.path)
        }
        let environment = pluginEnvironment(harness: harness, home: probe.home, profile: probe.profile, inherited: probe.environment)
        let marketplace = URL(fileURLWithPath: owner.source).appendingPathComponent("marketplace")
        let registration = try marketplaceRegistration(harness, executable: probe.executable, environment: environment, marketplace: owner.marketplace, expectedRoot: marketplace)
        guard registration != .mismatch else { throw LocalSessionError.unsafeFiles }
        var pluginInstalled = false
        if registration == .matches && !progress.pluginRemoved {
            pluginInstalled = try verifyInstalledPlugin(harness, executable: probe.executable, profile: probe.profile, marketplace: marketplace, environment: environment, ownership: owner, allowMissing: true)
        }
        if !progress.mcpRemoved {
            do {
                try verifyMCP(harness, name: Self.serverName(connectionID), url: owner.mcpURL, executable: probe.executable, environment: environment)
                try commandRunner(probe.executable, ["mcp", "logout", Self.serverName(connectionID)], environment, false)
                var remove = ["mcp", "remove", Self.serverName(connectionID)]
                if harness == .claudeCode { remove += ["--scope", "user"] }
                try commandRunner(probe.executable, remove, environment, false)
            } catch LocalSessionError.missingMCP {
                // A documented missing-entry response proves there is no MCP entry to remove.
            }
            progress.mcpRemoved = true
            try save()
        }
        if registration == .matches {
            if !progress.pluginRemoved && pluginInstalled {
                let identifier = owner.plugin + "@" + owner.marketplace
                let removePlugin = harness == .codex ? ["plugin", "remove", identifier] : ["plugin", "uninstall", identifier, "--scope", "user"]
                try commandRunner(probe.executable, removePlugin, environment, false)
            }
            progress.pluginRemoved = true
            try save()
            if !progress.marketplaceRemoved {
                try commandRunner(probe.executable, ["plugin", "marketplace", "remove", owner.marketplace], environment, false)
                progress.marketplaceRemoved = true
                try save()
            }
        }
        try manager.removeItem(at: URL(fileURLWithPath: owner.source))
        try manager.removeItem(at: path)
        if exists(progressPath) { try manager.removeItem(at: progressPath) }
    }

    public func check(_ connectionID: String, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL, reconnect: Bool) throws {
        let (_, owner) = try ownedConnection(connectionID, harness: harness, probe: probe, appURL: appURL)
        let environment = pluginEnvironment(harness: harness, home: probe.home, profile: probe.profile, inherited: probe.environment)
        let marketplace = URL(fileURLWithPath: owner.source).appendingPathComponent("marketplace")
        guard try marketplaceRegistration(harness, executable: probe.executable, environment: environment, marketplace: owner.marketplace, expectedRoot: marketplace) == .matches else { throw LocalSessionError.unsafeFiles }
        _ = try verifyInstalledPlugin(harness, executable: probe.executable, profile: probe.profile, marketplace: marketplace, environment: environment, ownership: owner, allowMissing: false)
        try verifyMCP(harness, name: Self.serverName(connectionID), url: owner.mcpURL, executable: probe.executable, environment: environment)
        if reconnect { try commandRunner(probe.executable, ["mcp", "login", Self.serverName(connectionID)], environment, false) }
    }

    public func validateRemoval(_ connectionID: String, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws {
        if connectionID.lowercased() == legacyID(probe.profile), try legacyConnection(harness, probe: probe, appURL: appURL) != nil { return }
        _ = try ownedConnection(connectionID, harness: harness, probe: probe, appURL: appURL)
    }

    public func legacyCredential(_ connectionID: String, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws -> HarnessActivityCredential? {
        guard connectionID.lowercased() == legacyID(probe.profile), let (_, _, _, token) = try legacyConnection(harness, probe: probe, appURL: appURL) else { return nil }
        return HarnessActivityCredential(connectionID: connectionID.lowercased(), activityToken: token, appURL: appURL, harness: harness, routingEnabled: false)
    }

    private func legacyID(_ profile: URL) -> String {
        let hash = profileHash(profile.resolvingSymlinksInPath().path)
        var chars = Array(hash)
        chars[12] = "5"
        chars[16] = Character(String((Int(String(chars[16]), radix: 16)! & 3) | 8, radix: 16))
        return String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
    }

    private func legacyConnection(_ harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws -> (URL, LegacyHarnessPluginOwnership, String, String)? {
        let root = connectionRoot(harness, probe: probe)
        let path = root.appendingPathComponent("active.json")
        guard exists(path) else { return nil }
        try requireOwnedFile(path)
        let owner = try JSONDecoder().decode(LegacyHarnessPluginOwnership.self, from: Data(contentsOf: path))
        let key = profileHash(probe.profile.resolvingSymlinksInPath().path)
        let source = URL(fileURLWithPath: owner.source).standardizedFileURL
        guard owner.format == 1, owner.harness == (harness == .codex ? "codex" : "claude-code"), owner.profile == probe.profile.resolvingSymlinksInPath().path,
              owner.marketplace == "personastack-desktop-" + key, owner.plugin == "personastack-local-" + key,
              source.deletingLastPathComponent() == root else { throw LocalSessionError.unsafeFiles }
        try requireOwnedDirectory(source)
        let marker = source.appendingPathComponent(".personastack-plugin-owner.json")
        try requireOwnedFile(marker)
        guard try JSONDecoder().decode(LegacyHarnessPluginOwnership.self, from: Data(contentsOf: marker)) == owner,
              try ownedSourceDigest(source) == owner.digest else { throw LocalSessionError.unsafeFiles }
        let mcpPath = source.appendingPathComponent("marketplace/plugins/" + owner.plugin + "/.mcp.json")
        try requireOwnedFile(mcpPath)
        guard let mcp = try JSONSerialization.jsonObject(with: Data(contentsOf: mcpPath)) as? [String: Any] else { throw LocalSessionError.unsafeFiles }
        let servers = harness == .codex ? mcp["mcpServers"] as? [String: Any] : mcp
        guard let server = servers?["personastack_local"] as? [String: Any], let url = server["url"] as? String,
              let headers = server["headers"] as? [String: String], let authorization = headers["Authorization"], authorization.hasPrefix("Bearer "),
              LocalSessionBundle.permitsMCP(url, appURL: appURL) else { return nil }
        let token = String(authorization.dropFirst(7))
        guard token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw LocalSessionError.unsafeFiles }
        return (path, owner, url, token)
    }

    private func removeLegacy(_ path: URL, owner: LegacyHarnessPluginOwnership, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe) throws {
        let environment = pluginEnvironment(harness: harness, home: probe.home, profile: probe.profile, inherited: probe.environment)
        let marketplace = URL(fileURLWithPath: owner.source).appendingPathComponent("marketplace")
        let registration = try marketplaceRegistration(harness, executable: probe.executable, environment: environment, marketplace: owner.marketplace, expectedRoot: marketplace)
        guard registration != .mismatch else { throw LocalSessionError.unsafeFiles }
        if registration == .matches {
            let identifier = owner.plugin + "@" + owner.marketplace
            let remove = harness == .codex ? ["plugin", "remove", identifier] : ["plugin", "uninstall", identifier, "--scope", "user"]
            // Legacy sources use the same verified owned cache layout and content digest.
            let adapted = LocalHarnessPluginOwnership(format: 1, harness: owner.harness, marketplace: owner.marketplace, plugin: owner.plugin, profile: owner.profile, source: owner.source, digest: owner.digest, connectionID: legacyID(probe.profile), origin: "", workspaceID: "", personaID: "", personaName: "", mcpURL: "", mcpReady: false, hookReady: false)
            let installed = try verifyInstalledPlugin(harness, executable: probe.executable, profile: probe.profile, marketplace: marketplace, environment: environment, ownership: adapted, allowMissing: true)
            if installed { try commandRunner(probe.executable, remove, environment, false) }
            try commandRunner(probe.executable, ["plugin", "marketplace", "remove", owner.marketplace], environment, false)
        }
        try manager.removeItem(at: URL(fileURLWithPath: owner.source))
        try manager.removeItem(at: path)
    }

    private func ownedConnection(_ connectionID: String, harness: LocalSessionHarness, probe: LocalSessionHarnessProbe, appURL: URL) throws -> (URL, LocalHarnessPluginOwnership) {
        guard UUID(uuidString: connectionID) != nil else { throw LocalSessionError.invalidRequest }
        let root = connectionRoot(harness, probe: probe)
        let key = connectionID.lowercased().replacingOccurrences(of: "-", with: "")
        let path = root.appendingPathComponent(key + ".json")
        guard let owner = try activeOwnership(at: path, under: root, harness: harness == .codex ? "codex" : "claude-code", profile: probe.profile.resolvingSymlinksInPath().path, marketplace: "personastack-desktop-" + key, plugin: "personastack-persona-" + key), owner.origin == Self.origin(appURL), owner.connectionID.lowercased() == connectionID.lowercased() else { throw LocalSessionError.unsafeFiles }
        return (path, owner)
    }

    private func configureMCP(_ bundle: LocalSessionBundle, executable: URL, environment: [String: String], previous: LocalHarnessPluginOwnership?) throws {
        let name = Self.serverName(bundle.connectionID)
        var exists = false
        if bundle.harness == .codex {
            let data = try commandOutputReader(executable, ["mcp", "list", "--json"], environment)
            guard let records = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]] else { throw LocalSessionError.unsafeFiles }
            exists = records.contains { $0["name"] as? String == name }
            if exists && previous == nil { throw LocalSessionError.unsafeFiles }
        } else if previous != nil {
            // A failed previous setup may have installed its plugin before adding MCP.
            do {
                try verifyMCP(bundle.harness, name: name, url: bundle.mcpURL, executable: executable, environment: environment)
                exists = true
            } catch LocalSessionError.missingMCP { exists = false }
        }
        if exists {
            try verifyMCP(bundle.harness, name: name, url: bundle.mcpURL, executable: executable, environment: environment)
        } else {
            let add = bundle.harness == .codex ? ["mcp", "add", name, "--url", bundle.mcpURL] : ["mcp", "add", "--transport", "http", "--scope", "user", name, bundle.mcpURL]
            try commandRunner(executable, add, environment, false)
            try verifyMCP(bundle.harness, name: name, url: bundle.mcpURL, executable: executable, environment: environment)
        }
        try commandRunner(executable, ["mcp", "login", name], environment, false)
        try verifyMCP(bundle.harness, name: name, url: bundle.mcpURL, executable: executable, environment: environment)
    }

    private func verifyMCP(_ harness: LocalSessionHarness, name: String, url: String, executable: URL, environment: [String: String]) throws {
        let args = ["mcp", "get", name] + (harness == .codex ? ["--json"] : [])
        let result = try commandOutputReader(executable, args, environment)
        if harness == .codex {
            guard let record = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any], record["name"] as? String == name,
                  let transport = record["transport"] as? [String: Any], transport["url"] as? String == url,
                  transport["type"] as? String == "streamable_http",
                  transport["bearer_token_env_var"] == nil || transport["bearer_token_env_var"] is NSNull,
                  Self.emptyHeaderSetting(transport["http_headers"]), Self.emptyHeaderSetting(transport["env_http_headers"]),
                  transport["http_headers_helper"] == nil || transport["http_headers_helper"] is NSNull || transport["http_headers_helper"] as? String == "" else { throw LocalSessionError.unsafeFiles }
        } else {
            let lines = result.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains("URL: " + url), !lines.contains(where: { $0.hasPrefix("Headers:") }) else { throw LocalSessionError.unsafeFiles }
        }
    }

    private static func emptyHeaderSetting(_ value: Any?) -> Bool {
        value == nil || value is NSNull || (value as? [String: Any])?.isEmpty == true
    }

    private func installHooks(bundle: LocalSessionBundle, plugin: URL) throws {
        guard manager.isExecutableFile(atPath: helperURL.path) else { throw LocalSessionError.missingHarness }
        let hookDirectory = try directories(["hooks"], below: plugin)
        let events = bundle.harness == .codex ? ["UserPromptSubmit", "Stop", "Interrupt", "SessionEnd"] : ["UserPromptSubmit", "Stop", "StopFailure", "SessionEnd"]
        var hooks: [String: [[String: Any]]] = [:]
        for event in events {
            let command = "exec " + LocalSessionLauncher.shellQuote(helperURL.path) + " --connection " + LocalSessionLauncher.shellQuote(bundle.connectionID) + " --event " + event
            hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 8]]]]
        }
        try write(JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys]), to: hookDirectory.appendingPathComponent("hooks.json"))
    }

    private func activeOwnership(at activeURL: URL, under root: URL, harness: String, profile: String, marketplace: String, plugin: String) throws -> LocalHarnessPluginOwnership? {
        guard exists(activeURL) else { return nil }
        try requirePrivate(activeURL, directory: false)
        let ownership = try JSONDecoder().decode(LocalHarnessPluginOwnership.self, from: Data(contentsOf: activeURL))
        let source = URL(fileURLWithPath: ownership.source).standardizedFileURL
        guard ownership.format == 2, ownership.harness == harness, ownership.marketplace == marketplace, ownership.plugin == plugin, ownership.profile == profile,
              source.deletingLastPathComponent() == root, source.lastPathComponent != "active.json" else { throw LocalSessionError.unsafeFiles }
        try requireOwnedDirectory(source)
        let marker = source.appendingPathComponent(".personastack-plugin-owner.json")
        try requireOwnedFile(marker)
        guard try JSONDecoder().decode(LocalHarnessPluginOwnership.self, from: Data(contentsOf: marker)) == ownership else { throw LocalSessionError.unsafeFiles }
        guard try ownedSourceDigest(source) == ownership.digest else { throw LocalSessionError.unsafeFiles }
        return ownership
    }

    /// The marker and digest make deletion safe only for an unmodified PersonaStack source.
    private func ownedSourceDigest(_ directory: URL) throws -> String {
        try contentDigest(directory, requirePrivateModes: true, excludeOwnershipMarker: true)
    }

    private func contentDigest(_ directory: URL, requirePrivateModes: Bool, excludeOwnershipMarker: Bool) throws -> String {
        let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
        if requirePrivateModes { try requirePrivate(directory, directory: true) }
        guard let enumerator = manager.enumerator(atPath: directory.path) else { throw LocalSessionError.unsafeFiles }
        var files: [(String, Data)] = []
        for case let relative as String in enumerator {
            if excludeOwnershipMarker && relative == ".personastack-plugin-owner.json" { continue }
            let file = directory.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
            if values.isDirectory == true {
                if requirePrivateModes { try requirePrivate(file, directory: true) }
                continue
            }
            guard values.isRegularFile == true else { throw LocalSessionError.unsafeFiles }
            if requirePrivateModes { try requirePrivate(file, directory: false) }
            files.append((relative, try Data(contentsOf: file)))
        }
        var hasher = SHA256()
        for (relative, contents) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: contents)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func saveOwnership(_ ownership: LocalHarnessPluginOwnership, at activeURL: URL) throws {
        let marker = URL(fileURLWithPath: ownership.source).appendingPathComponent(".personastack-plugin-owner.json")
        try requireOwnedFile(marker)
        try JSONEncoder().encode(ownership).write(to: marker, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try replaceActiveOwnership(ownership, at: activeURL)
    }

    private func replaceActiveOwnership(_ ownership: LocalHarnessPluginOwnership, at activeURL: URL) throws {
        if exists(activeURL) { try manager.removeItem(at: activeURL) }
        try write(JSONEncoder().encode(ownership), to: activeURL)
    }

    private func preparedSkills(bundle: LocalSessionBundle, appURL: URL, profile: URL) throws -> [(name: String, ownership: Data, files: [LocalSessionSkillFile])] {
        let origin = URLComponents(url: appURL, resolvingAgainstBaseURL: false).map { "\($0.scheme ?? "")://\($0.host ?? ""):\($0.port ?? 443)" } ?? ""
        return try bundle.skills.map { selected in
            let owner = LocalSkillOwnership(format: 1, origin: origin, workspace: bundle.workspaceID, persona: bundle.personaID,
                                           profile: profile.resolvingSymlinksInPath().path, skill: selected.skillID, digest: selected.digest)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let ownership = try encoder.encode(owner)
            let name = "ps-" + SHA256.hash(data: ownership).prefix(20).map { String(format: "%02x", $0) }.joined()
            let files = try selected.files.map { file in
                LocalSessionSkillFile(relativePath: file.relativePath, content: file.relativePath == "SKILL.md" ? try LocalSessionSkillManifest.renamed(file.content, name: name) : file.content)
            }
            guard !files.contains(where: { $0.relativePath.lowercased() == ".personastack-owner.json" }) else { throw LocalSessionError.invalidBundle }
            return (name, ownership, files)
        }
    }

    private func installPlugin(_ harness: LocalSessionHarness, executable: URL, home: URL, profile: URL, marketplace: URL,
                               harnessEnvironment: [String: String], ownership: LocalHarnessPluginOwnership,
                               previous: LocalHarnessPluginOwnership?, willMutate: () -> Void,
                               marketplaceRegistered: () -> Void) throws {
        let environment = pluginEnvironment(harness: harness, home: home, profile: profile, inherited: harnessEnvironment)
        if let previous {
            let activeMarketplace = URL(fileURLWithPath: previous.source).appendingPathComponent("marketplace")
            logger.notice("local session previous marketplace validation started")
            switch try marketplaceRegistration(harness, executable: executable, environment: environment, marketplace: previous.marketplace,
                                               expectedRoot: activeMarketplace) {
            case .mismatch: throw LocalSessionError.unsafeFiles
            case .missing: logger.notice("local session previous marketplace validation completed")
            case .matches:
                logger.notice("local session previous marketplace validation completed")
                let installed = try verifyInstalledPlugin(harness, executable: executable, profile: profile, marketplace: activeMarketplace,
                                                          environment: environment, ownership: previous, allowMissing: true)
                let identifier = previous.plugin + "@" + previous.marketplace
                let remove = harness == .codex ? ["plugin", "remove", identifier] : ["plugin", "uninstall", identifier, "--scope", "user"]
                if installed {
                    willMutate()
                    logger.notice("local session previous plugin removal started")
                    try commandRunner(executable, remove, environment, false)
                    logger.notice("local session previous plugin removal completed")
                }
                willMutate()
                logger.notice("local session previous marketplace removal started")
                try commandRunner(executable, ["plugin", "marketplace", "remove", previous.marketplace], environment, false)
                logger.notice("local session previous marketplace removal completed")
            }
        }
        willMutate()
        logger.notice("local session marketplace add started")
        try commandRunner(executable, ["plugin", "marketplace", "add", marketplace.path], environment, false)
        logger.notice("local session marketplace add completed")
        marketplaceRegistered()
        let install = harness == .codex ? ["plugin", "add", ownership.plugin, "--marketplace", ownership.marketplace] : ["plugin", "install", ownership.plugin + "@" + ownership.marketplace, "--scope", "user"]
        willMutate()
        logger.notice("local session plugin manager install started")
        try commandRunner(executable, install, environment, false)
        logger.notice("local session plugin manager install completed")
        _ = try verifyInstalledPlugin(harness, executable: executable, profile: profile, marketplace: marketplace, environment: environment,
                                      ownership: ownership, allowMissing: false)
    }

    private func verifyInstalledPlugin(_ harness: LocalSessionHarness, executable: URL, profile: URL, marketplace: URL,
                                       environment: [String: String], ownership: LocalHarnessPluginOwnership,
                                       allowMissing: Bool) throws -> Bool {
        let result = try commandOutputReader(executable, ["plugin", "list", "--available", "--json"], environment)
        let value = try JSONSerialization.jsonObject(with: Data(result.utf8))
        guard let object = value as? [String: Any], let records = object["installed"] as? [[String: Any]] else { throw LocalSessionError.unsafeFiles }
        logger.notice("local session plugin registry parsed")
        let identifier = ownership.plugin + "@" + ownership.marketplace
        let expectedSource = marketplace.appendingPathComponent("plugins/" + ownership.plugin).standardizedFileURL.path
        let record: [String: Any]
        if harness == .codex {
            guard let value = records.first(where: { $0["pluginId"] as? String == identifier }) else {
                if allowMissing { return false }
                throw LocalSessionError.unsafeFiles
            }
            guard value["enabled"] as? Bool == true,
                  let source = value["source"] as? [String: Any],
                  let sourcePath = source["path"] as? String,
                  sameDirectory(sourcePath, as: URL(fileURLWithPath: expectedSource)),
                  let marketplaceSource = value["marketplaceSource"] as? [String: Any],
                  let marketplacePath = marketplaceSource["source"] as? String,
                  sameDirectory(marketplacePath, as: marketplace.standardizedFileURL) else { throw LocalSessionError.unsafeFiles }
            record = value
        } else {
            guard let value = records.first(where: { $0["id"] as? String == identifier }) else {
                if allowMissing { return false }
                throw LocalSessionError.unsafeFiles
            }
            guard value["enabled"] as? Bool == true,
                  value["scope"] as? String == "user" else { throw LocalSessionError.unsafeFiles }
            record = value
        }
        logger.notice("local session plugin identity verified")
        let cache: URL
        if harness == .codex {
            let version: String
            if let reportedVersionValue = record["version"] {
                guard let reportedVersion = reportedVersionValue as? String else { throw LocalSessionError.unsafeFiles }
                guard !reportedVersion.isEmpty else { throw LocalSessionError.unsafeFiles }
                version = reportedVersion
            } else {
                let manifest = marketplace.appendingPathComponent("plugins/" + ownership.plugin + "/.codex-plugin/plugin.json")
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                guard let plugin = value as? [String: Any], plugin["name"] as? String == ownership.plugin,
                      let manifestVersion = plugin["version"] as? String, !manifestVersion.isEmpty else {
                    throw LocalSessionError.unsafeFiles
                }
                version = manifestVersion
            }
            cache = profile.resolvingSymlinksInPath().appendingPathComponent("plugins/cache/" + ownership.marketplace + "/" + ownership.plugin + "/" + version)
        } else {
            guard let path = record["installPath"] as? String else { throw LocalSessionError.unsafeFiles }
            cache = URL(fileURLWithPath: path)
        }
        let cacheRoot = profile.resolvingSymlinksInPath().appendingPathComponent("plugins/cache/" + ownership.marketplace + "/" + ownership.plugin).standardizedFileURL
        let rawCache = cache.standardizedFileURL
        let normalizedCache = rawCache.resolvingSymlinksInPath().standardizedFileURL
        guard rawCache.path.hasPrefix(cacheRoot.path + "/"), normalizedCache == rawCache else { throw LocalSessionError.unsafeFiles }
        logger.notice("local session plugin cache path verified")
        let source = marketplace.appendingPathComponent("plugins/" + ownership.plugin)
        logger.notice("local session plugin cache verification started")
        try hardenInstalledPlugin(at: normalizedCache, expectedDigest: try contentDigest(source, requirePrivateModes: true, excludeOwnershipMarker: false))
        logger.notice("local session plugin cache verification completed")
        return true
    }

    /// CLI caches can copy the bearer-bearing file with broad modes. Tighten only the verified managed cache.
    private func hardenInstalledPlugin(at root: URL, expectedDigest: String) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
        guard let enumerator = manager.enumerator(atPath: root.path) else { throw LocalSessionError.unsafeFiles }
        var paths = [root]
        for case let relative as String in enumerator {
            let path = root.appendingPathComponent(relative)
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw LocalSessionError.unsafeFiles }
            paths.append(path)
        }
        guard try contentDigest(root, requirePrivateModes: false, excludeOwnershipMarker: false) == expectedDigest else { throw LocalSessionError.unsafeFiles }
        for path in paths {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey])
            try manager.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: path.path)
            try requirePrivate(path, directory: values.isDirectory == true)
        }
    }

    /// Refuse to remove a profile-specific name after a user has repointed it elsewhere.
    private func marketplaceRegistration(_ harness: LocalSessionHarness, executable: URL, environment: [String: String], marketplace: String,
                                         expectedRoot: URL?) throws -> LocalMarketplaceRegistration {
        logger.notice("local session marketplace registry query started")
        let result = try commandOutputReader(executable, ["plugin", "marketplace", "list", "--json"], environment)
        let value = try JSONSerialization.jsonObject(with: Data(result.utf8))
        logger.notice("local session marketplace registry query completed")
        let records: [[String: Any]]
        if harness == .codex {
            guard let object = value as? [String: Any], let values = object["marketplaces"] as? [[String: Any]] else { return .mismatch }
            records = values
        } else {
            guard let values = value as? [[String: Any]] else { return .mismatch }
            records = values
        }
        guard let record = records.first(where: { $0["name"] as? String == marketplace }) else { return .missing }
        guard let expectedRoot else { return .mismatch }
        let path = harness == .codex ? record["root"] as? String : record["path"] as? String
        guard let path, sameDirectory(path, as: expectedRoot) else { return .mismatch }
        return .matches
    }

    /// CLIs may canonicalize a source path differently from Foundation. Accept aliases only
    /// when the reported absolute path names the exact same directory on disk.
    private func sameDirectory(_ path: String, as expected: URL) -> Bool {
        guard path.hasPrefix("/"), expected.isFileURL else { return false }
        var actual = stat()
        var target = stat()
        guard stat(path, &actual) == 0, stat(expected.path, &target) == 0 else { return false }
        return (actual.st_mode & S_IFMT) == S_IFDIR && (target.st_mode & S_IFMT) == S_IFDIR &&
            actual.st_dev == target.st_dev && actual.st_ino == target.st_ino
    }

    private func pluginEnvironment(harness: LocalSessionHarness, home: URL, profile: URL, inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["HOME"] = home.path
        environment[harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = profile.resolvingSymlinksInPath().path
        return environment
    }

    private func profileHash(_ profile: String) -> String {
        SHA256.hash(data: Data(profile.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: URL, arguments: [String], environment: [String: String], allowFailure: Bool) throws {
        _ = try processOutput(executable, arguments: arguments, environment: environment, allowFailure: allowFailure)
    }

    private static func readOutput(_ executable: URL, arguments: [String], environment: [String: String]) throws -> String {
        try processOutput(executable, arguments: arguments, environment: environment, allowFailure: false)
    }

    private static func processOutput(_ executable: URL, arguments: [String], environment: [String: String], allowFailure: Bool) throws -> String {
        let process = Process(), outputPipe = Pipe(), errorPipe = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardOutput = outputPipe; process.standardError = errorPipe; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw LocalSessionError.missingHarness }
        outputPipe.fileHandleForWriting.closeFile(); errorPipe.fileHandleForWriting.closeFile()
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor, errorFD = errorPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outputFD, F_SETFL, O_NONBLOCK); _ = fcntl(errorFD, F_SETFL, O_NONBLOCK)
        defer { outputPipe.fileHandleForReading.closeFile(); errorPipe.fileHandleForReading.closeFile() }
        let deadline = ProcessInfo.processInfo.systemUptime + (arguments.prefix(2).elementsEqual(["mcp", "login"]) ? 180 : 30)
        var output = Data(), errorOutput = Data()
        func drain(_ descriptor: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { return }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 256 * 1024 { return }
            }
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            drain(outputFD, into: &output); drain(errorFD, into: &errorOutput)
            if output.count > 256 * 1024 || errorOutput.count > 256 * 1024 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        drain(outputFD, into: &output); drain(errorFD, into: &errorOutput)
        guard output.count <= 256 * 1024, errorOutput.count <= 256 * 1024,
              let value = String(data: output, encoding: .utf8) else { throw LocalSessionError.unsafeFiles }
        if !allowFailure && process.terminationStatus != 0 {
            let diagnostic = String(data: errorOutput, encoding: .utf8) ?? ""
            if documentedMissingMCP(arguments, output: value, error: diagnostic) { throw LocalSessionError.missingMCP }
            throw LocalSessionError.unsafeFiles
        }
        return value
    }

    static func documentedMissingMCP(_ arguments: [String], output: String, error: String) -> Bool {
        guard arguments.count >= 3, arguments[0] == "mcp", arguments[1] == "get" else { return false }
        let name = arguments[2]
        let codex = "Error: No MCP server named '" + name + "' found."
        let claude = "No MCP server named \"" + name + "\"."
        return [output, error].contains { diagnostic in
            let value = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == codex || value == claude || value.hasPrefix(claude + " Configured servers:")
        }
    }

    private func exists(_ path: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: path.path)) != nil
    }

    private func requireDirectory(_ path: URL) throws {
        let attributes = try manager.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LocalSessionError.unsafeFiles }
    }

    private func directories(_ components: [String], below root: URL) throws -> URL {
        var path = root
        for component in components {
            path.appendPathComponent(component, isDirectory: true)
            if !exists(path) {
                try manager.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try requireDirectory(path)
        }
        return path
    }

    private func writeArtifact(_ file: LocalSessionSkillFile, below root: URL) throws {
        let components = file.relativePath.split(separator: "/").map(String.init)
        let parent = try directories(Array(components.dropLast()), below: root)
        try write(Data(file.content.utf8), to: parent.appendingPathComponent(components.last!))
    }

    private func write(_ data: Data, to path: URL, mode: mode_t = 0o600) throws {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw LocalSessionError.unsafeFiles }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalSessionError.unsafeFiles }
                offset += count
            }
        }
    }

    private func verifySnapshot(_ directory: URL, ownership: Data, files: [LocalSessionSkillFile]) throws {
        try requireDirectory(directory)
        try requirePrivate(directory, directory: true)
        var expected = Set(files.map(\.relativePath))
        expected.insert(".personastack-owner.json")
        guard let enumerator = manager.enumerator(atPath: directory.path) else {
            throw LocalSessionError.unsafeFiles
        }
        for case let relative as String in enumerator {
            let url = directory.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
            try requirePrivate(url, directory: values.isDirectory == true)
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, expected.remove(relative) != nil else { throw LocalSessionError.unsafeFiles }
            let desired = relative == ".personastack-owner.json" ? ownership : Data(files.first(where: { $0.relativePath == relative })!.content.utf8)
            guard try Data(contentsOf: url) == desired else { throw LocalSessionError.unsafeFiles }
        }
        guard expected.isEmpty else { throw LocalSessionError.unsafeFiles }
    }

    private func requireOwnedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
        try requirePrivate(url, directory: true)
    }

    private func requireOwnedFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
        try requirePrivate(url, directory: false)
    }

    private func requirePrivate(_ url: URL, directory: Bool) throws {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o777 == (directory ? 0o700 : 0o600) else { throw LocalSessionError.unsafeFiles }
    }
}
