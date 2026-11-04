import CryptoKit
import Darwin
import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private func credentialFixture(_ configuration: DesktopEnvironmentConfiguration = .production) throws -> DesktopControlInstallation {
    let data = try JSONSerialization.data(withJSONObject: [
        "installation_id": "fixture-mac",
        "machine_credential": Data(repeating: 0x42, count: 32).base64EncodedString(),
        "gateway_websocket_url": configuration.gatewayWebsocketURL.absoluteString,
        "environment_origin": configuration.appOrigin,
    ])
    return try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
}

private final class DiskCredentialFixture: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let lock = NSLock()
    private var count = 0
    private var generated = 0
    var reads: Int { lock.withLock { count } }
    var generations: Int { lock.withLock { generated } }
    func recordRead() { lock.withLock { count += 1 } }
    func nextProof() -> Data { lock.withLock { generated += 1; return Data(repeating: UInt8(generated), count: 32) } }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func file(_ configuration: DesktopEnvironmentConfiguration = .production) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(configuration.preferenceIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func pendingFile(_ configuration: DesktopEnvironmentConfiguration = .production) -> URL {
        file(configuration).deletingPathExtension().appendingPathExtension("imessage-pending.json")
    }
    func setupDraftFile(_ configuration: DesktopEnvironmentConfiguration = .production) -> URL {
        file(configuration).deletingPathExtension().appendingPathExtension("imessage-setup.json")
    }
    func store(_ configuration: DesktopEnvironmentConfiguration = .production,
               legacy: @escaping @Sendable () throws -> DesktopControlInstallation? = { nil },
               random: (@Sendable () throws -> Data)? = nil) -> FileDesktopControlCredentialStore {
        FileDesktopControlCredentialStore(directory: directory, configurationProvider: { configuration }, legacyLoader: { _ in
            self.recordRead()
            return try legacy()
        }, randomBytes: random)
    }
}

@Test func diskCredentialMigratesOnceAndSurvivesNewStoreAndMenuRetry() throws {
    let fixture = DiskCredentialFixture()
    let installation = try credentialFixture()
    let store = fixture.store(legacy: { installation })
    #expect(try store.load() == installation)
    #expect(try store.loadWithUserInteraction() == installation)
    #expect(try fixture.store(legacy: { throw DesktopControlEnrollmentError.credentialAccessRequired }).load() == installation)
    #expect(fixture.reads == 1)
    let directoryMode = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int
    let fileMode = try FileManager.default.attributesOfItem(atPath: fixture.file().path)[.posixPermissions] as? Int
    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
}

@Test func deniedLegacyCredentialAllowsFreshEnrollmentWithoutRepeatedKeychainReads() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(legacy: { throw DesktopControlEnrollmentError.credentialAccessRequired })
    #expect(try store.load() == nil)
    #expect(try fixture.store().loadWithUserInteraction() == nil)
    #expect(fixture.reads == 1)
    let installation = try credentialFixture()
    try store.save(installation)
    #expect(try fixture.store().load() == installation)
    #expect(fixture.reads == 1)
}

private actor DiskEnrollmentTransport: DesktopControlEnrollmentTransport {
    let installation: DesktopControlInstallation
    private(set) var calls = 0
    init(installation: DesktopControlInstallation) { self.installation = installation }
    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int) {
        calls += 1
        #expect(url == DesktopEnvironmentConfiguration.production.appURL.appendingPathComponent("v1/desktop-control/enroll"))
        #expect(bearer == nil)
        #expect(try JSONDecoder().decode([String: String].self, from: body) == ["enrollment_ticket": "fresh-authorized-ticket"])
        return (try JSONEncoder().encode(installation), 201)
    }
}

@Test func deniedLegacyCredentialEnrollsWithFreshTicketAndPersistsProofOnDisk() async throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(legacy: { throw DesktopControlEnrollmentError.credentialAccessRequired })
    let installation = try credentialFixture()
    let transport = DiskEnrollmentTransport(installation: installation)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: store)
    #expect(try await client.enroll(ticket: "fresh-authorized-ticket", appURL: DesktopEnvironmentConfiguration.production.appPageURL) == installation)
    #expect(try fixture.store().load() == installation)
    #expect(try await client.enroll(ticket: "", appURL: DesktopEnvironmentConfiguration.production.appPageURL) == installation)
    #expect(await transport.calls == 1)
    #expect(fixture.reads == 1)
}

