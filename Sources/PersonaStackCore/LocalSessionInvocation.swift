import Foundation

/// Child process inputs. This value contains a credential and must never be logged.
public struct LocalSessionInvocation: Sendable {
    public let executable: URL
    public let workingDirectory: URL
    public let arguments: [String]
    public let environment: [String: String]

    public static func make(
        bundle: LocalSessionBundle,
        sessionID: UUID,
        executable: URL,
        home: URL,
        sessionDirectory: URL,
        inheritedEnvironment: [String: String]
    ) throws -> LocalSessionInvocation {
        guard executable.isFileURL, home.isFileURL, sessionDirectory.isFileURL,
              [executable.path, home.path, sessionDirectory.path].allSatisfy({ !$0.contains("\0") }),
              inheritedEnvironment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw LocalSessionError.invalidRequest
        }
        let server = serverName(sessionID)
        let instructions = sessionDirectory.appendingPathComponent("persona.md").path
        var environment = inheritedEnvironment
        var arguments: [String]
        switch bundle.harness {
        case .codex:
            let variable = "PERSONASTACK_LOCAL_TOKEN_" + sessionID.uuidString.replacingOccurrences(of: "-", with: "")
            environment[variable] = bundle.bearerToken
            arguments = ["--cd", home.path,
                         "-c", "mcp_servers.\(server).url=\(try quotedConfigString(bundle.mcpURL))",
                         "-c", "mcp_servers.\(server).bearer_token_env_var=\(try quotedConfigString(variable))",
                         "Read the persona instructions at \(try quotedConfigString(instructions)) and follow them for this session."]
        case .claudeCode:
            arguments = ["--plugin-dir", sessionDirectory.appendingPathComponent("plugin").path,
                         "--mcp-config", sessionDirectory.appendingPathComponent("mcp.json").path,
                         "--append-system-prompt-file", instructions]
        }
        return LocalSessionInvocation(executable: executable, workingDirectory: home,
                                      arguments: arguments, environment: environment)
    }

    public static func serverName(_ sessionID: UUID) -> String {
        "personastack_local_" + sessionID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// TOML basic strings share JSON escaping except for JSON's optional slash escape.
    private static func quotedConfigString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw LocalSessionError.invalidRequest
        }
        return result
    }
}

public enum LocalSessionLauncher {
    /// Only native-owned helper paths and IDs enter this file. Bundle text never does.
    public static func command(helper: URL, sessionID: UUID, loginShell: URL) throws -> String {
        guard helper.isFileURL, loginShell.isFileURL,
              [helper.path, loginShell.path].allSatisfy({ !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw LocalSessionError.invalidRequest
        }
        let invocation = "exec " + shellQuote(helper.path) + " " + shellQuote(sessionID.uuidString)
        let arguments = loginArguments(shell: loginShell, command: invocation)
        return "#!/bin/sh\nexec /bin/bash " + arguments.map(shellQuote).joined(separator: " ") + "\n"
    }

    /// A leading '-' argv[0] requests login initialization across macOS shells.
    /// Unlike '-l', this also works with tcsh when a command is supplied.
    static func loginArguments(shell: URL, command: String) -> [String] {
        ["-c", "exec -a \"-${1##*/}\" \"$@\"", "personastack", shell.path, "-i", "-c", command]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
