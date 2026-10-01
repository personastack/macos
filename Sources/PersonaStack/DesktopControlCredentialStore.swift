import CryptoKit
import Darwin
import Foundation
import PersonaStackCore

/// Native machine proof only. Hosted identity and authorization remain API-owned.
struct FileDesktopControlCredentialStore: DesktopControlCredentialStoring {
    private static let lock = NSLock()
    private let directory: URL
    private let configurationProvider: @Sendable () throws -> DesktopEnvironmentConfiguration
    private let legacyLoader: @Sendable (DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation?

    init(directory: URL? = nil, appURL: URL? = nil,
         configurationProvider: (@Sendable () throws -> DesktopEnvironmentConfiguration)? = nil,
         legacyLoader: @escaping @Sendable (DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation? = {
             try KeychainDesktopControlCredentialStore(configuration: $0).loadForMigration()
         }) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PersonaStack/DesktopControlCredentials", isDirectory: true)
        self.configurationProvider = configurationProvider ?? {
            if let appURL { return try DesktopEnvironmentConfigurationStore.shared.environment(for: appURL) }
            return try LaunchConfiguration.selectedEnvironment()
        }
        self.legacyLoader = legacyLoader
    }

    func load() throws -> DesktopControlInstallation? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        if let data = try readFile(configuration) {
            let installation: DesktopControlInstallation?
            do { installation = try JSONDecoder().decode(DesktopControlInstallation?.self, from: data) }
            catch { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
            try installation?.requireEnvironment(configuration.appPageURL, configuration: configuration)
            return installation
        }
        let installation: DesktopControlInstallation?
        do { installation = try legacyLoader(configuration) }
        catch DesktopControlEnrollmentError.credentialAccessRequired {
            // The old token cannot be recovered without authorization. A fresh
            // authenticated setup can enroll a new identity. Never use its ID
            // as proof or delete the old server configuration.
            installation = nil
        }
        try installation?.requireEnvironment(configuration.appPageURL, configuration: configuration)
        try writeFile(installation, configuration: configuration)
        return installation
    }

    func save(_ installation: DesktopControlInstallation) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        try writeFile(installation, configuration: configuration)
    }

    func delete() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Null records prevent the retained legacy item from returning later.
        try writeFile(nil, configuration: configurationProvider())
    }

    private func filename(_ configuration: DesktopEnvironmentConfiguration) -> String {
        SHA256.hash(data: Data(configuration.preferenceIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func directoryDescriptor(create: Bool) throws -> Int32? {
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
            } catch { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 && errno == ENOENT && !create { return nil }
        guard descriptor >= 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        do { try validate(descriptor, type: S_IFDIR) }
        catch { close(descriptor); throw error }
        return descriptor
    }

    private func validate(_ descriptor: Int32, type: mode_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(), info.st_mode & S_IFMT == type,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 || type == S_IFDIR else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
    }

    private func readFile(_ configuration: DesktopEnvironmentConfiguration) throws -> Data? {
        guard let parent = try directoryDescriptor(create: false) else { return nil }
        defer { close(parent) }
        let descriptor = openat(parent, filename(configuration), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        defer { close(descriptor) }
        try validate(descriptor, type: S_IFREG)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= 16_384 else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        return data
    }

    private func writeFile(_ installation: DesktopControlInstallation?,
                           configuration: DesktopEnvironmentConfiguration) throws {
        guard let parent = try directoryDescriptor(create: true) else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        defer { close(parent) }
        let descriptor = openat(parent, filename(configuration), O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        defer { close(descriptor) }
        try validate(descriptor, type: S_IFREG)
        let data = try JSONEncoder().encode(installation)
        guard data.count <= 16_384, ftruncate(descriptor, 0) == 0,
              data.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == data.count else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
    }
}