@Test func diskCredentialDeletionCannotResurrectLegacyIdentity() throws {
    let fixture = DiskCredentialFixture()
    let installation = try credentialFixture()
    let store = fixture.store(legacy: { installation })
    try store.delete()
    #expect(try fixture.store(legacy: { installation }).load() == nil)
    #expect(fixture.reads == 0)
}

@Test func diskCredentialsSeparateAllThreeServerURLs() throws {
    let fixture = DiskCredentialFixture()
    let production = try credentialFixture()
    let alternate = try DesktopEnvironmentConfiguration(appURL: DesktopEnvironmentConfiguration.production.appOrigin,
        gatewayURL: "https://alternate.example", mcpURL: "https://mcp.personastack.ai")
    try fixture.store().save(production)
    #expect(try fixture.store(alternate).load() == nil)
    #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try fixture.store(alternate).save(production) }
    #expect(try fixture.store().load() == production)
}

@Test func diskCredentialInvalidDataDoesNotFallBackToKeychain() throws {
    let fixture = DiskCredentialFixture()
    try fixture.store().save(credentialFixture())
    try Data("invalid".utf8).write(to: fixture.file())
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().load() }
    #expect(fixture.reads == 0)
}

@Test func diskCredentialMigrationStorageErrorsRemainErrors() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(legacy: { throw DesktopControlEnrollmentError.credentialStoreUnavailable })
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.load() }
    #expect(!FileManager.default.fileExists(atPath: fixture.file().path))
}

@Test func diskCredentialRejectsOversizedFileBeforeDecodeOrLegacyRead() throws {
    let fixture = DiskCredentialFixture()
    try fixture.store().save(credentialFixture())
    try Data(repeating: 0x20, count: 16_385).write(to: fixture.file())
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().load() }
    #expect(fixture.reads == 0)
}

@Test(arguments: ["symlink", "hardlink", "directory", "fifo", "mode"])
func diskCredentialRejectsUnsafeFiles(kind: String) throws {
    let fixture = DiskCredentialFixture()
    let target = fixture.directory.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    switch kind {
    case "symlink":
        try FileManager.default.createSymbolicLink(at: fixture.file(), withDestinationURL: target)
    case "hardlink":
        try Data("null".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #expect(link(target.path, fixture.file().path) == 0)
    case "directory":
        try FileManager.default.createDirectory(at: fixture.file(), withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    case "fifo": #expect(mkfifo(fixture.file().path, 0o600) == 0)
    default:
        try Data("null".utf8).write(to: fixture.file())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file().path)
    }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().load() }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().save(credentialFixture()) }
    #expect(fixture.reads == 0)
}

@Test func diskCredentialRejectsPublicDirectoryAndWrongEnvironment() throws {
    let fixture = DiskCredentialFixture()
    try fixture.store().save(credentialFixture())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().load() }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try fixture.store().save(credentialFixture()) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    try JSONEncoder().encode(credentialFixture(.lan)).write(to: fixture.file())
    #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try fixture.store().load() }
    #expect(fixture.reads == 0)
}

private let diskPendingReference = String(repeating: "A", count: 43)
private let diskPendingExpiry = "2030-01-02T03:04:05.123456789Z"
private let diskPendingNow = Date(timeIntervalSince1970: 1_700_000_000)

private func prepareDiskPending(_ store: FileDesktopControlCredentialStore, reference: String = diskPendingReference,
                                user: String = "natural-user", workspace: String = "workspace",
                                expiry: String = diskPendingExpiry, now: Date = diskPendingNow) throws -> IMessagePendingEnrollment {
    try store.preparePendingEnrollment(setupReference: reference, naturalUserID: user, workspaceID: workspace,
        expiresAt: expiry, now: now)
}

@Test func iMessageDiskPendingEnrollmentPersistsBeforeReturnAndReusesProofAfterRestart() throws {
    let fixture = DiskCredentialFixture()
    let pending = try prepareDiskPending(fixture.store(random: { fixture.nextProof() }))
    let persisted = try JSONDecoder().decode(IMessagePendingEnrollment.self, from: Data(contentsOf: fixture.pendingFile()))
    #expect(persisted == pending)
    #expect(try fixture.store().loadPendingEnrollment() == pending)
    #expect(try prepareDiskPending(fixture.store(random: { fixture.nextProof() })) == pending)
    #expect(fixture.generations == 1)
    #expect(fixture.reads == 1)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.pendingFile().path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(try fixture.store().load() == nil)
}

