import Darwin
import Foundation

public struct LocalSessionHarnessProbe: Sendable {
    public let executable: URL
    public let home: URL
    public let profile: URL
    public let shell: URL
    public let environment: [String: String]

    public init(executable: URL, home: URL, profile: URL, shell: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable; self.home = home; self.profile = profile; self.shell = shell; self.environment = environment
    }
}

public enum LocalSessionProbe {
    public static func loginShell() throws -> URL {
        guard let record = getpwuid(getuid()), let value = record.pointee.pw_shell else { throw LocalSessionError.missingHarness }
        let path = String(cString: value)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw LocalSessionError.missingHarness }
        return URL(fileURLWithPath: path)
    }

    /// Probe only finite commands and the non-secret profile fields needed for local files.
    public static func inspect(_ harness: LocalSessionHarness, shell: URL? = nil,
                               environment inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> LocalSessionHarnessProbe {
        let selectedShell = try shell ?? loginShell()
        let binary = harness == .codex ? "codex" : "claude"
        let marker = "PERSONASTACK_PROBE_" + UUID().uuidString
        let script = "printf '\\n\(marker)\\0'; command -v \(binary); printf '\\0%s\\0%s\\0%s\\0%s\\0' \"$HOME\" \"${CODEX_HOME:-$HOME/.codex}\" \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\" \"$PATH\""
        let command = "exec /bin/sh -c " + LocalSessionLauncher.shellQuote(script)
        let output = try run(executable: URL(fileURLWithPath: "/bin/bash"),
                             arguments: LocalSessionLauncher.loginArguments(shell: selectedShell, command: command), environment: inheritedEnvironment)
        let fields = try parseEnvironment(output, marker: marker)
        let executable = URL(fileURLWithPath: fields[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalSessionError.missingHarness }
        var environment = inheritedEnvironment
        environment["HOME"] = fields[1]; environment["CODEX_HOME"] = fields[2]
        environment["CLAUDE_CONFIG_DIR"] = fields[3]; environment["PATH"] = fields[4]
        try checkExecutable(harness, executable: executable, environment: environment)
        return LocalSessionHarnessProbe(executable: executable, home: URL(fileURLWithPath: fields[1]),
                                       profile: URL(fileURLWithPath: harness == .codex ? fields[2] : fields[3]), shell: selectedShell, environment: environment)
    }

    public static func checkExecutable(_ harness: LocalSessionHarness, executable: URL, environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw LocalSessionError.missingHarness }
        let version = try run(executable: executable, arguments: ["--version"], environment: environment)
        let help = try run(executable: executable, arguments: ["--help"], environment: environment)
        let pluginHelp = try run(executable: executable, arguments: ["plugin", "--help"], environment: environment)
        let marketplaceHelp = try run(executable: executable, arguments: ["plugin", "marketplace", "--help"], environment: environment)
        try validateCapabilities(harness, version: version, help: help, pluginHelp: pluginHelp, marketplaceHelp: marketplaceHelp)
    }

    static func parseEnvironment(_ output: String, marker: String) throws -> [String] {
        guard let range = output.range(of: "\n" + marker + "\0") else { throw LocalSessionError.missingHarness }
        var fields = String(output[range.upperBound...]).components(separatedBy: "\0")
        guard fields.count == 6, fields.removeLast().isEmpty else { throw LocalSessionError.missingHarness }
        fields[0] = fields[0].trimmingCharacters(in: .newlines)
        guard fields.prefix(4).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw LocalSessionError.missingHarness
        }
        return fields
    }

    public static func validateCapabilities(_ harness: LocalSessionHarness, version: String, help: String,
                                            pluginHelp: String, marketplaceHelp: String) throws {
        let minimum = harness == .codex ? [0, 154, 0] : [2, 1, 152]
        guard let range = version.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { throw LocalSessionError.outdatedHarness }
        let numbers = version[range].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, !numbers.lexicographicallyPrecedes(minimum) else { throw LocalSessionError.outdatedHarness }
        guard help.contains("plugin"), pluginHelp.contains(harness == .codex ? "add" : "install"),
              marketplaceHelp.contains("add"), marketplaceHelp.contains("list") else { throw LocalSessionError.outdatedHarness }
    }

    /// Synchronous only on a background task or the standalone helper. Never logs output.
    private static func run(executable: URL, arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw LocalSessionError.missingHarness }
        pipe.fileHandleForWriting.closeFile()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer { pipe.fileHandleForReading.closeFile() }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if output.count > 256 * 1024 || ProcessInfo.processInfo.systemUptime >= deadline {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw LocalSessionError.missingHarness
            }
            if !process.isRunning && count <= 0 { break }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard process.terminationStatus == 0, let value = String(data: output, encoding: .utf8) else { throw LocalSessionError.missingHarness }
        return value
    }
}
