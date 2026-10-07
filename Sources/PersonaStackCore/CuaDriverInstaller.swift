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

public enum CuaProcessError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputDidNotClose
    case outputReadFailed
    case outputLimitExceeded
}

public struct SystemCuaProcessRunner: CuaProcessRunning {
    private let timeout: TimeInterval
    private let outputLimit: Int

    public init(timeout: TimeInterval = 30, outputLimit: Int = 1024 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func run(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let handles = [stdout.fileHandleForReading, stderr.fileHandleForReading,
                       stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        defer { for handle in handles { try? handle.close() } }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = CuaDriverCompatibility.processEnvironment(from: ProcessInfo.processInfo.environment)
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch { throw CuaProcessError.launchFailed }
        defer { stopOwnedCommand(process) }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        // Nonblocking reads share the command's lifetime. A grandchild retaining a
        // pipe cannot strand a reader thread or keep this setup action alive.
        let output = try BoundedProcessOutput(handle: stdout.fileHandleForReading, limit: outputLimit)
        let error = try BoundedProcessOutput(handle: stderr.fileHandleForReading, limit: outputLimit)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var outputDeadline: TimeInterval?
        while true {
            try Task.checkCancellation()
            try output.drain()
            try error.drain()
            let now = ProcessInfo.processInfo.systemUptime
            if !process.isRunning {
                if output.closed && error.closed { break }
                if outputDeadline == nil { outputDeadline = now + 1 }
                if now >= outputDeadline! { throw CuaProcessError.outputDidNotClose }
            } else if now >= deadline {
                throw CuaProcessError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard !output.exceededLimit && !error.exceededLimit else { throw CuaProcessError.outputLimitExceeded }
        return CuaProcessResult(status: process.terminationStatus, stdout: output.data, stderr: error.data)
    }

    private func stopOwnedCommand(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killGrace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killGrace {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        if !process.isRunning { process.waitUntilExit() }
        // Only this short-lived command belongs to setup. CUA's independent
        // service and any application launched for consent remain untouched.
    }
}

private final class BoundedProcessOutput {
    private let descriptor: Int32
    private let limit: Int
    private(set) var data = Data()
    private(set) var exceededLimit = false
    private(set) var closed = false

    init(handle: FileHandle, limit: Int) throws {
        descriptor = handle.fileDescriptor
        self.limit = max(0, limit)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CuaProcessError.outputReadFailed
        }
    }

    func drain() throws {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each pass so a continuously writing process cannot starve the
        // other stream, deadline, or cancellation checks.
        for _ in 0..<32 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { closed = true; return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw CuaProcessError.outputReadFailed
            }
            let remaining = max(0, limit - data.count)
            data.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining { exceededLimit = true }
        }
    }
}

public enum CuaDriverInstallError: Error, Equatable, Sendable {
    case downloadTimedOut
    case placementFailed
    case verificationFailed(CuaProcessError)
    case extractionCommandFailed(CuaProcessError)
    case downloadFailed
    case installationNotWritable
    case checksumMismatch
    case extractionFailed
    case invalidLayout
    case invalidSignature
    case incompatibleRuntime
}

extension CuaDriverInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .installationNotWritable:
            "CUA must be installed in /Applications for its permission setup. An administrator must install CuaDriver.app there, then choose Check Again."
        case .incompatibleRuntime:
            "The installed CUA version is not compatible with this PersonaStack release. PersonaStack will not replace or downgrade it."
        case .invalidSignature, .checksumMismatch:
            "CUA could not be verified against the reviewed signed release. The existing installation was not changed."
        case .downloadTimedOut:
            "CUA download timed out. Check the connection and choose Retry Install."
        case .placementFailed:
            "CUA could not be placed in Applications. Check available disk space and access to Applications, then choose Retry Install."
        case .extractionFailed, .extractionCommandFailed:
            "CUA could not be extracted. Check available disk space, then choose Retry Install."
        case .verificationFailed:
            "CUA verification could not finish. Choose Check Again to verify the installed application."
        case .invalidLayout:
            "The CUA application is incomplete or has an unexpected layout. Ask an administrator to install the supported CuaDriver.app in Applications, then choose Check Again."
        case .downloadFailed:
            "CUA could not be downloaded. Check the connection and choose Install CUA again."
        }
    }
}

