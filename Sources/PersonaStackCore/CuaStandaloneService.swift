import Darwin
import Foundation
import Security

public enum CuaStandaloneServiceError: Error, Equatable, Sendable, LocalizedError {
    case configurationFailed
    case serviceDisabled
    case startFailed
    case startTimedOut
    case permissionLaunchFailed
    case permissionCommandFailed
    case permissionTimedOut

    public var errorDescription: String? {
        switch self {
        case .configurationFailed:
            "CUA is installed, but its login service could not be configured. Check access to your Library/LaunchAgents folder, then choose Check Again."
        case .serviceDisabled:
            "CUA's login service is disabled. Enable CUA in macOS System Settings > General > Login Items, then choose Check Again."
        case .startFailed:
            "CUA is installed, but its login service could not start. Choose Retry Start. If this continues, check CUA in macOS Login Items."
        case .startTimedOut:
            "CUA is installed, but its service did not become reachable in time. Choose Check Again before retrying startup."
        case .permissionLaunchFailed:
            "CUA's permission command could not open. Choose Grant CUA Permissions to try again."
        case .permissionCommandFailed:
            "CUA's permission request did not finish successfully. Check the permission status below, then choose Grant CUA Permissions to try again."
        case .permissionTimedOut:
            "CUA's permission request timed out. Finish any open macOS permission prompts, then choose Check Again."
        }
    }
}

