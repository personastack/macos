import Darwin
import Foundation
import PersonaStackCore

struct AgentBridgeLegacySupervisor {
    static let label = "ai.personastack.connector"
    /// This authority is native-only. It never accepts a path or process ID from the page.
    static func stop(scope: String) throws {
        guard scope == "user_launch_agent" else { throw AgentBridgeFailure.migrationRequired }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size < 64 * 1024 else { throw AgentBridgeFailure.migrationRequired }
        let data = try Data(contentsOf: path)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let args = plist["ProgramArguments"] as? [String], args.count == 3,
              URL(fileURLWithPath: args[0]).lastPathComponent == "personastack-connector",
              Array(args.dropFirst()) == ["run", "--foreground"] else { throw AgentBridgeFailure.migrationRequired }
        let target = "gui/\(getuid())/\(label)"
        // Already stopped is accepted. No plist/config deletion and no runtime process kill.
        if try launchctl(["print", target]) != 0 { return }
        guard try launchctl(["bootout", target]) == 0, try launchctl(["print", target]) != 0 else {
            throw AgentBridgeFailure.cleanupRequired
        }
    }
    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
