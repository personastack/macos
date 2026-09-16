import CryptoKit
import Foundation

public enum LocalSessionHarness: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude_code"

    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

/// Errors are deliberately finite. Never include bundle content or credentials.
public enum LocalSessionError: String, Error, LocalizedError, Sendable {
    case invalidBundle = "The local session bundle is invalid. Try again."
    case invalidRequest = "The local session request is invalid."
    case staleRequest = "The page changed. Start the local session again."
    case unsafeFiles = "PersonaStack cannot safely install the local session files."
    case missingHarness = "Install the selected CLI, then try again."
    case outdatedHarness = "Update the selected CLI, then try again."
    case terminalUnavailable = "The session could not open in Terminal. Try again."
    public var errorDescription: String? { rawValue }
}

public struct LocalSessionSkillFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let content: String
    enum CodingKeys: String, CodingKey { case relativePath = "relative_path", content }
}

public struct LocalSessionSkill: Codable, Equatable, Sendable {
    public let skillID: String
    public let slug: String
    public let digest: String
    public let files: [LocalSessionSkillFile]
    enum CodingKeys: String, CodingKey { case skillID = "skill_id", slug, digest, files }
}

public struct LocalSessionBundle: Codable, Sendable {
    public static let maxWireBytes = 12 * 1024 * 1024
    public static let lifetime: TimeInterval = 365 * 24 * 60 * 60
    public let personaID: String
    public let personaName: String
    public let workspaceID: String
    public let harness: LocalSessionHarness
    public let issuedAt: String
    public let expiresAt: String
    public let mcpURL: String
    public let bearerToken: String
    public let personaPrompt: String
    public let skills: [LocalSessionSkill]
    enum CodingKeys: String, CodingKey, CaseIterable {
        case personaID = "persona_id", personaName = "persona_name", workspaceID = "workspace_id"
        case harness, issuedAt = "issued_at", expiresAt = "expires_at", mcpURL = "mcp_url"
        case bearerToken = "bearer_token", personaPrompt = "persona_prompt", skills
    }

    public static func decode(_ data: Data, appURL: URL, now: Date = Date()) throws -> LocalSessionBundle {
        do {
            guard data.count <= maxWireBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
                  let skills = object["skills"] as? [[String: Any]], skills.count <= 32 else { throw LocalSessionError.invalidBundle }
            for skill in skills {
                guard Set(skill.keys) == ["skill_id", "slug", "digest", "files"],
                      let files = skill["files"] as? [[String: Any]], files.count <= 128 else { throw LocalSessionError.invalidBundle }
                for file in files {
                    guard Set(file.keys) == ["relative_path", "content"] else { throw LocalSessionError.invalidBundle }
                }
            }
            let bundle = try JSONDecoder().decode(Self.self, from: data)
            try bundle.validate(appURL: appURL, now: now)
            return bundle
        } catch { throw LocalSessionError.invalidBundle }
    }

    public func validate(appURL: URL, now: Date = Date()) throws {
        guard ChatWindowCommand.validPersonaID(personaID),
              workspaceID.range(of: "^ws_[0-9a-f]{32}$", options: .regularExpression) != nil,
              personaName.utf8.count <= 1024, !personaName.contains("\0"),
              personaPrompt.utf8.count <= 128 * 1024, !personaPrompt.contains("\0"),
              bearerToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let issued = Self.date(issuedAt), let expires = Self.date(expiresAt),
              abs(expires.timeIntervalSince(issued) - Self.lifetime) < 0.001,
              issued.timeIntervalSince(now) <= 300, expires > now,
              Self.permitsMCP(mcpURL, appURL: appURL), skills.count <= 32 else { throw LocalSessionError.invalidBundle }
        var identities = Set<String>()
        var bytes = 0
        var count = 0
        for skill in skills {
            guard !skill.skillID.isEmpty, skill.skillID.utf8.count <= 512, !skill.skillID.contains("\0"),
                  !skill.slug.isEmpty, skill.slug.utf8.count <= 255, !skill.slug.contains("\0"),
                  identities.insert(skill.skillID).inserted else { throw LocalSessionError.invalidBundle }
            try skill.validate()
            count += skill.files.count
            bytes += skill.files.reduce(0) { $0 + $1.content.utf8.count }
            guard count <= 128, bytes <= 512 * 1024 else { throw LocalSessionError.invalidBundle }
        }
    }

    public static func permitsMCP(_ endpoint: String, appURL: URL) -> Bool {
        guard appURL.user == nil, appURL.password == nil else { return false }
        if ChatWindowCommand.sameOrigin(appURL, URL(string: "https://my.personastack.ai")!) {
            return endpoint == "https://mcp.personastack.ai/v1/mcp"
        }
        if ChatWindowCommand.sameOrigin(appURL, URL(string: "https://personastack.ericgreer.info")!) {
            return endpoint == "http://mcp.personastack.lan/v1/mcp"
        }
        return false
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

extension LocalSessionSkill {
    public func validate() throws {
        guard !files.isEmpty, files.count <= 128,
              files.contains(where: { $0.relativePath == "SKILL.md" && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw LocalSessionError.invalidBundle }
        var seen = Set<String>()
        var bytes = 0
        for file in files {
            let key = file.relativePath.precomposedStringWithCanonicalMapping.lowercased()
            guard Self.safePath(file.relativePath), !file.content.contains("\0"), seen.insert(key).inserted else { throw LocalSessionError.invalidBundle }
            bytes += file.content.utf8.count
            guard bytes <= 512 * 1024 else { throw LocalSessionError.invalidBundle }
        }
        // A file cannot also be an ancestor directory, including on case-insensitive volumes.
        for key in seen {
            var components = key.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty {
                guard !seen.contains(components.joined(separator: "/")) else { throw LocalSessionError.invalidBundle }
                components.removeLast()
            }
        }
        guard Self.digest(files) == digest else { throw LocalSessionError.invalidBundle }
    }

    public static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }
    }

    public static func digest(_ files: [LocalSessionSkillFile]) -> String {
        var hash = SHA256()
        for file in files.sorted(by: { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }) {
            hash.update(data: Data(file.relativePath.utf8)); hash.update(data: Data([0]))
            hash.update(data: Data(file.content.utf8)); hash.update(data: Data([0]))
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