public enum CuaInstallStage: String, Sendable {
    case checking = "Checking existing CUA installation"
    case downloading = "Downloading CUA"
    case verifyingDownload = "Verifying CUA download"
    case extracting = "Extracting CUA"
    case verifyingApplication = "Verifying CUA application"
    case installing = "Installing CUA in Applications"
    case installed = "CUA is installed"
    case starting = "Starting CUA service"
}

public typealias CuaInstallProgress = @Sendable (CuaInstallStage) async -> Void

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
/// /Applications. CUA’s own permission command requires this upstream path.
public actor CuaDriverInstaller {
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let processRunner: any CuaProcessRunning
    private let session: URLSession
    private let externalApplicationURLs: [URL]
    private let downloadTimeout: TimeInterval

    public init(
        supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonaStack/DesktopControl", isDirectory: true),
        fileManager: FileManager = .default,
        processRunner: any CuaProcessRunning = SystemCuaProcessRunner(),
        session: URLSession = .shared,
        externalApplicationURLs: [URL]? = nil,
        downloadTimeout: TimeInterval = 300
    ) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.session = session
        self.downloadTimeout = downloadTimeout
        self.externalApplicationURLs = externalApplicationURLs ?? [
            URL(fileURLWithPath: "/Applications/CuaDriver.app", isDirectory: true),
        ]
    }

    /// Passive discovery never downloads, launches, or replaces an application.
    public func discoverExisting() throws -> CuaDriverInstallation? {
        var failure: Error?
        for application in externalApplicationURLs where fileManager.fileExists(atPath: application.path) {
            do { return try validateExternalApplication(at: application) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if let failure { throw failure }
        return nil
    }

    /// Called only by the user's Install CUA action. CUA is not a PersonaStack resource.
    public func install() async throws -> CuaDriverInstallation {
        try await install(progress: { _ in })
    }

    public func install(progress: CuaInstallProgress) async throws -> CuaDriverInstallation {
        await progress(.checking)
        try Task.checkCancellation()
        if let existing = try discoverExisting() {
            await progress(.installed)
            return existing
        }
        guard let applicationDestination = externalApplicationURLs.last else { throw CuaDriverInstallError.invalidLayout }
        let applicationsDirectory = applicationDestination.deletingLastPathComponent()
        if fileManager.fileExists(atPath: applicationsDirectory.path),
           !fileManager.isWritableFile(atPath: applicationsDirectory.path) {
            throw CuaDriverInstallError.installationNotWritable
        }
        let staging = supportDirectory.appendingPathComponent(".cua-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch { throw CuaDriverInstallError.placementFailed }
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("cua-driver.tar.gz")
        await progress(.downloading)
        try await download(to: archive)
        await progress(.verifyingDownload)
        try Task.checkCancellation()
        do {
            guard try Self.sha256(file: archive) == CuaDriverCompatibility.archiveSHA256 else {
                throw CuaDriverInstallError.checksumMismatch
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw CuaDriverInstallError.checksumMismatch }

        let extracted = staging.appendingPathComponent("payload", isDirectory: true)
        do { try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false) }
        catch { throw CuaDriverInstallError.extractionFailed }
        let tarURL = URL(fileURLWithPath: "/usr/bin/tar")
        await progress(.extracting)
        try Task.checkCancellation()
        let extraction: CuaProcessResult
        do { extraction = try processRunner.run(tarURL, arguments: ["-xzf", archive.path, "-C", extracted.path]) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CuaProcessError { throw CuaDriverInstallError.extractionCommandFailed(error) }
        catch { throw CuaDriverInstallError.extractionFailed }
        guard extraction.status == 0 else { throw CuaDriverInstallError.extractionFailed }

        let payload = extracted.appendingPathComponent("cua-driver-rs-\(CuaDriverCompatibility.version)-darwin-universal", isDirectory: true)
        let application = payload.appendingPathComponent("CuaDriver.app", isDirectory: true)
        let executable = application.appendingPathComponent("Contents/MacOS/cua-driver")
        guard fileManager.fileExists(atPath: application.path), fileManager.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverInstallError.invalidLayout
        }
        await progress(.verifyingApplication)
        try Task.checkCancellation()
        try verifySignature(application)
        _ = try validate(applicationURL: application, executableURL: executable)
        // The extracted app remains byte-for-byte signed. Keep its license beside it.
        let license = applicationsDirectory.appendingPathComponent("LICENSE-CuaDriver-MIT.txt")
        if !fileManager.fileExists(atPath: license.path) {
            do { try Self.installLicenseNotice(into: applicationsDirectory) }
            catch {
                guard fileManager.fileExists(atPath: license.path) else { throw CuaDriverInstallError.placementFailed }
            }
        }
        try Task.checkCancellation()
        await progress(.installing)
        try Task.checkCancellation()
        let installed = try placeValidatedApplication(application, at: applicationDestination)
        try Task.checkCancellation()
        await progress(.installed)
        return installed
    }

    /// The final location is the authority, including when another installer wins
    /// placement. Never overwrite or remove a shared installation.
    func placeValidatedApplication(_ application: URL, at destination: URL) throws -> CuaDriverInstallation {
        if !fileManager.fileExists(atPath: destination.path) {
            do { try fileManager.moveItem(at: application, to: destination) }
            catch {
                guard fileManager.fileExists(atPath: destination.path) else {
                    throw CuaDriverInstallError.placementFailed
                }
            }
        }
        return try validateExternalApplication(at: destination)
    }

    private func validateExternalApplication(at application: URL) throws -> CuaDriverInstallation {
        let executable = application.appendingPathComponent("Contents/MacOS/cua-driver")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CuaDriverInstallError.invalidLayout
        }
        try verifySignature(application)
        return try validate(applicationURL: application, executableURL: executable)
    }

    private func validate(applicationURL: URL, executableURL: URL) throws -> CuaDriverInstallation {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == CuaDriverCompatibility.bundleIdentifier else {
            throw CuaDriverInstallError.invalidLayout
        }
        let checksum = try verificationCommand(URL(fileURLWithPath: "/usr/bin/shasum"),
                                             arguments: ["-a", "256", executableURL.path])
        guard checksum.status == 0,
              String(decoding: checksum.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
                == Substring(CuaDriverCompatibility.executableSHA256) else {
            throw CuaDriverInstallError.checksumMismatch
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
        let verified = try verificationCommand(codesign, arguments: ["--verify", "--deep", "--strict", applicationURL.path])
        guard verified.status == 0 else { throw CuaDriverInstallError.invalidSignature }
        let details = try verificationCommand(codesign, arguments: ["-dv", "--verbose=4", applicationURL.path])
        let text = String(decoding: details.stderr + details.stdout, as: UTF8.self)
        guard details.status == 0,
              text.contains("Identifier=\(CuaDriverCompatibility.bundleIdentifier)"),
              text.contains("TeamIdentifier=\(CuaDriverCompatibility.teamIdentifier)") else {
            throw CuaDriverInstallError.invalidSignature
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> CuaProcessResult {
        let result = try verificationCommand(executable, arguments: arguments)
        guard result.status == 0 else {
            throw CuaDriverInstallError.incompatibleRuntime
        }
        return result
    }

    private func verificationCommand(_ executable: URL, arguments: [String]) throws -> CuaProcessResult {
        do { return try processRunner.run(executable, arguments: arguments) }
        catch is CancellationError { throw CancellationError() }
        catch let error as CuaProcessError { throw CuaDriverInstallError.verificationFailed(error) }
        catch { throw CuaDriverInstallError.verificationFailed(.launchFailed) }
    }

    private func download(to destination: URL) async throws {
        var request = URLRequest(url: CuaDriverCompatibility.archiveURL)
        request.timeoutInterval = 120
        let session = session
        let timeout = downloadTimeout
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [request] in
                    let (temporary, response) = try await session.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw CuaDriverInstallError.downloadFailed
                    }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CuaDriverInstallError.downloadTimedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let failure = error as? CuaDriverInstallError { throw failure }
            if (error as? URLError)?.code == .timedOut { throw CuaDriverInstallError.downloadTimedOut }
            throw CuaDriverInstallError.downloadFailed
        }
    }

    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
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

    static func installLicenseNotice(into directory: URL) throws {
        try Data(CuaDriverCompatibility.licenseNotice.utf8).write(
            to: directory.appendingPathComponent("LICENSE-CuaDriver-MIT.txt"), options: .withoutOverwriting
        )
    }

}
