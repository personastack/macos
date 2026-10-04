import CryptoKit
import Darwin
import Foundation

public enum DesktopSkillTransferError: String, Error, LocalizedError, Sendable {
    case collectionFolderRequired = "Choose a folder containing skills to download a copy or a skill with a different name."
    public var errorDescription: String? { rawValue }
}

public struct DesktopSkillBaseline: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let skillID: String
    public let configID: String
    public let revision: Int
    public let configVersion: Int
    public let digest: String
    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", skillID = "skill_id", configID = "config_id", revision, configVersion = "config_version", digest
    }
    public init(workspaceID: String, skillID: String, configID: String, revision: Int, configVersion: Int, digest: String) {
        self.workspaceID = workspaceID; self.skillID = skillID; self.configID = configID; self.revision = revision
        self.configVersion = configVersion; self.digest = digest
    }
}

public struct DesktopLocalSkill: Sendable {
    public let directory: URL
    public let name: String
    public let files: [LocalSessionSkillFile]
    public let digest: String
    public let baseline: DesktopSkillBaseline?
}

/// The caller supplies only a directory chosen by a native file picker, never a web path.
public struct DesktopSkillFiles: Sendable {
    private let metadataRoot: URL
    public init(metadataRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PersonaStack/SkillSync")) {
        self.metadataRoot = metadataRoot
    }

    public struct ListingIssue: Sendable {
        public let name: String
        public let message: String
    }
    public struct Listing: Sendable {
        public let skills: [DesktopLocalSkill]
        public let errors: [ListingIssue]
    }

    public func list(_ root: URL, origin: URL) throws -> [DesktopLocalSkill] {
        let listing = try previewList(root, origin: origin)
        guard listing.errors.isEmpty else { throw LocalSessionError.unsafeFiles }
        return listing.skills
    }