@Test func iMessageDiskPendingEnrollmentTicketDigestIsCanonicalSHA256RatherThanTheProof() throws {
    let fixture = DiskCredentialFixture()
    let pending = try prepareDiskPending(fixture.store(random: { Data(count: 32) }))
    let digest = pending.credentialSHA256
    let standard = digest.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
    let bytes = try #require(Data(base64Encoded: standard))
    #expect(bytes.map { String(format: "%02x", $0) }.joined() == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
    #expect(digest.utf8.count == 43)
    #expect(!digest.contains("="))
    #expect(digest != pending.machineCredential)
}

@Test func iMessageDiskPendingEnrollmentRefusesConflictingJourneysWithoutReplacingProof() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    let pending = try prepareDiskPending(store)
    let original = try Data(contentsOf: fixture.pendingFile())
    let otherReference = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    #expect(throws: IMessagePendingEnrollmentError.conflictingJourney) { try prepareDiskPending(store, reference: otherReference) }
    #expect(throws: IMessagePendingEnrollmentError.conflictingJourney) { try prepareDiskPending(store, user: "another-user") }
    #expect(throws: IMessagePendingEnrollmentError.conflictingJourney) { try prepareDiskPending(store, workspace: "another-workspace") }
    #expect(throws: IMessagePendingEnrollmentError.conflictingJourney) { try prepareDiskPending(store, expiry: "2030-01-02T03:04:06Z") }
    #expect(try Data(contentsOf: fixture.pendingFile()) == original)
    #expect(try store.loadPendingEnrollment() == pending)
    #expect(fixture.generations == 1)
}

@Test func iMessageDiskPendingEnrollmentRefusesExistingInstallationAndPreservesMigration() throws {
    let fixture = DiskCredentialFixture()
    let installation = try credentialFixture()
    let store = fixture.store(legacy: { installation }, random: { fixture.nextProof() })
    #expect(throws: IMessagePendingEnrollmentError.installationPresent) { try prepareDiskPending(store) }
    #expect(try fixture.store().load() == installation)
    let original = try Data(contentsOf: fixture.file())
    #expect(throws: IMessagePendingEnrollmentError.installationPresent) { try prepareDiskPending(fixture.store(random: { fixture.nextProof() })) }
    #expect(try Data(contentsOf: fixture.file()) == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.pendingFile().path))
    #expect(fixture.generations == 0)
    #expect(fixture.reads == 1)
}

@Test func iMessageDiskPendingEnrollmentSeparatesEnvironmentsAndRejectsForeignClear() throws {
    let fixture = DiskCredentialFixture()
    let alternate = try DesktopEnvironmentConfiguration(appURL: DesktopEnvironmentConfiguration.production.appOrigin,
        gatewayURL: "https://alternate.example", mcpURL: "https://mcp.personastack.ai")
    let pending = try prepareDiskPending(fixture.store(random: { fixture.nextProof() }))
    #expect(try fixture.store(alternate).loadPendingEnrollment() == nil)
    let other = try prepareDiskPending(fixture.store(alternate, random: { fixture.nextProof() }))
    #expect(other.environmentIdentity != pending.environmentIdentity)
    #expect(throws: IMessagePendingEnrollmentError.scopeMismatch) { try fixture.store(alternate).clearPendingEnrollment(matching: pending) }
    #expect(try fixture.store().loadPendingEnrollment() == pending)
    #expect(try fixture.store(alternate).loadPendingEnrollment() == other)
    try JSONEncoder().encode(other).write(to: fixture.pendingFile())
    #expect(throws: IMessagePendingEnrollmentError.scopeMismatch) { try fixture.store().loadPendingEnrollment() }
}

@Test func iMessageDiskPendingEnrollmentExpiryKeepsRecoveryProofAndExplicitClearPreservesInstallation() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    let pending = try prepareDiskPending(store)
    let originalInstallation = try Data(contentsOf: fixture.file())
    #expect(throws: IMessagePendingEnrollmentError.expired) { try prepareDiskPending(store, now: pending.expiry) }
    #expect(try store.loadPendingEnrollment() == pending)
    #expect(try store.clearPendingEnrollment(matching: pending))
    #expect(try store.loadPendingEnrollment() == nil)
    #expect(try Data(contentsOf: fixture.file()) == originalInstallation)
    let replacement = try prepareDiskPending(store, user: "another-user")
    #expect(replacement.machineCredential != pending.machineCredential)
    #expect(try store.clearPendingEnrollment(matching: pending) == false)
    #expect(try store.loadPendingEnrollment() == replacement)
    let installed = try credentialFixture()
    try store.save(installed)
    let installedData = try Data(contentsOf: fixture.file())
    #expect(try store.clearPendingEnrollment(matching: replacement))
    #expect(try Data(contentsOf: fixture.file()) == installedData)
    #expect(try store.load() == installed)
}