/// The upstream login service is independent. There is deliberately no stop or uninstall API.
public actor CuaStandaloneService {
    public nonisolated let socketURL: URL
    private let homeDirectory: URL
    private let processRunner: any CuaProcessRunning
    private let permissionRunner: any CuaProcessRunning
    private let fileManager: FileManager
    private let startupTimeout: TimeInterval
    private let monotonicNow: @Sendable () -> TimeInterval
    private let startupPause: @Sendable () async throws -> Void
    private let peerInspector: (@Sendable (CuaDriverInstallation) throws -> Int32)?
    public static let label = "com.trycua.cua-driver"

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                processRunner: (any CuaProcessRunning)? = nil,
                permissionRunner: (any CuaProcessRunning)? = nil,
                fileManager: FileManager = .default,
                peerInspector: (@Sendable (CuaDriverInstallation) throws -> Int32)? = nil,
                startupTimeout: TimeInterval = 5,
                monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                startupPause: @escaping @Sendable () async throws -> Void = {
                    try await Task.sleep(for: .milliseconds(100))
                }) {
        self.homeDirectory = homeDirectory
        self.processRunner = processRunner ?? SystemCuaProcessRunner()
        self.permissionRunner = permissionRunner ?? processRunner ?? SystemCuaProcessRunner(timeout: 600)
        self.fileManager = fileManager
        self.peerInspector = peerInspector
        self.startupPause = startupPause
        self.startupTimeout = startupTimeout
        self.monotonicNow = monotonicNow
        socketURL = homeDirectory.appendingPathComponent("Library/Caches/cua-driver/cua-driver.sock")
    }

    /// Explicit local setup only. Preserve an existing compatible user's service configuration.
    public func setup(installation: CuaDriverInstallation) async throws {
        do { try await configureAndStart(installation: installation) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CuaMCPProxyError { throw error }
        catch let error as CuaStandaloneServiceError { throw error }
        catch { throw CuaStandaloneServiceError.configurationFailed }
    }

    private func configureAndStart(installation: CuaDriverInstallation) async throws {
        try Task.checkCancellation()
        let peerIsRunning: Bool
        do {
            _ = try inspectPeer(installation: installation)
            peerIsRunning = true
        } catch CuaMCPProxyError.notStarted {
            peerIsRunning = false
        }
        let directory = homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = directory.appendingPathComponent(Self.label + ".plist")
        if fileManager.fileExists(atPath: plistURL.path) {
            let data = try Data(contentsOf: plistURL)
            try validateConfiguration(data, installation: installation, peerIsRunning: peerIsRunning)
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
        // A verified independent daemon already owns the socket. Preserve its
        // settings and never launch a competing KeepAlive job.
        if peerIsRunning { return }
        try Task.checkCancellation()
        let domain = "gui/\(Darwin.getuid())"
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let disabled = try runStartupCommand(launchctl, arguments: ["print-disabled", domain])
        guard disabled.status == 0 else { throw CuaStandaloneServiceError.startFailed }
        let disabledLines = String(decoding: disabled.stdout, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !disabledLines.contains("\"\(Self.label)\" => true") else {
            throw CuaStandaloneServiceError.serviceDisabled
        }
        try Task.checkCancellation()
        let loaded = try runStartupCommand(launchctl, arguments: ["print", "\(domain)/\(Self.label)"])
        try Task.checkCancellation()
        if loaded.status == 0 {
            let definition = String(decoding: loaded.stdout, as: UTF8.self)
            let lines = definition.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.contains("program = " + installation.executableURL.path),
                  !definition.contains("--embedded"), !definition.contains("--parent-liveness-stdio"),
                  !definition.contains("--socket"),
                  !definition.contains("CUA_DRIVER_EMBEDDED"), !definition.contains("CUA_DRIVER_HOST_BUNDLE_ID") else {
                throw CuaMCPProxyError.serviceMismatch
            }
            // No -k: start a stopped upstream job without replacing an existing daemon.
            try Task.checkCancellation()
            let result = try runStartupCommand(launchctl, arguments: ["kickstart", "\(domain)/\(Self.label)"])
            guard result.status == 0 else { throw CuaStandaloneServiceError.startFailed }
        } else {
            try Task.checkCancellation()
            let result = try runStartupCommand(launchctl, arguments: ["bootstrap", domain, plistURL.path])
            guard result.status == 0 else { throw CuaStandaloneServiceError.startFailed }
        }
        try await waitForStartedPeer(installation: installation)
    }

    private func validateConfiguration(_ data: Data, installation: CuaDriverInstallation, peerIsRunning: Bool) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CuaStandaloneServiceError.configurationFailed
        }
        guard peerIsRunning || plist["Disabled"] as? Bool != true else { throw CuaStandaloneServiceError.serviceDisabled }
        guard plist["Label"] as? String == Self.label,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first == installation.executableURL.path,
              arguments.dropFirst().first == "serve",
              !arguments.contains("--embedded"), !arguments.contains("--parent-liveness-stdio"),
              !arguments.contains(where: { $0 == "--socket" || $0.hasPrefix("--socket=") }),
              (plist["EnvironmentVariables"] as? [String: String])?["CUA_DRIVER_EMBEDDED"] == nil,
              (plist["EnvironmentVariables"] as? [String: String])?["CUA_DRIVER_HOST_BUNDLE_ID"] == nil else {
            throw CuaMCPProxyError.serviceMismatch
        }
    }

    private func waitForStartedPeer(installation: CuaDriverInstallation) async throws {
        let deadline = monotonicNow() + startupTimeout
        while monotonicNow() < deadline {
            try Task.checkCancellation()
            do {
                _ = try inspectPeer(installation: installation)
                return
            } catch CuaMCPProxyError.notStarted {
                try await startupPause()
            }
        }
        throw CuaStandaloneServiceError.startTimedOut
    }

    /// CUA's supported command launches its own app via LaunchServices and owns all TCC prompts.
    public func requestPermissions(installation: CuaDriverInstallation) throws {
        try Task.checkCancellation()
        let result: CuaProcessResult
        do { result = try permissionRunner.run(installation.executableURL, arguments: ["permissions", "grant"]) }
        catch is CancellationError { throw CancellationError() }
        catch CuaProcessError.timedOut { throw CuaStandaloneServiceError.permissionTimedOut }
        catch CuaProcessError.launchFailed { throw CuaStandaloneServiceError.permissionLaunchFailed }
        catch { throw CuaStandaloneServiceError.permissionCommandFailed }
        try Task.checkCancellation()
        guard result.status == 0 else { throw CuaStandaloneServiceError.permissionCommandFailed }
    }

    private func runStartupCommand(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        do { return try processRunner.run(executable, arguments: arguments) }
        catch is CancellationError { throw CancellationError() }
        catch { throw CuaStandaloneServiceError.startFailed }
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
