import CryptoKit
import Darwin
import Foundation

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

private struct LocalMCPServer: Encodable {
    struct Headers: Encodable { let Authorization: String }
    let type = "http"
    let url: String
    let headers: Headers
}

private struct LocalCodexMCP: Encodable {
    let mcpServers: [String: LocalMCPServer]
}

/// Claude plugin manifests use a direct server map rather than Codex's mcpServers wrapper.
private struct LocalClaudePluginMCP: Encodable {
    let personastack_local: LocalMCPServer
}

private struct LocalHarnessPluginOwnership: Codable, Equatable {
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

    private let manager: FileManager
    private let commandRunner: CommandRunner
    private let commandOutputReader: CommandOutputReader
    public init(manager: FileManager = .default) {
        self.manager = manager
        self.commandRunner = Self.run
        self.commandOutputReader = Self.readOutput
    }
    init(manager: FileManager, commandRunner: @escaping CommandRunner) {
        self.manager = manager; self.commandRunner = commandRunner; self.commandOutputReader = Self.readOutput
    }
    init(manager: FileManager, commandRunner: @escaping CommandRunner,
         commandOutputReader: @escaping CommandOutputReader) {
        self.manager = manager; self.commandRunner = commandRunner; self.commandOutputReader = commandOutputReader
    }