@Test func iMessageDiskPendingEnrollmentRejectsBadInputAndRandomnessBeforeCreatingProof() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    #expect(throws: IMessagePendingEnrollmentError.invalidRecord) { try prepareDiskPending(store, reference: "locator") }
    #expect(throws: IMessagePendingEnrollmentError.expired) { try prepareDiskPending(store, expiry: "2020-01-02T03:04:05Z") }
    #expect(fixture.reads == 0)
    #expect(fixture.generations == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    #expect(throws: IMessagePendingEnrollmentError.randomnessUnavailable) {
        try prepareDiskPending(fixture.store(random: { throw IMessagePendingEnrollmentError.randomnessUnavailable }))
    }
    #expect(throws: IMessagePendingEnrollmentError.randomnessUnavailable) {
        try prepareDiskPending(fixture.store(random: { Data(count: 31) }))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.pendingFile().path))
    #expect(try fixture.store().load() == nil)
}

@Test(arguments: ["invalid", "oversized"])
func iMessageDiskPendingEnrollmentRejectsCorruptionWithoutReplacingCustody(kind: String) throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    let pending = try prepareDiskPending(store)
    let badData = kind == "invalid" ? Data("invalid".utf8) : Data(repeating: 0x20, count: 16_385)
    try badData.write(to: fixture.pendingFile())
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.loadPendingEnrollment() }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try prepareDiskPending(store) }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.clearPendingEnrollment(matching: pending) }
    #expect(try Data(contentsOf: fixture.pendingFile()) == badData)
    #expect(fixture.generations == 1)
    #expect(fixture.reads == 1)
}

@Test(arguments: ["symlink", "hardlink", "directory", "fifo", "mode"])
func iMessageDiskPendingEnrollmentRejectsUnsafeRecords(kind: String) throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    #expect(try store.load() == nil)
    let target = fixture.directory.appendingPathComponent("target")
    switch kind {
    case "symlink": try FileManager.default.createSymbolicLink(at: fixture.pendingFile(), withDestinationURL: target)
    case "hardlink":
        try Data("null".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #expect(link(target.path, fixture.pendingFile().path) == 0)
    case "directory":
        try FileManager.default.createDirectory(at: fixture.pendingFile(), withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    case "fifo": #expect(mkfifo(fixture.pendingFile().path, 0o600) == 0)
    default:
        try Data("null".utf8).write(to: fixture.pendingFile())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.pendingFile().path)
    }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.loadPendingEnrollment() }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try prepareDiskPending(store) }
    #expect(fixture.generations == 0)
    #expect(fixture.reads == 1)
}

@Test func iMessageDiskPendingEnrollmentFailedWriteAndClearLeaveExistingRecordsIntact() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    #expect(try store.load() == nil)
    let installation = try Data(contentsOf: fixture.file())
    // Deny mutation through a private read-only directory. This test requires
    // the normal non-root macOS app-test user rather than a privileged runner.
    #expect(geteuid() != 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try prepareDiskPending(store) }
    #expect(!FileManager.default.fileExists(atPath: fixture.pendingFile().path))
    #expect(try Data(contentsOf: fixture.file()) == installation)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
    let pending = try prepareDiskPending(store)
    let persisted = try Data(contentsOf: fixture.pendingFile())
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.clearPendingEnrollment(matching: pending) }
    #expect(try Data(contentsOf: fixture.pendingFile()) == persisted)
    #expect(try Data(contentsOf: fixture.file()) == installation)
}

private func diskSetupDraftFixture(_ configuration: DesktopEnvironmentConfiguration = .production,
                                   reference: String = diskPendingReference, user: String = "natural-user",
                                   workspace: String = "workspace", expiry: String = diskPendingExpiry,
                                   selected: [IMessageSetupDraft.Selection]? = nil) throws -> IMessageSetupDraft {
    let selections = try selected ?? [IMessageSetupDraft.Selection(nativeChatRowID: "1", expectedGUID: "iMessage;-;draft-guid")]
    return try IMessageSetupDraft(setupReference: reference, naturalUserID: user, workspaceID: workspace,
        environmentIdentity: configuration.preferenceIdentity, expiresAt: expiry,
        expectedAccountID: "draft-account", sourceGeneration: "draft-source", selectedConversations: selections)
}

