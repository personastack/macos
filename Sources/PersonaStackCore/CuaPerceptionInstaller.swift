import CryptoKit
import Darwin
import Foundation

public enum CuaPerceptionCompatibility {
    public static let version = "0.2.1"
    public static let target = "aarch64-apple-darwin"
    public static let archiveBytes: Int64 = 426_075_949
    public static let archiveSHA256 = "5fbcf59c15fc5cd8beca6ac4aa5533c34359054810aceb12c9e26d7a45e750ab"
    public static let catalogSHA256 = "d20c1e1cbf5d90cfa85b956100846c2c7a43c387fdc5b344d75a15f91498aa42"
    public static let manifestSHA256 = "99297debe5c0fd9f2ce5e80545e74dc2662dc66597278603136a9f5defd1784a"
    public static let artifact = "cua-perception-0.2.1-aarch64-apple-darwin"
    public static let releaseURL = URL(string: "https://github.com/trycua/cua/releases/download/cua-perception-v0.2.1/")!
    public static var supportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}

public enum CuaPerceptionError: Error, LocalizedError, Equatable {
    case unsupportedArchitecture, invalidArtifact, invalidReview, approvalRequired, commandFailed, unsafeCache
    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture: "The pinned CUA perception extension is unavailable for Intel Macs. Other desktop controls remain available."
        case .invalidArtifact: "The perception download did not match the pinned release."
        case .invalidReview: "The perception installation review could not be verified."
        case .approvalRequired: "Review the perception component and choose Install before installing it."
        case .commandFailed: "CUA could not verify or install the perception component."
        case .unsafeCache: "The perception staging directory is not a private owned directory."
        }
    }
}

public struct CuaPerceptionInstallReview: Equatable, Sendable {
    public let id: UUID
    public let json: Data
    public let destination: String
    public let license: String
    public let installedBytes: Int64
    public var displayJSON: String { String(decoding: json, as: UTF8.self) }
}

public struct CuaPerceptionStatus: Equatable, Sendable {
    public let installed: Bool
    public let healthy: Bool
    public let version: String?
    public var ready: Bool { installed && healthy && version == CuaPerceptionCompatibility.version }
    public init(installed: Bool, healthy: Bool, version: String?) {
        self.installed = installed
        self.healthy = healthy
        self.version = version
    }
}

/// The downloader receives only pinned URLs. Its byte limit applies during transfer.
public protocol CuaPerceptionDownloading: Sendable {
    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws
}

public protocol CuaPerceptionInstalling: Sendable {
    var catalogURL: URL { get async }
    func prepareReview(driver: CuaDriverInstallation) async throws -> CuaPerceptionInstallReview
    func install(review: CuaPerceptionInstallReview) async throws -> CuaPerceptionStatus
    func status(driver: CuaDriverInstallation) async throws -> CuaPerceptionStatus
    func cancelReview() async
}

