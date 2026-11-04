import CryptoKit
import Darwin
import Foundation
import PersonaStackCore
import Security

/// Private native machine proof and setup intention. Hosted authority remains API-owned.
struct FileDesktopControlCredentialStore: DesktopControlCredentialStoring {
    private static let lock = NSLock()
    private let directory: URL
    private let configurationProvider: @Sendable () throws -> DesktopEnvironmentConfiguration
    private let randomBytes: @Sendable () throws -> Data
    private let legacyLoader: @Sendable (DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation?

    init(directory: URL? = nil, appURL: URL? = nil,
         configurationProvider: (@Sendable () throws -> DesktopEnvironmentConfiguration)? = nil,
         legacyLoader: @escaping @Sendable (DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation? = {
             try KeychainDesktopControlCredentialStore(configuration: $0).loadForMigration()
         }, randomBytes: (@Sendable () throws -> Data)? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PersonaStack/DesktopControlCredentials", isDirectory: true)
        self.configurationProvider = configurationProvider ?? {
            if let appURL { return try DesktopEnvironmentConfigurationStore.shared.environment(for: appURL) }
            return try LaunchConfiguration.selectedEnvironment()
        }
        self.legacyLoader = legacyLoader
        self.randomBytes = randomBytes ?? { try Self.generateCredentialBytes() }
    }

    func load() throws -> DesktopControlInstallation? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try loadInstallation(configurationProvider())
    }

    private func loadInstallation(_ configuration: DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation? {
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

    /// Loading is native custody only. A coordinator must separately validate
    /// the current human/session before using this proof in a ticket request.
    func loadPendingEnrollment() throws -> IMessagePendingEnrollment? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        return try readPendingEnrollment(configuration)
    }

    func preparePendingEnrollment(setupReference: String, naturalUserID: String, workspaceID: String,
                                  expiresAt: String, now: Date = Date()) throws -> IMessagePendingEnrollment {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        let expiry = try IMessagePendingEnrollment.validateIdentity(setupReference: setupReference,
            naturalUserID: naturalUserID, workspaceID: workspaceID,
            environmentIdentity: configuration.preferenceIdentity, expiresAt: expiresAt)
        guard expiry > now else { throw IMessagePendingEnrollmentError.expired }
        guard try loadInstallation(configuration) == nil else { throw IMessagePendingEnrollmentError.installationPresent }
        if let pending = try readPendingEnrollment(configuration) {
            try pending.requireJourney(setupReference: setupReference, naturalUserID: naturalUserID,
                workspaceID: workspaceID, environmentIdentity: configuration.preferenceIdentity, expiresAt: expiresAt)
            try pending.requireUsable(now: now)
            return pending
        }
        let proof: Data
        do { proof = try randomBytes() }
        catch { throw IMessagePendingEnrollmentError.randomnessUnavailable }
        guard proof.count == 32 else { throw IMessagePendingEnrollmentError.randomnessUnavailable }
        let pending = try IMessagePendingEnrollment(setupReference: setupReference, naturalUserID: naturalUserID,
            workspaceID: workspaceID, environmentIdentity: configuration.preferenceIdentity,
            expiresAt: expiresAt, credentialBytes: proof)
        try writeRecord(try JSONEncoder().encode(pending), configuration: configuration, kind: .pendingIMessage)
        return pending
    }

    @discardableResult
    func clearPendingEnrollment(matching expected: IMessagePendingEnrollment) throws -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        try expected.requireEnvironment(configuration.preferenceIdentity)
        guard let current = try readPendingEnrollment(configuration), current == expected else { return false }
        try writeRecord(Data("null".utf8), configuration: configuration, kind: .pendingIMessage)
        return true
    }

    private func readPendingEnrollment(_ configuration: DesktopEnvironmentConfiguration) throws -> IMessagePendingEnrollment? {
        guard let data = try readFile(configuration, kind: .pendingIMessage) else { return nil }
        let pending: IMessagePendingEnrollment?
        do { pending = try JSONDecoder().decode(IMessagePendingEnrollment?.self, from: data) }
        catch { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        try pending?.requireEnvironment(configuration.preferenceIdentity)
        return pending
    }

    /// Drafts restore intention only. Loading never restores consent, machine
    /// proof or metadata authority, including when the original journey expired.
    func loadSetupDraft() throws -> IMessageSetupDraft? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readSetupDraft(configurationProvider())
    }

    func saveSetupDraft(_ draft: IMessageSetupDraft, now: Date = Date()) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        try draft.requireEnvironment(configuration.preferenceIdentity)
        try draft.requireUsable(now: now)
        if let current = try readSetupDraft(configuration) {
            try current.requireJourney(setupReference: draft.setupReference, naturalUserID: draft.naturalUserID,
                workspaceID: draft.workspaceID, environmentIdentity: draft.environmentIdentity, expiresAt: draft.expiresAt)
        }
        try writeRecord(try JSONEncoder().encode(draft), configuration: configuration, kind: .setupIMessage)
    }