@Test func iMessageDiskSetupDraftPersistsWithoutReadingLegacyOrCreatingMachineProof() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(legacy: { throw DesktopControlEnrollmentError.credentialStoreUnavailable }, random: { fixture.nextProof() })
    let draft = try diskSetupDraftFixture()
    try store.saveSetupDraft(draft, now: diskPendingNow)
    #expect(try fixture.store().loadSetupDraft() == draft)
    #expect(try JSONDecoder().decode(IMessageSetupDraft.self, from: Data(contentsOf: fixture.setupDraftFile())) == draft)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.setupDraftFile().path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int == 0o700)
    #expect(!FileManager.default.fileExists(atPath: fixture.file().path))
    #expect(!FileManager.default.fileExists(atPath: fixture.pendingFile().path))
    #expect(fixture.reads == 0)
    #expect(fixture.generations == 0)
}

@Test func iMessageDiskSetupDraftPreservesExistingInstallationAndPendingEnrollment() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    let pending = try prepareDiskPending(store)
    let installation = try credentialFixture()
    try store.save(installation)
    let installationBytes = try Data(contentsOf: fixture.file())
    let pendingBytes = try Data(contentsOf: fixture.pendingFile())
    let draft = try diskSetupDraftFixture()
    try store.saveSetupDraft(draft, now: diskPendingNow)
    #expect(try fixture.store().loadSetupDraft() == draft)
    #expect(try fixture.store().load() == installation)
    #expect(try fixture.store().loadPendingEnrollment() == pending)
    #expect(try store.clearSetupDraft(matching: draft))
    #expect(try fixture.store().loadSetupDraft() == nil)
    #expect(try Data(contentsOf: fixture.file()) == installationBytes)
    #expect(try Data(contentsOf: fixture.pendingFile()) == pendingBytes)
    #expect(fixture.reads == 1)
    #expect(fixture.generations == 1)
}

@Test func iMessageDiskSetupDraftExactClearPreservesChangedSelectionsAndNewJourney() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store()
    let first = try diskSetupDraftFixture()
    let replacement = try diskSetupDraftFixture(selected: [IMessageSetupDraft.Selection(nativeChatRowID: "2", expectedGUID: "other-guid")])
    try store.saveSetupDraft(first, now: diskPendingNow)
    try store.saveSetupDraft(replacement, now: diskPendingNow)
    #expect(try !store.clearSetupDraft(matching: first))
    #expect(try fixture.store().loadSetupDraft() == replacement)
    #expect(try store.clearSetupDraft(matching: replacement))
    let reference = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let fresh = try diskSetupDraftFixture(reference: reference)
    try store.saveSetupDraft(fresh, now: diskPendingNow)
    #expect(try !store.clearSetupDraft(matching: replacement))
    #expect(try fixture.store().loadSetupDraft() == fresh)
    #expect(fixture.reads == 0)
    #expect(fixture.generations == 0)
}

@Test func iMessageDiskSetupDraftCannotRenewOrReplaceOriginalJourneyWithoutExactClear() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store()
    let draft = try diskSetupDraftFixture()
    try store.saveSetupDraft(draft, now: diskPendingNow)
    let original = try Data(contentsOf: fixture.setupDraftFile())
    let reference = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    for changed in [try diskSetupDraftFixture(reference: reference), try diskSetupDraftFixture(user: "other-user"),
                    try diskSetupDraftFixture(workspace: "other-workspace"), try diskSetupDraftFixture(expiry: "2031-01-02T03:04:05Z")] {
        #expect(throws: IMessageSetupDraftError.conflictingJourney) { try store.saveSetupDraft(changed, now: diskPendingNow) }
    }
    #expect(throws: IMessageSetupDraftError.expired) { try store.saveSetupDraft(draft, now: draft.expiry) }
    let loadedDraft = try fixture.store().loadSetupDraft()
    let expired = try #require(loadedDraft)
    #expect(expired == draft)
    #expect(throws: IMessageSetupDraftError.expired) { try expired.requireUsable(now: draft.expiry) }
    #expect(try Data(contentsOf: fixture.setupDraftFile()) == original)
    #expect(try store.clearSetupDraft(matching: expired))
}

