import Darwin
import Foundation
import Security

/// The upstream login service is independent. There is deliberately no stop or uninstall API.
public actor CuaStandaloneService {
    public nonisolated let socketURL: URL
    private let homeDirectory: URL
    private let processRunner: any CuaProcessRunning
    private let permissionRunner: any CuaProcessRunning
    private let fileManager: FileManager
    private let peerInspector: (@Sendable (CuaDriverInstallation) throws -> Int32)?
    public static let label = "com.trycua.cua-driver"

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                processRunner: (any CuaProcessRunning)? = nil,
                permissionRunner: (any CuaProcessRunning)? = nil,
                fileManager: FileManager = .default,
                peerInspector: (@Sendable (CuaDriverInstallation) throws -> Int32)? = nil) {
        self.homeDirectory = homeDirectory
        self.processRunner = processRunner ?? SystemCuaProcessRunner()
        self.permissionRunner = permissionRunner ?? processRunner ?? SystemCuaProcessRunner(timeout: 600)
        self.fileManager = fileManager
        self.peerInspector = peerInspector
        socketURL = homeDirectory.appendingPathComponent("Library/Caches/cua-driver/cua-driver.sock")
    }

    /// Explicit local setup only. Preserve an existing compatible user's service configuration.
    public func setup(installation: CuaDriverInstallation) throws {
        try Task.checkCancellation()
        let directory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = directory.appendingPathComponent(Self.label + ".plist")
        if fileManager.fileExists(atPath: plistURL.path) {
            let data = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["Label"] as? String == Self.label,
                  let arguments = plist["ProgramArguments"] as? [String],
                  arguments.first == installation.executableURL.path,
                  arguments.dropFirst().first == "serve",
                  !arguments.contains("--embedded"), !arguments.contains("--parent-liveness-stdio"),
                  !arguments.contains("--socket"),
                  (plist["EnvironmentVariables"] as? [String: String])?["CUA_DRIVER_EMBEDDED"] == nil,
                  (plist["EnvironmentVariables"] as? [String: String])?["CUA_DRIVER_HOST_BUNDLE_ID"] == nil else {
                throw CuaMCPProxyError.serviceMismatch
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": [installation.executableURL.path, "serve"],
                "RunAtLoad": true,
                "KeepAlive": true,
                // Fresh installations keep the prior opt-out. Existing settings are never rewritten.
                "EnvironmentVariables": ["CUA_DRIVER_RS_TELEMETRY_ENABLED": "0"],
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .withoutOverwriting)
        }
        // An independently launched daemon already owns this socket. Register the
        // login file for the next login, but never launch a competing KeepAlive job.
        do {
            _ = try inspectPeer(installation: installation)
            return
        } catch CuaMCPProxyError.notStarted {
            // Explicit Setup may start the upstream service only when it is absent.
        }
        try Task.checkCancellation()
        let domain = "gui/\(Darwin.getuid())"
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let loaded = try processRunner.run(launchctl, arguments: ["print", "\(domain)/\(Self.label)"])
        try Task.checkCancellation()
        if loaded.status == 0 {
            let definition = String(decoding: loaded.stdout, as: UTF8.self)
            let lines = definition.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains("program = " + installation.executableURL.path),
                  !definition.contains("--embedded"), !definition.contains("--parent-liveness-stdio"),
                  !definition.contains("CUA_DRIVER_EMBEDDED"), !definition.contains("CUA_DRIVER_HOST_BUNDLE_ID") else {
                throw CuaMCPProxyError.serviceMismatch
            }
            // No -k: start a stopped upstream job without replacing an existing daemon.
            try Task.checkCancellation()
            let result = try processRunner.run(launchctl, arguments: ["kickstart", "\(domain)/\(Self.label)"])
            guard result.status == 0 else { throw CuaDriverInstallError.processFailed("CUA login service could not start") }
        } else {
            try Task.checkCancellation()
            let result = try processRunner.run(launchctl, arguments: ["bootstrap", domain, plistURL.path])
            guard result.status == 0 else { throw CuaDriverInstallError.processFailed("CUA login service could not start") }
        }
    }

    /// CUA's supported command launches its own app via LaunchServices and owns all TCC prompts.
    public func requestPermissions(installation: CuaDriverInstallation) throws {
        try Task.checkCancellation()
        let result = try permissionRunner.run(installation.executableURL, arguments: ["permissions", "grant"])
        guard result.status == 0 else { throw CuaMCPProxyError.permissionsRequired }
    }

    /// Passive kernel identity read. A matching filename or PID file is not sufficient.
    public func inspectPeer(installation: CuaDriverInstallation) throws -> Int32 {
        if let peerInspector { return try peerInspector(installation) }
        guard let pid = CuaSocketIdentity.peerPID(at: socketURL) else { throw CuaMCPProxyError.notStarted }
        guard CuaSocketIdentity.parentPID(of: pid) != nil else { throw CuaMCPProxyError.serviceMismatch }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
                == installation.executableURL.resolvingSymlinksInPath() else { throw CuaMCPProxyError.serviceMismatch }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            throw CuaMCPProxyError.serviceMismatch
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(CuaDriverCompatibility.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(CuaDriverCompatibility.teamIdentifier)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              CuaSocketIdentity.peerPID(at: socketURL) == pid else { throw CuaMCPProxyError.serviceMismatch }
        // Bind the live code object to the exact pin already verified on disk.
        var staticCode: SecStaticCode?
        var liveStaticCode: SecStaticCode?
        var liveInfo: CFDictionary?
        var diskInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(installation.executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopyStaticCode(code, [], &liveStaticCode) == errSecSuccess,
              let liveStaticCode,
              SecCodeCopySigningInformation(liveStaticCode, [], &liveInfo) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, [], &diskInfo) == errSecSuccess,
              let liveHash = (liveInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let diskHash = (diskInfo as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              liveHash == diskHash else { throw CuaMCPProxyError.serviceMismatch }
        return pid
    }
}