    @discardableResult
    func clearSetupDraft(matching expected: IMessageSetupDraft) throws -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let configuration = try configurationProvider()
        try expected.requireEnvironment(configuration.preferenceIdentity)
        guard let current = try readSetupDraft(configuration), current == expected else { return false }
        try writeRecord(Data("null".utf8), configuration: configuration, kind: .setupIMessage)
        return true
    }

    private func readSetupDraft(_ configuration: DesktopEnvironmentConfiguration) throws -> IMessageSetupDraft? {
        guard let data = try readFile(configuration, kind: .setupIMessage) else { return nil }
        let draft: IMessageSetupDraft?
        do { draft = try JSONDecoder().decode(IMessageSetupDraft?.self, from: data) }
        catch { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        try draft?.requireEnvironment(configuration.preferenceIdentity)
        return draft
    }

    private static func generateCredentialBytes() throws -> Data {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw IMessagePendingEnrollmentError.randomnessUnavailable }
        return bytes
    }

    private enum RecordKind { case installation, pendingIMessage, setupIMessage }

    private func filename(_ configuration: DesktopEnvironmentConfiguration, kind: RecordKind = .installation) -> String {
        let identity = SHA256.hash(data: Data(configuration.preferenceIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        switch kind {
        case .installation: return identity + ".json"
        case .pendingIMessage: return identity + ".imessage-pending.json"
        case .setupIMessage: return identity + ".imessage-setup.json"
        }
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

    private func readFile(_ configuration: DesktopEnvironmentConfiguration, kind: RecordKind = .installation) throws -> Data? {
        guard let parent = try directoryDescriptor(create: false) else { return nil }
        defer { close(parent) }
        let descriptor = openat(parent, filename(configuration, kind: kind), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
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
        try writeRecord(try JSONEncoder().encode(installation), configuration: configuration, kind: .installation)
    }

    private func writeRecord(_ data: Data, configuration: DesktopEnvironmentConfiguration, kind: RecordKind) throws {
        guard !data.isEmpty, data.count <= 16_384,
              let parent = try directoryDescriptor(create: true) else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        defer { close(parent) }
        let destination = filename(configuration, kind: kind)
        try validateDestination(parent, filename: destination)
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        defer { close(descriptor); unlinkat(parent, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        try validate(descriptor, type: S_IFREG)
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0, renameat(parent, temporary, parent, destination) == 0, fsync(parent) == 0 else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
    }

    private func validateDestination(_ parent: Int32, filename: String) throws {
        let descriptor = openat(parent, filename, O_WRONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return }
        guard descriptor >= 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        defer { close(descriptor) }
        try validate(descriptor, type: S_IFREG)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
            var offset = 0
            while offset < data.count {
                let count = write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
                offset += count
            }
        }
    }
}

extension IMessagePendingEnrollment {
    /// Canonical digest for the ticket body. Raw proof is used only in native Authorization.
    var credentialSHA256: String {
        Data(SHA256.hash(data: credentialBytes)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