@Test func iMessageDiskSetupDraftSeparatesProfilesAndValidatesLoadedEnvironment() throws {
    let fixture = DiskCredentialFixture()
    let production = try diskSetupDraftFixture()
    let alternate = try DesktopEnvironmentConfiguration(appURL: DesktopEnvironmentConfiguration.production.appOrigin,
        gatewayURL: "https://draft-alternate.example", mcpURL: "https://mcp.personastack.ai")
    let other = try diskSetupDraftFixture(alternate)
    try fixture.store().saveSetupDraft(production, now: diskPendingNow)
    #expect(try fixture.store(alternate).loadSetupDraft() == nil)
    #expect(throws: IMessageSetupDraftError.scopeMismatch) { try fixture.store(alternate).saveSetupDraft(production, now: diskPendingNow) }
    #expect(throws: IMessageSetupDraftError.scopeMismatch) { try fixture.store(alternate).clearSetupDraft(matching: production) }
    try fixture.store(alternate).saveSetupDraft(other, now: diskPendingNow)
    #expect(try fixture.store().loadSetupDraft() == production)
    #expect(try fixture.store(alternate).loadSetupDraft() == other)
    try JSONEncoder().encode(other).write(to: fixture.setupDraftFile())
    #expect(throws: IMessageSetupDraftError.scopeMismatch) { try fixture.store().loadSetupDraft() }
    #expect(fixture.reads == 0)
}

@Test func iMessageDiskSetupDraftRejectsMalformedAndOversizedRecordsWithoutRepair() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store()
    let draft = try diskSetupDraftFixture()
    try store.saveSetupDraft(draft, now: diskPendingNow)
    for invalid in [Data("{invalid-private-record".utf8), Data(repeating: 0x20, count: 16_385)] {
        try invalid.write(to: fixture.setupDraftFile())
        #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.loadSetupDraft() }
        #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.saveSetupDraft(draft, now: diskPendingNow) }
        #expect(try Data(contentsOf: fixture.setupDraftFile()) == invalid)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.file().path))
    #expect(!FileManager.default.fileExists(atPath: fixture.pendingFile().path))
    #expect(fixture.reads == 0)
    #expect(fixture.generations == 0)
}

@Test(arguments: ["symlink", "hardlink", "directory", "fifo", "mode"])
func iMessageDiskSetupDraftRejectsUnsafeFiles(kind: String) throws {
    let fixture = DiskCredentialFixture()
    let target = fixture.directory.appendingPathComponent("draft-target")
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    switch kind {
    case "symlink":
        try FileManager.default.createSymbolicLink(at: fixture.setupDraftFile(), withDestinationURL: target)
    case "hardlink":
        try Data("null".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        #expect(link(target.path, fixture.setupDraftFile().path) == 0)
    case "directory":
        try FileManager.default.createDirectory(at: fixture.setupDraftFile(), withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    case "fifo": #expect(mkfifo(fixture.setupDraftFile().path, 0o600) == 0)
    default:
        try Data("null".utf8).write(to: fixture.setupDraftFile())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.setupDraftFile().path)
    }
    let store = fixture.store()
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.loadSetupDraft() }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.saveSetupDraft(diskSetupDraftFixture(), now: diskPendingNow) }
    #expect(fixture.reads == 0)
}

@Test func iMessageDiskSetupDraftBoundedWriteAndFailedClearPreserveExistingRecords() throws {
    let fixture = DiskCredentialFixture()
    let store = fixture.store(random: { fixture.nextProof() })
    _ = try prepareDiskPending(store)
    try store.save(credentialFixture())
    let draft = try diskSetupDraftFixture()
    try store.saveSetupDraft(draft, now: diskPendingNow)
    let original = try Data(contentsOf: fixture.setupDraftFile())
    let installed = try Data(contentsOf: fixture.file())
    let proof = try Data(contentsOf: fixture.pendingFile())
    let selected = try (1...32).map { try IMessageSetupDraft.Selection(nativeChatRowID: String($0), expectedGUID: String(repeating: "\\", count: 250) + String($0)) }
    let oversized = try diskSetupDraftFixture(selected: selected)
    #expect(try JSONEncoder().encode(oversized).count > 16_384)
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.saveSetupDraft(oversized, now: diskPendingNow) }
    #expect(try Data(contentsOf: fixture.setupDraftFile()) == original)
    // Darwin permission-failure coverage requires the normal non-root app-test
    // user. It is deliberately excluded from the portable Core harness.
    #expect(geteuid() != 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.clearSetupDraft(matching: draft) }
    #expect(try Data(contentsOf: fixture.setupDraftFile()) == original)
    #expect(try Data(contentsOf: fixture.file()) == installed)
    #expect(try Data(contentsOf: fixture.pendingFile()) == proof)
}
