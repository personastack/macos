import CryptoKit
import Darwin
import Foundation

public struct LocalSessionInstalledFiles: Sendable {
    public let directory: URL
    public let launcher: URL
    public let skillDirectories: [URL]
    public init(directory: URL, launcher: URL, skillDirectories: [URL]) {
        self.directory = directory; self.launcher = launcher; self.skillDirectories = skillDirectories
    }
}

public struct LocalSessionLaunchContext: Codable, Sendable {
    public let appURL: URL
    public let home: URL
    public let profile: URL
    public let executable: URL
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

private struct LocalClaudeMCP: Encodable {
    struct Server: Encodable {
        let type = "http"
        let url: String
        let headers: Headers
    }
    struct Headers: Encodable { let Authorization: String }
    let mcpServers: [String: Server]
}

/// Filesystem ownership is local to the desktop. No server-supplied destination is used.
public struct LocalSessionFiles {
    private let manager: FileManager
    public init(manager: FileManager = .default) { self.manager = manager }

    public func install(bundle: LocalSessionBundle, appURL: URL, home: URL, profile: URL,
                        sessionID: UUID, executable: URL, helper: URL, loginShell: URL, now: Date = Date()) throws -> LocalSessionInstalledFiles {
        try bundle.validate(appURL: appURL, now: now)
        // Validate and adapt every selected artifact before creating any files.
        let origin = URLComponents(url: appURL, resolvingAgainstBaseURL: false).map {
            "\($0.scheme ?? "")://\($0.host ?? ""):\($0.port ?? 443)"
        } ?? ""
        let prepared = try bundle.skills.map { skill in
            let owner = LocalSkillOwnership(format: 1, origin: origin, workspace: bundle.workspaceID,
                                           persona: bundle.personaID, profile: profile.resolvingSymlinksInPath().path,
                                           skill: skill.skillID, digest: skill.digest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let ownership = try encoder.encode(owner)
            let name = "ps-" + SHA256.hash(data: ownership).prefix(20).map { String(format: "%02x", $0) }.joined()
            let files = try skill.files.map { file in
                LocalSessionSkillFile(relativePath: file.relativePath, content: file.relativePath == "SKILL.md"
                    ? try LocalSessionSkillManifest.renamed(file.content, name: name) : file.content)
            }
            guard !files.contains(where: { $0.relativePath.lowercased() == ".personastack-owner.json" }) else {
                throw LocalSessionError.invalidBundle
            }
            return (name: name, ownership: ownership, files: files)
        }
        let launcher = try LocalSessionLauncher.command(helper: helper, sessionID: sessionID, loginShell: loginShell)
        do {
            let root = home.resolvingSymlinksInPath().standardizedFileURL
            try requireDirectory(root)
            let sessions = try directories(["Library", "Application Support", "PersonaStack", "LocalSessions"], below: root)
            let directory = sessions.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            // Session IDs are single-use. Never overwrite a previous launch, even if it looks owned.
            guard !exists(directory) else { throw LocalSessionError.unsafeFiles }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var skillDirectories: [URL] = []
            let skillRoot: URL
            if bundle.harness == .codex {
                skillRoot = try directories([".agents", "skills"], below: root)
            } else {
                skillRoot = try directories(["plugin", "skills"], below: directory)
                let pluginManifest = try directories(["plugin", ".claude-plugin"], below: directory)
                struct Plugin: Encodable { let name: String; let version: String }
                try write(JSONEncoder().encode(Plugin(name: "personastack-" + sessionID.uuidString.lowercased(), version: "1.0.0")), to: pluginManifest.appendingPathComponent("plugin.json"))
            }
            for skill in prepared {
                let destination = skillRoot.appendingPathComponent(skill.name, isDirectory: true)
                if exists(destination) {
                    try verifySnapshot(destination, ownership: skill.ownership, files: skill.files)
                } else {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    for file in skill.files { try writeArtifact(file, below: destination) }
                    try write(skill.ownership, to: destination.appendingPathComponent(".personastack-owner.json"))
                }
                skillDirectories.append(destination)
            }
            let selected = zip(prepared, skillDirectories).map { "- \($0.0.name): \($0.1.path)" }.joined(separator: "\n")
            let prompt = bundle.personaPrompt + "\n\nPersonaStack MCP server: " + LocalSessionInvocation.serverName(sessionID)
                + "\nSelected local skills:\n" + selected + "\n"
            try write(Data(prompt.utf8), to: directory.appendingPathComponent("persona.md"))
            // The helper reads the same validated producer bundle, rather than a second command protocol.
            try write(JSONEncoder().encode(bundle), to: directory.appendingPathComponent("bundle.json"))
            try write(JSONEncoder().encode(LocalSessionLaunchContext(appURL: appURL, home: home, profile: profile.resolvingSymlinksInPath(), executable: executable)), to: directory.appendingPathComponent("context.json"))
            if bundle.harness == .claudeCode {
                let config = LocalClaudeMCP(mcpServers: [LocalSessionInvocation.serverName(sessionID): .init(url: bundle.mcpURL, headers: .init(Authorization: "Bearer " + bundle.bearerToken))])
                try write(JSONEncoder().encode(config), to: directory.appendingPathComponent("mcp.json"))
            }
            let command = directory.appendingPathComponent("launch.command")
            try write(Data(launcher.utf8), to: command, mode: 0o700)
            return LocalSessionInstalledFiles(directory: directory, launcher: command, skillDirectories: skillDirectories)
        } catch { throw LocalSessionError.unsafeFiles }
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

    private func requirePrivate(_ url: URL, directory: Bool) throws {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o777 == (directory ? 0o700 : 0o600) else { throw LocalSessionError.unsafeFiles }
    }
}
