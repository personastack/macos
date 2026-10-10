import Darwin
import Foundation

/// Native settings supply these URLs. This is not a WebView authorization input.
public struct AgentBridgeApprovedEnvironment: Codable, Equatable, Sendable {
    public let environmentID: String
    public let gatewayBaseURL: String
    public init(_ configuration: DesktopEnvironmentConfiguration) {
        environmentID = configuration.appOrigin
        gatewayBaseURL = configuration.gatewayURL.absoluteString
    }
    enum CodingKeys: String, CodingKey { case environmentID = "environment_id", gatewayBaseURL = "gateway_base_url" }
}

public enum AgentBridgeEnvironments {
    /// Only explicit Enable/setup may remove the helper's disabled preference.
    public static func enable(directory: URL = AgentBridgeNativePaths.directory) throws {
        try AgentBridgeNativePaths.createDirectory(directory)
        let marker = directory.appendingPathComponent("disabled")
        var information = stat()
        guard lstat(marker.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw AgentBridgeFailure.invalidRequest
        }
        guard information.st_uid == getuid(), information.st_mode & 0o077 == 0,
              information.st_mode & S_IFMT == S_IFREG, information.st_nlink == 1 else { throw AgentBridgeFailure.invalidRequest }
        try FileManager.default.removeItem(at: marker)
    }
    public static func approve(_ configuration: DesktopEnvironmentConfiguration,
                               directory: URL = AgentBridgeNativePaths.directory) throws {
        try AgentBridgeNativePaths.createDirectory(directory)
        let file = directory.appendingPathComponent("environments.json")
        var values: [AgentBridgeApprovedEnvironment] = []
        var information = stat()
        if lstat(file.path, &information) == 0 {
            guard information.st_uid == getuid(), information.st_mode & 0o077 == 0,
                  information.st_mode & S_IFMT == S_IFREG else { throw AgentBridgeFailure.invalidRequest }
            let data = try Data(contentsOf: file)
            guard data.count <= AgentBridgeRequest.maximumBytes else { throw AgentBridgeFailure.invalidRequest }
            values = try JSONDecoder().decode([AgentBridgeApprovedEnvironment].self, from: data)
        } else if errno != ENOENT { throw AgentBridgeFailure.invalidRequest }
        let approved = AgentBridgeApprovedEnvironment(configuration)
        values.removeAll { $0.environmentID == approved.environmentID }
        values.append(approved)
        guard values.count <= 64 else { throw AgentBridgeFailure.invalidRequest }
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