    public func previewList(_ inputRoot: URL, origin: URL) throws -> Listing {
        try directory(inputRoot)
        let root = try Self.canonicalDirectory(inputRoot)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return listing([root], origin: origin)
        }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard children.count <= 1024 else { throw LocalSessionError.unsafeFiles }
        var candidates: [URL] = []
        var errors: [ListingIssue] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                errors.append(.init(name: child.lastPathComponent, message: "Symbolic links cannot be transferred. Choose the original skill folder."))
            } else if values.isDirectory == true && FileManager.default.fileExists(atPath: child.appendingPathComponent("SKILL.md").path) {
                candidates.append(child)
            }
        }
        guard candidates.count <= 128 else { throw LocalSessionError.unsafeFiles }
        let result = listing(candidates, origin: origin)
        return Listing(skills: result.skills, errors: errors + result.errors)
    }

    private func listing(_ candidates: [URL], origin: URL) -> Listing {
        var skills: [DesktopLocalSkill] = []
        var errors: [ListingIssue] = []
        for child in candidates {
            do { skills.append(try read(child, origin: origin)) }
            catch { errors.append(.init(name: child.lastPathComponent, message: "This skill contains unsupported files, unsafe paths, or exceeds the transfer limits.")) }
        }
        return Listing(skills: skills, errors: errors)
    }

    public func read(_ inputRoot: URL, origin: URL) throws -> DesktopLocalSkill {
        try directory(inputRoot)
        let root = try Self.canonicalDirectory(inputRoot)
        try directory(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { throw LocalSessionError.unsafeFiles }
        var files: [LocalSessionSkillFile] = []
        var bytes = 0
        var entries = 0
        for case let file as URL in enumerator {
            entries += 1
            guard entries <= 1024 else { throw LocalSessionError.unsafeFiles }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size <= 512 * 1024 else { throw LocalSessionError.unsafeFiles }
            bytes += size
            guard bytes <= 512 * 1024, files.count < 128 else { throw LocalSessionError.unsafeFiles }
            let data = try Data(contentsOf: file)
            guard data.count == size, let content = String(data: data, encoding: .utf8) else { throw LocalSessionError.unsafeFiles }
            let path = String(file.path.dropFirst(root.path.count + 1))
            files.append(.init(relativePath: path, content: content))
        }
        let digest = LocalSessionSkill.digest(files)
        try validate(files, digest: digest)
        return DesktopLocalSkill(directory: root, name: root.lastPathComponent, files: files.sorted(by: { $0.relativePath < $1.relativePath }), digest: digest, baseline: try baseline(root, origin: origin))
    }

    public func write(root inputRoot: URL, name: String, files: [LocalSessionSkillFile], expectedDigest: String, overwrite: Bool, origin: URL) throws -> DesktopLocalSkill {
        guard Self.safeName(name) else { throw LocalSessionError.invalidRequest }
        try directory(inputRoot)
        let root = try Self.canonicalDirectory(inputRoot)
        try directory(root)
        let digest = LocalSessionSkill.digest(files)
        try validate(files, digest: digest)
        let selectedSkill = FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path)
        guard !selectedSkill || name == root.lastPathComponent else { throw DesktopSkillTransferError.collectionFolderRequired }
        let destination = selectedSkill ? root : root.appendingPathComponent(name, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists {
            let current = try read(destination, origin: origin)
            guard current.digest == expectedDigest else { throw LocalSessionError.staleRequest }
            guard overwrite || current.digest == digest else { throw LocalSessionError.unsafeFiles }
            var merged = Dictionary(uniqueKeysWithValues: current.files.map { ($0.relativePath, $0) })
            for file in files { merged[file.relativePath] = file }
            let planned = Array(merged.values)
            try validate(planned, digest: LocalSessionSkill.digest(planned))
        } else {
            guard expectedDigest.isEmpty else { throw LocalSessionError.staleRequest }
        }
        // Inspect every destination before writing any content. Unrelated files are retained.
        for file in files { try inspectDestination(file.relativePath, root: destination) }
        if !exists { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        for file in files {
            let components = file.relativePath.split(separator: "/").map(String.init)
            var parent = destination
            for component in components.dropLast() {
                parent.appendPathComponent(component, isDirectory: true)
                if !FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                try directory(parent)
            }
            try inspectDestination(file.relativePath, root: destination)
            try Data(file.content.utf8).write(to: parent.appendingPathComponent(components.last!), options: .atomic)
        }
        return try read(destination, origin: origin)
    }

    public func saveBaseline(_ value: DesktopSkillBaseline, directory skillDirectory: URL, origin: URL) throws {
        guard value.workspaceID.range(of: "^ws_[0-9a-f]{32}$", options: .regularExpression) != nil,
              !value.skillID.isEmpty, value.skillID.utf8.count <= 512,
              !value.configID.isEmpty, value.configID.utf8.count <= 512, value.revision > 0, value.configVersion > 0,
              try read(skillDirectory, origin: origin).digest == value.digest else { throw LocalSessionError.staleRequest }
        try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try self.directory(metadataRoot)
        try JSONEncoder().encode(value).write(to: metadataURL(skillDirectory, origin: origin), options: .atomic)
    }

    private func baseline(_ directory: URL, origin: URL) throws -> DesktopSkillBaseline? {
        let path = metadataURL(directory, origin: origin)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 8192 else { throw LocalSessionError.unsafeFiles }
        return try JSONDecoder().decode(DesktopSkillBaseline.self, from: Data(contentsOf: path))
    }

    private func metadataURL(_ directory: URL, origin: URL) -> URL {
        let originKey = "\(origin.scheme ?? "")://\(origin.host ?? ""):\(origin.port ?? (origin.scheme == "http" ? 80 : 443))"
        let key = SHA256.hash(data: Data((originKey + "\n" + directory.standardizedFileURL.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return metadataRoot.appendingPathComponent(key + ".json")
    }

    private func validate(_ files: [LocalSessionSkillFile], digest: String) throws {
        try LocalSessionSkill(skillID: "transfer", slug: "transfer", digest: digest, files: files).validate()
    }

    private func inspectDestination(_ path: String, root: URL) throws {
        var target = root
        let components = path.split(separator: "/").map(String.init)
        if FileManager.default.fileExists(atPath: root.path) { try directory(root) }
        for (index, component) in components.enumerated() {
            target.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) {
                let required: FileAttributeType = index == components.count - 1 ? .typeRegular : .typeDirectory
                guard attributes[.type] as? FileAttributeType == required else { throw LocalSessionError.unsafeFiles }
            }
        }
    }

    private func directory(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
        var ancestor = path.deletingLastPathComponent()
        while ancestor.path != "/" {
            let values = try ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // macOS /var and /tmp are system aliases. All user-selected paths are canonicalized.
            if values.isSymbolicLink == true && ["/var", "/tmp"].contains(ancestor.path) {
                guard let resolved = realpath(ancestor.path, nil) else { throw LocalSessionError.unsafeFiles }
                defer { free(resolved) }
                guard String(cString: resolved) == "/private" + ancestor.path else { throw LocalSessionError.unsafeFiles }
            } else {
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalSessionError.unsafeFiles }
            }
            ancestor.deleteLastPathComponent()
        }
    }

    public static func canonicalDirectory(_ path: URL) throws -> URL {
        guard path.isFileURL, let resolved = realpath(path.path, nil) else { throw LocalSessionError.unsafeFiles }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    public static func safeName(_ name: String) -> Bool {
        LocalSessionSkill.safePath(name) && !name.contains("/") && !name.hasPrefix(".")
    }
}
