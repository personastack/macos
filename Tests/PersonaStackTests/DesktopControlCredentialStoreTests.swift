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
    var reads: Int { lock.withLock { count } }
    func recordRead() { lock.withLock { count += 1 } }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func file(_ configuration: DesktopEnvironmentConfiguration = .production) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(configuration.preferenceIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined() + ".json")
    }
    func store(_ configuration: DesktopEnvironmentConfiguration = .production,
               legacy: @escaping @Sendable () throws -> DesktopControlInstallation? = { nil }) -> FileDesktopControlCredentialStore {
        FileDesktopControlCredentialStore(directory: directory, configurationProvider: { configuration }, legacyLoader: { _ in
            self.recordRead()
            return try legacy()
        })
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
