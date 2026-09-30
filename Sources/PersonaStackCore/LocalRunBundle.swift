import CryptoKit
import Foundation

public struct LocalRunEnvironment: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
}

public struct LocalRunFile: Codable, Sendable, Equatable {
    public var path: String
    public var content: String
    public var digest: String
    public var mode: Int
}

public struct LocalRunCompanion: Codable, Sendable {
    public var kind: String
    public var image: String
    public var command: [String]
    public var environment: [LocalRunEnvironment]
}

public struct LocalRunBundle: Decodable, Sendable {
    public var version: Int
    public var protocol_version: Int
    public var session_id: String
    public var persona_id: String
    public var persona_name: String
    public var workspace_id: String
    public var stack_id: String?
    public var worker_image: String
    public var provider: String
    public var model: String
    public var issued_at: String
    public var expires_at: String
    public var mcp_url: String
    public var bearer_token: String
    public var persona_prompt: String
    public var skills: [LocalSessionSkill]
    public var environment: [LocalRunEnvironment]
    public var files: [LocalRunFile]
    public var command: [String]
    public var companions: [LocalRunCompanion]?

    public static func decode(_ data: Data, sessionID: String, personaID: String, mcpURL: URL, now: Date = Date()) throws -> Self {
        guard data.count <= 12 * 1024 * 1024 else { throw LocalRunError.invalidBundle }
        do {
            let bundle = try JSONDecoder().decode(Self.self, from: data)
            try bundle.validate(sessionID: sessionID, personaID: personaID, mcpURL: mcpURL, now: now)
            return bundle
        } catch { throw LocalRunError.invalidBundle }
    }

    public func validate(sessionID: String, personaID: String, mcpURL: URL, now: Date = Date()) throws {
        guard version == 1, protocol_version == 1, session_id == sessionID, persona_id == personaID,
              UUID(uuidString: session_id) != nil, ChatWindowCommand.validPersonaID(persona_id),
              !workspace_id.isEmpty, persona_name.utf8.count <= 1024,
              URL(string: mcp_url) == mcpURL, bearer_token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              Self.validImage(worker_image), !command.isEmpty, command.count <= 128,
              command.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 }),
              let issued = Self.date(issued_at), let expires = Self.date(expires_at),
              issued <= now.addingTimeInterval(300), expires > now, expires > issued,
              skills.count <= 32, files.count <= 512, environment.count <= 256,
              (companions ?? []).count <= 1 else { throw LocalRunError.invalidBundle }
        try validateEnvironment(environment)
        var paths = Set<String>()
        var bytes = 0
        for file in files {
            guard file.path.hasPrefix("/"), LocalSessionSkill.safePath(String(file.path.dropFirst())),
                  !file.path.hasPrefix("/host/"), file.path != "/host",
                  !file.path.hasPrefix("/workspace/"), file.path != "/workspace",
                  !file.path.hasPrefix(LocalRunContainer.guestArtifacts + "/"), file.path != LocalRunContainer.guestArtifacts,
                  paths.insert(file.path.lowercased()).inserted,
                  [0o400, 0o600, 0o644, 0o700, 0o755].contains(file.mode),
                  Self.digest(file.content) == file.digest else { throw LocalRunError.invalidBundle }
            bytes += file.content.utf8.count
        }
        guard bytes <= 8 * 1024 * 1024 else { throw LocalRunError.invalidBundle }
        for skill in skills { try skill.validate() }
        for companion in companions ?? [] {
            guard companion.kind == "buildkit", Self.validImage(companion.image), !companion.command.isEmpty, companion.command.count <= 32,
                  companion.command.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 65536 }),
                  companion.environment.count <= 64 else { throw LocalRunError.invalidBundle }
            try validateEnvironment(companion.environment)
        }
    }

    private func validateEnvironment(_ values: [LocalRunEnvironment]) throws {
        var names = Set<String>()
        for value in values {
            guard value.name.range(of: "^[A-Z_][A-Z_0-9]*$", options: .regularExpression) != nil,
                  names.insert(value.name).inserted, !value.value.contains("\n"), !value.value.contains("\r"),
                  !value.value.contains("\0"), value.value.utf8.count <= 65536 else { throw LocalRunError.invalidBundle }
        }
    }

    public static func validImage(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9./:_-]+(@sha256:[a-f0-9]{64}|:([a-f0-9]{12}|v?[0-9]+\\.[0-9]+\\.[0-9]+(-[A-Za-z0-9.-]+)?))$", options: .regularExpression) != nil
    }
    public static func digest(_ value: String) -> String {
        "sha256:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