public actor CuaPerceptionInstaller: CuaPerceptionInstalling {
    private let root: URL
    private let runner: any CuaProcessRunning
    private let downloader: any CuaPerceptionDownloading
    private let supported: Bool
    private var preparing = false
    private var generation = 0
    private var pending: (review: CuaPerceptionInstallReview, executable: URL)?

    public init(cacheDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PersonaStack/DesktopControl/Perception-0.2.1", isDirectory: true),
                processRunner: any CuaProcessRunning = SystemCuaProcessRunner(timeout: 180, outputLimit: 1024 * 1024),
                downloader: any CuaPerceptionDownloading = SystemCuaPerceptionDownloader(),
                supportedArchitecture: Bool = CuaPerceptionCompatibility.supportedArchitecture) {
        root = cacheDirectory
        runner = processRunner
        self.downloader = downloader
        supported = supportedArchitecture
    }

    public var catalogURL: URL { root.appendingPathComponent(CuaPerceptionCompatibility.artifact + ".catalog.json") }
    private var archiveURL: URL { root.appendingPathComponent(CuaPerceptionCompatibility.artifact + ".tar.gz") }

    public func prepareReview(driver: CuaDriverInstallation) async throws -> CuaPerceptionInstallReview {
        guard supported else { throw CuaPerceptionError.unsupportedArchitecture }
        guard !preparing else { throw CuaPerceptionError.commandFailed }
        preparing = true
        defer { preparing = false }
        pending = nil
        generation += 1
        let current = generation
        try prepareDirectory()
        try await stage(catalogURL, bytes: 920, hash: CuaPerceptionCompatibility.catalogSHA256)
        try await stage(archiveURL, bytes: CuaPerceptionCompatibility.archiveBytes, hash: CuaPerceptionCompatibility.archiveSHA256)
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let review = try inspect(driver.executableURL)
        pending = (review, driver.executableURL)
        return review
    }

    /// Only the native Install action receives this exact opaque review value.
    public func install(review: CuaPerceptionInstallReview) throws -> CuaPerceptionStatus {
        guard let approved = pending, approved.review == review else { throw CuaPerceptionError.approvalRequired }
        pending = nil
        try verifyStagedFiles()
        let fresh = try inspect(approved.executable)
        guard fresh.json == review.json else { throw CuaPerceptionError.invalidReview }
        try Task.checkCancellation()
        _ = try run(approved.executable, ["extension", "install", "cua-perception", "--catalog", catalogURL.path])
        return try status(executable: approved.executable)
    }

    public func cancelReview() { generation += 1; pending = nil }

    /// Upstream verifies installed files and may run its bounded health hook.
    /// This never requests installation, a self-test, or screen capture.
    public func status(driver: CuaDriverInstallation) throws -> CuaPerceptionStatus {
        guard supported else { throw CuaPerceptionError.unsupportedArchitecture }
        return try status(executable: driver.executableURL)
    }

    private func status(executable: URL) throws -> CuaPerceptionStatus {
        let data = try run(executable, ["extension", "status", "cua-perception", "--json"])
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["id"] as? String == "cua-perception", let installed = fields["installed"] as? Bool,
              let healthy = fields["healthy"] as? Bool else { throw CuaPerceptionError.invalidReview }
        if installed {
            guard fields["trust"] as? String == "publisher-verified",
                  fields["evidence_class"] as? String == "production-publisher-verified",
                  fields["publisher_id"] as? String == "cua",
                  fields["publisher_key_id"] as? String == "cua-extension-ed25519-2026-09",
                  (fields["catalog_version"] as? NSNumber)?.int64Value == 2_609_260_017 else { throw CuaPerceptionError.invalidReview }
        }
        return CuaPerceptionStatus(installed: installed, healthy: healthy, version: fields["active_version"] as? String)
    }

    private func inspect(_ executable: URL) throws -> CuaPerceptionInstallReview {
        let data = try run(executable, ["extension", "inspect", "cua-perception", "--catalog", catalogURL.path, "--json"])
        return try Self.validatedReview(data)
    }

    public static func validatedReview(_ data: Data) throws -> CuaPerceptionInstallReview {
        guard data.count <= 1024 * 1024,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["id"] as? String == "cua-perception",
              fields["version"] as? String == CuaPerceptionCompatibility.version,
              fields["target"] as? String == CuaPerceptionCompatibility.target,
              fields["trust"] as? String == "publisher-verified",
              fields["evidence_class"] as? String == "production-publisher-verified",
              fields["publisher_id"] as? String == "cua",
              fields["publisher_key_id"] as? String == "cua-extension-ed25519-2026-09",
              fields["publisher_signature_verified"] as? Bool == true,
              (fields["catalog_version"] as? NSNumber)?.int64Value == 2_609_260_017,
              fields["archive_sha256"] as? String == CuaPerceptionCompatibility.archiveSHA256,
              fields["manifest_sha256"] as? String == CuaPerceptionCompatibility.manifestSHA256,
              (fields["download_size"] as? NSNumber)?.int64Value == CuaPerceptionCompatibility.archiveBytes,
              fields["mutation_performed"] as? Bool == false,
              let destination = fields["destination"] as? String, destination.hasPrefix("/"),
              let license = fields["license"] as? String, !license.isEmpty,
              let size = fields["installed_size"] as? NSNumber, size.int64Value > 0,
              let notices = fields["license_notices"] as? [Any], !notices.isEmpty,
              let models = fields["model_licenses"] as? [Any], !models.isEmpty else { throw CuaPerceptionError.invalidReview }
        let canonical = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        return CuaPerceptionInstallReview(id: UUID(), json: canonical, destination: destination, license: license, installedBytes: size.int64Value)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        try Task.checkCancellation()
        let result = try runner.run(executable, arguments: arguments)
        try Task.checkCancellation()
        guard result.status == 0 else { throw CuaPerceptionError.commandFailed }
        return result.stdout
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try verifyDirectory()
    }

    private func verifyDirectory() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CuaPerceptionError.unsafeCache
        }
    }

    private func stage(_ destination: URL, bytes: Int64, hash: String) async throws {
        try verifyDirectory()
        if (try? Self.matches(destination, bytes: bytes, hash: hash)) == true { return }
        // Refuse existing unexpected files. Never replace a caller-controlled path.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CuaPerceptionError.invalidArtifact }
        try await downloader.download(CuaPerceptionCompatibility.releaseURL.appendingPathComponent(destination.lastPathComponent),
                                      to: destination, maximumBytes: bytes)
        guard try Self.matches(destination, bytes: bytes, hash: hash) else {
            _ = unlink(destination.path)
            throw CuaPerceptionError.invalidArtifact
        }
    }

    private func verifyStagedFiles() throws {
        try verifyDirectory()
        guard try Self.matches(catalogURL, bytes: 920, hash: CuaPerceptionCompatibility.catalogSHA256),
              try Self.matches(archiveURL, bytes: CuaPerceptionCompatibility.archiveBytes, hash: CuaPerceptionCompatibility.archiveSHA256) else {
            throw CuaPerceptionError.invalidArtifact
        }
    }

    private static func matches(_ url: URL, bytes: Int64, hash: String) throws -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size == bytes else { return false }
        var digest = SHA256()
        var consumed: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            consumed += Int64(data.count)
            guard consumed <= bytes else { return false }
            digest.update(data: data)
        }
        guard consumed == bytes else { return false }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == hash
    }
}
