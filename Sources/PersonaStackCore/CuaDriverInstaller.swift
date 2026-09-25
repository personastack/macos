import CryptoKit
import Darwin
import Foundation

public struct CuaProcessResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CuaProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult
}

public struct SystemCuaProcessRunner: CuaProcessRunning {
    private let timeout: TimeInterval
    private let outputLimit: Int

    public init(timeout: TimeInterval = 30, outputLimit: Int = 1024 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        let allowedEnvironment = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        process.environment = ProcessInfo.processInfo.environment.filter { allowedEnvironment.contains($0.key) }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Both pipes must drain while the process runs. A full stderr pipe otherwise
        // blocks a CLI whose stdout is still being read by the installer.
        let output = BoundedProcessOutput(limit: outputLimit)
        let error = BoundedProcessOutput(limit: outputLimit)
        let readers = DispatchGroup()
        for (handle, collector) in [(stdout.fileHandleForReading, output), (stderr.fileHandleForReading, error)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                collector.drain(handle)
            }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let killGrace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killGrace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            if !process.isRunning { process.waitUntilExit() }
            throw CuaDriverInstallError.processFailed("Cua validation command timed out")
        }
        process.waitUntilExit()
        guard readers.wait(timeout: .now() + 1) == .success else {
            throw CuaDriverInstallError.processFailed("Cua validation output did not close")
        }
        guard !output.readFailed && !error.readFailed else {
            throw CuaDriverInstallError.processFailed("Cua validation output could not be read")
        }
        guard !output.exceededLimit && !error.exceededLimit else {
            throw CuaDriverInstallError.processFailed("Cua validation output exceeded limit")
        }
        return CuaProcessResult(status: process.terminationStatus, stdout: output.data, stderr: error.data)
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var overflow = false
    private var failed = false

    init(limit: Int) { self.limit = max(0, limit) }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overflow
    }

    var readFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func drain(_ handle: FileHandle) {
        defer { try? handle.close() }
        do {
            while let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty {
                lock.lock()
                let remaining = max(0, limit - bytes.count)
                if remaining > 0 { bytes.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { overflow = true }
                lock.unlock()
            }
        } catch {
            lock.lock()
            failed = true
            lock.unlock()
        }
    }
}

public enum CuaDriverInstallError: Error, Equatable {
    case downloadFailed
    case checksumMismatch
    case extractionFailed
    case invalidLayout
    case invalidSignature
    case incompatibleRuntime
    case processFailed(String)
}

public struct CuaDriverInstallation: Equatable, Sendable {
    public let applicationURL: URL
    public let executableURL: URL
    public let version: String
    public let toolNames: Set<String>

    public init(applicationURL: URL, executableURL: URL, version: String, toolNames: Set<String>) {
        self.applicationURL = applicationURL
        self.executableURL = executableURL
        self.version = version
        self.toolNames = toolNames
    }
}