    /// Read-only preflight runs before the hosted request can issue a credential.
    public func preflight(_ harnessValue: LocalSessionHarness, probe: LocalSessionHarnessProbe) throws {
        let root = probe.home.resolvingSymlinksInPath().standardizedFileURL
        let profile = probe.profile.resolvingSymlinksInPath().standardizedFileURL
        try requireDirectory(root)
        try requireDirectory(profile)
        let harness = harnessValue == .codex ? "codex" : "claude-code"
        let profileKey = profileHash(profile.path)
        let marketplace = "personastack-desktop-" + profileKey
        let plugin = "personastack-local-" + profileKey
        let pluginRoot = root.appendingPathComponent("Library/Application Support/PersonaStack/LocalHarnessPlugins/" + harness + "/" + profileKey)
        let activeURL = pluginRoot.appendingPathComponent("active.json")
        let active = try activeOwnership(at: activeURL, under: pluginRoot, harness: harness, profile: profile.path, marketplace: marketplace, plugin: plugin)
        let registration = try marketplaceRegistration(harnessValue, executable: probe.executable, environment: probe.environment, marketplace: marketplace,
                                                       expectedRoot: active.map { URL(fileURLWithPath: $0.source).appendingPathComponent("marketplace") })
        if active == nil {
            guard registration == .missing else { throw LocalSessionError.unsafeFiles }
        } else if registration == .mismatch {
            throw LocalSessionError.unsafeFiles
        }
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
        let marketplaceName = "personastack-desktop-" + profileKey
        let pluginName = "personastack-local-" + profileKey
        let plugins = try directories(["Library", "Application Support", "PersonaStack", "LocalHarnessPlugins", harness, profileKey], below: root)
        let activeURL = plugins.appendingPathComponent("active.json")
        let previous = try activeOwnership(at: activeURL, under: plugins, harness: harness, profile: profilePath, marketplace: marketplaceName, plugin: pluginName)
        if previous == nil {
            let environment = pluginEnvironment(harness: bundle.harness, home: root, profile: profile, inherited: harnessEnvironment)
            switch try marketplaceRegistration(bundle.harness, executable: executable, environment: environment, marketplace: marketplaceName, expectedRoot: nil) {
            case .missing: break
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
            let server = LocalMCPServer(url: bundle.mcpURL, headers: .init(Authorization: "Bearer " + bundle.bearerToken))
            if bundle.harness == .codex {
                try write(JSONEncoder().encode(LocalCodexMCP(mcpServers: ["personastack_local": server])), to: plugin.appendingPathComponent(".mcp.json"))
            } else {
                try write(JSONEncoder().encode(LocalClaudePluginMCP(personastack_local: server)), to: plugin.appendingPathComponent(".mcp.json"))
            }
            let skillRoot = try directories(["skills", "personastack"], below: plugin)
            let skill = "---\nname: personastack\ndescription: Active PersonaStack persona context. Consult this skill before work involving the configured persona and use the PersonaStack MCP server for current persona state.\n---\n\n" + bundle.personaPrompt + "\n"
            try write(Data(skill.utf8), to: skillRoot.appendingPathComponent("SKILL.md"))
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
            let ownership = LocalHarnessPluginOwnership(format: 1, harness: harness, marketplace: marketplaceName, plugin: pluginName,
                                                        profile: profilePath, source: directory.path, digest: try ownedSourceDigest(directory))
            stagedOwnership = ownership
            try write(JSONEncoder().encode(ownership), to: directory.appendingPathComponent(".personastack-plugin-owner.json"))
            try installPlugin(bundle.harness, executable: executable, home: root, profile: profile, marketplace: marketplace,
                              harnessEnvironment: harnessEnvironment, ownership: ownership, previous: previous,
                              willMutate: { pluginManagerMutated = true },
                              marketplaceRegistered: { marketplaceRegistered = true })
            try replaceActiveOwnership(ownership, at: activeURL)
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

    private func activeOwnership(at activeURL: URL, under root: URL, harness: String, profile: String, marketplace: String, plugin: String) throws -> LocalHarnessPluginOwnership? {
        guard exists(activeURL) else { return nil }
        try requirePrivate(activeURL, directory: false)
        let ownership = try JSONDecoder().decode(LocalHarnessPluginOwnership.self, from: Data(contentsOf: activeURL))
        let source = URL(fileURLWithPath: ownership.source).standardizedFileURL
        guard ownership.format == 1, ownership.harness == harness, ownership.marketplace == marketplace, ownership.plugin == plugin, ownership.profile == profile,
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
            switch try marketplaceRegistration(harness, executable: executable, environment: environment, marketplace: previous.marketplace,
                                               expectedRoot: activeMarketplace) {
            case .mismatch: throw LocalSessionError.unsafeFiles
            case .missing: break
            case .matches:
                let installed = try verifyInstalledPlugin(harness, executable: executable, profile: profile, marketplace: activeMarketplace,
                                                          environment: environment, ownership: previous, allowMissing: true, hardenCache: false)
                let identifier = previous.plugin + "@" + previous.marketplace
                let remove = harness == .codex ? ["plugin", "remove", identifier] : ["plugin", "uninstall", identifier, "--scope", "user"]
                if installed {
                    willMutate()
                    try commandRunner(executable, remove, environment, true)
                }
                willMutate()
                try commandRunner(executable, ["plugin", "marketplace", "remove", previous.marketplace], environment, true)
            }
        }
        willMutate()
        try commandRunner(executable, ["plugin", "marketplace", "add", marketplace.path], environment, false)
        marketplaceRegistered()
        let install = harness == .codex ? ["plugin", "add", ownership.plugin, "--marketplace", ownership.marketplace] : ["plugin", "install", ownership.plugin + "@" + ownership.marketplace, "--scope", "user"]
        willMutate()
        try commandRunner(executable, install, environment, false)
        _ = try verifyInstalledPlugin(harness, executable: executable, profile: profile, marketplace: marketplace, environment: environment,
                                      ownership: ownership, allowMissing: false, hardenCache: true)
    }

    private func verifyInstalledPlugin(_ harness: LocalSessionHarness, executable: URL, profile: URL, marketplace: URL,
                                       environment: [String: String], ownership: LocalHarnessPluginOwnership,
                                       allowMissing: Bool, hardenCache: Bool) throws -> Bool {
        let result = try commandOutputReader(executable, ["plugin", "list", "--available", "--json"], environment)
        let value = try JSONSerialization.jsonObject(with: Data(result.utf8))
        guard let object = value as? [String: Any], let records = object["installed"] as? [[String: Any]] else { throw LocalSessionError.unsafeFiles }
        let identifier = ownership.plugin + "@" + ownership.marketplace
        let expectedSource = marketplace.appendingPathComponent("plugins/" + ownership.plugin).standardizedFileURL.path
        let record: [String: Any]
        if harness == .codex {
            guard let value = records.first(where: { $0["pluginId"] as? String == identifier }) else {
                if allowMissing { return false }
                throw LocalSessionError.unsafeFiles
            }
            guard value["enabled"] as? Bool == true,
                  let source = value["source"] as? [String: Any], source["path"] as? String == expectedSource,
                  let marketplaceSource = value["marketplaceSource"] as? [String: Any],
                  marketplaceSource["source"] as? String == marketplace.standardizedFileURL.path else { throw LocalSessionError.unsafeFiles }
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
        let cache: URL
        if harness == .codex {
            guard let version = record["version"] as? String, !version.isEmpty else { throw LocalSessionError.unsafeFiles }
            cache = profile.resolvingSymlinksInPath().appendingPathComponent("plugins/cache/" + ownership.marketplace + "/" + ownership.plugin + "/" + version)
        } else {
            guard let path = record["installPath"] as? String else { throw LocalSessionError.unsafeFiles }
            cache = URL(fileURLWithPath: path)
        }
        let cacheRoot = profile.resolvingSymlinksInPath().appendingPathComponent("plugins/cache/" + ownership.marketplace + "/" + ownership.plugin).standardizedFileURL
        let rawCache = cache.standardizedFileURL
        let normalizedCache = rawCache.resolvingSymlinksInPath().standardizedFileURL
        guard rawCache.path.hasPrefix(cacheRoot.path + "/"), normalizedCache == rawCache else { throw LocalSessionError.unsafeFiles }
        let source = marketplace.appendingPathComponent("plugins/" + ownership.plugin)
        try hardenInstalledPlugin(at: normalizedCache, expectedDigest: try contentDigest(source, requirePrivateModes: true, excludeOwnershipMarker: false), harden: hardenCache)
        return true
    }

    /// CLI caches can copy the bearer-bearing file with broad modes. Tighten only the verified managed cache.
    private func hardenInstalledPlugin(at root: URL, expectedDigest: String, harden: Bool) throws {
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
            if harden { try manager.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: path.path) }
            try requirePrivate(path, directory: values.isDirectory == true)
        }
    }

    /// Refuse to remove a profile-specific name after a user has repointed it elsewhere.
    private func marketplaceRegistration(_ harness: LocalSessionHarness, executable: URL, environment: [String: String], marketplace: String,
                                         expectedRoot: URL?) throws -> LocalMarketplaceRegistration {
        let result = try commandOutputReader(executable, ["plugin", "marketplace", "list", "--json"], environment)
        let value = try JSONSerialization.jsonObject(with: Data(result.utf8))
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
        guard URL(fileURLWithPath: path ?? "").standardizedFileURL.path == expectedRoot.standardizedFileURL.path else { return .mismatch }
        return .matches
    }

    private func pluginEnvironment(harness: LocalSessionHarness, home: URL, profile: URL, inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["HOME"] = home.path
        environment[harness == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = profile.path
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
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw LocalSessionError.missingHarness }
        pipe.fileHandleForWriting.closeFile()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var output = Data()
        let reader = pipe.fileHandleForReading
        defer { reader.closeFile() }
        let descriptor = reader.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if output.count > 256 * 1024 { kill(process.processIdentifier, SIGKILL); break }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.02) }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
            if output.count > 256 * 1024 { throw LocalSessionError.unsafeFiles }
        }
        process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else { throw LocalSessionError.unsafeFiles }
        guard let value = String(data: output, encoding: .utf8) else { throw LocalSessionError.unsafeFiles }
        return value
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