/// Reuses a compatible signed Cua Driver app, or installs the pinned release into
/// PersonaStack-owned Application Support. Unmanaged apps are never modified.
public actor CuaDriverInstaller {
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let processRunner: any CuaProcessRunning
    private let session: URLSession
    private let externalApplicationURLs: [URL]

    public init(
        supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonaStack/DesktopControl", isDirectory: true),
        fileManager: FileManager = .default,
        processRunner: any CuaProcessRunning = SystemCuaProcessRunner(),
        session: URLSession = .shared,
        externalApplicationURLs: [URL]? = nil
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.session = session
        self.externalApplicationURLs = externalApplicationURLs ?? [
            URL(fileURLWithPath: "/Applications/CuaDriver.app", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CuaDriver.app", isDirectory: true),
        ]
    }

    public func validateOrInstall(
        repair: Bool = false,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)? = nil
    ) async throws -> CuaDriverInstallation {
        let installRoot = supportDirectory.appendingPathComponent("CuaDriver-\(CuaDriverCompatibility.version)", isDirectory: true)
        let replacingManagedInstall = fileManager.fileExists(atPath: installRoot.path)
        if fileManager.fileExists(atPath: installRoot.path) {
            if !repair, let existing = try? validate(at: installRoot) { return existing }
        }
        for application in externalApplicationURLs where fileManager.fileExists(atPath: application.path) {
            if let existing = try? validateExternalApplication(at: application) { return existing }
        }
        if replacingManagedInstall {
            guard isPersonaStackManaged(installRoot) else { throw CuaDriverInstallError.invalidLayout }
        }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let staging = supportDirectory.appendingPathComponent(".cua-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("cua-driver.tar.gz")
        try await download(to: archive)
        guard try Self.sha256(file: archive) == CuaDriverCompatibility.archiveSHA256 else {
            throw CuaDriverInstallError.checksumMismatch
        }

        let extracted = staging.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
        let tarURL = URL(fileURLWithPath: "/usr/bin/tar")
        let extraction = try processRunner.run(tarURL, arguments: ["-xzf", archive.path, "-C", extracted.path])
        guard extraction.status == 0 else { throw CuaDriverInstallError.extractionFailed }

        let payload = extracted.appendingPathComponent("cua-driver-rs-\(CuaDriverCompatibility.version)-darwin-universal", isDirectory: true)
        let application = payload.appendingPathComponent("CuaDriver.app", isDirectory: true)
        let executable = payload.appendingPathComponent("cua-driver")
        guard fileManager.fileExists(atPath: application.path), fileManager.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverInstallError.invalidLayout
        }
        try verifySignature(application)
        let validated = try validate(applicationURL: application, executableURL: executable)
        try Self.installLicenseNotice(into: payload)
        let ownership = InstallOwnership(version: CuaDriverCompatibility.version, archiveSHA256: CuaDriverCompatibility.archiveSHA256)
        let ownershipData = try JSONEncoder().encode(ownership)
        try ownershipData.write(to: payload.appendingPathComponent(Self.ownershipFile), options: .atomic)
        if let commitManagedInstall {
            try await commitManagedInstall(installRoot, payload, replacingManagedInstall)
        } else {
            if replacingManagedInstall { try fileManager.removeItem(at: installRoot) }
            try fileManager.moveItem(at: payload, to: installRoot)
        }
        return CuaDriverInstallation(
            applicationURL: installRoot.appendingPathComponent("CuaDriver.app", isDirectory: true),
            executableURL: installRoot.appendingPathComponent("cua-driver"),
            version: validated.version,
            toolNames: validated.toolNames
        )
    }

    private func validate(at root: URL) throws -> CuaDriverInstallation {
        let application = root.appendingPathComponent("CuaDriver.app", isDirectory: true)
        let executable = root.appendingPathComponent("cua-driver")
        guard fileManager.fileExists(atPath: application.path), fileManager.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverInstallError.invalidLayout
        }
        try verifySignature(application)
        return try validate(applicationURL: application, executableURL: executable)
    }

    private func validateExternalApplication(at application: URL) throws -> CuaDriverInstallation {
        let executable = application.appendingPathComponent("Contents/MacOS/cua-driver")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverInstallError.invalidLayout
        }
        try verifySignature(application)
        return try validate(applicationURL: application, executableURL: executable)
    }

    private func isPersonaStackManaged(_ root: URL) -> Bool {
        let marker = root.appendingPathComponent(Self.ownershipFile)
        guard let data = try? Data(contentsOf: marker),
              let ownership = try? JSONDecoder().decode(InstallOwnership.self, from: data) else { return false }
        return ownership.version == CuaDriverCompatibility.version
            && ownership.archiveSHA256 == CuaDriverCompatibility.archiveSHA256
    }

    private func validate(applicationURL: URL, executableURL: URL) throws -> CuaDriverInstallation {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == CuaDriverCompatibility.bundleIdentifier else {
            throw CuaDriverInstallError.invalidLayout
        }
        let manifestResult = try run(executableURL, ["manifest", "--pretty"])
        guard let manifestData = Self.jsonObject(in: manifestResult.stdout) else {
            throw CuaDriverInstallError.incompatibleRuntime
        }
        let toolsResult = try run(executableURL, ["list-tools"])
        guard let toolOutput = String(data: toolsResult.stdout, encoding: .utf8) else {
            throw CuaDriverInstallError.incompatibleRuntime
        }
        let toolNames = CuaDriverCompatibility.parseToolNames(toolOutput)
        do {
            try CuaDriverCompatibility.validate(manifestData: manifestData, toolNames: toolNames)
        } catch {
            throw CuaDriverInstallError.incompatibleRuntime
        }
        return CuaDriverInstallation(
            applicationURL: applicationURL,
            executableURL: executableURL,
            version: CuaDriverCompatibility.version,
            toolNames: toolNames
        )
    }

    private func verifySignature(_ applicationURL: URL) throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let verified = try processRunner.run(codesign, arguments: ["--verify", "--deep", "--strict", applicationURL.path])
        guard verified.status == 0 else { throw CuaDriverInstallError.invalidSignature }
        let details = try processRunner.run(codesign, arguments: ["-dv", "--verbose=4", applicationURL.path])
        let text = String(decoding: details.stderr + details.stdout, as: UTF8.self)
        guard details.status == 0,
              text.contains("Identifier=\(CuaDriverCompatibility.bundleIdentifier)"),
              text.contains("TeamIdentifier=\(CuaDriverCompatibility.teamIdentifier)") else {
            throw CuaDriverInstallError.invalidSignature
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> CuaProcessResult {
        let result = try processRunner.run(executable, arguments: arguments)
        guard result.status == 0 else {
            throw CuaDriverInstallError.processFailed(String(decoding: result.stderr, as: UTF8.self).prefix(512).description)
        }
        return result
    }

    private func download(to destination: URL) async throws {
        var request = URLRequest(url: CuaDriverCompatibility.archiveURL)
        request.timeoutInterval = 120
        let (temporary, response): (URL, URLResponse)
        do { (temporary, response) = try await session.download(for: request) }
        catch { throw CuaDriverInstallError.downloadFailed }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CuaDriverInstallError.downloadFailed }
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonObject(in data: Data) -> Data? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")), start <= end else { return nil }
        return data[start...end]
    }

    private static let ownershipFile = ".personastack-cua-install.json"

    static func installLicenseNotice(into directory: URL) throws {
        try Data(CuaDriverCompatibility.licenseNotice.utf8).write(
            to: directory.appendingPathComponent("LICENSE-CuaDriver-MIT.txt"), options: .atomic
        )
    }

    private struct InstallOwnership: Decodable, Encodable {
        let version: String
        let archiveSHA256: String
    }
}
