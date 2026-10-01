import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private actor EnrollmentTransportFixture: DesktopControlEnrollmentTransport {
    struct Request: Equatable {
        let url: URL
        let body: Data
        let bearer: String?
    }

    private let response: Data
    private let status: Int
    private var requests: [Request] = []

    init(response: Data, status: Int = 201) {
        self.response = response
        self.status = status
    }

    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int) {
        requests.append(Request(url: url, body: body, bearer: bearer))
        return (response, status)
    }

    func recordedRequests() -> [Request] { requests }
}

private final class EnrollmentCredentialStoreFixture: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var installation: DesktopControlInstallation?

    func save(_ installation: DesktopControlInstallation) throws {
        lock.lock()
        defer { lock.unlock() }
        self.installation = installation
    }

    func load() throws -> DesktopControlInstallation? {
        lock.lock()
        defer { lock.unlock() }
        return installation
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        installation = nil
    }
}

private final class LegacyKeychainFixture: DesktopControlKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWrites = false
    var deniedAccounts: Set<String> = []
    var reads: [(account: String, interaction: DesktopControlKeychainInteraction)] = []

    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        reads.append((account, interaction))
        if deniedAccounts.contains(account) { throw DesktopControlEnrollmentError.credentialAccessRequired }
        return items["\(service):\(account)"]
    }

    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        items["\(service):\(account)"] = data
    }

    func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items.removeValue(forKey: "\(service):\(account)")
    }
}

private final class BlockingLegacyKeychainFixture: DesktopControlKeychainAccess, @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [String: Data] = [:]
    private var legacyReadStarted = false
    private var allowLegacyRead = false

    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if account == "installation" {
            legacyReadStarted = true
            condition.broadcast()
            while !allowLegacyRead { condition.wait() }
        }
        return items["\(service):\(account)"]
    }

    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        condition.lock()
        defer { condition.unlock() }
        items["\(service):\(account)"] = data
    }

    func remove(service: String, account: String) throws {
        condition.lock()
        defer { condition.unlock() }
        items.removeValue(forKey: "\(service):\(account)")
    }

    func waitForLegacyRead() {
        condition.lock()
        defer { condition.unlock() }
        while !legacyReadStarted { condition.wait() }
    }

    func continueLegacyRead() {
        condition.lock()
        defer { condition.unlock() }
        allowLegacyRead = true
        condition.broadcast()
    }
}

private final class CredentialConfigurationSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DesktopEnvironmentConfiguration

    init(_ value: DesktopEnvironmentConfiguration) { self.value = value }

    var current: DesktopEnvironmentConfiguration {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}

@Test func legacyCredentialIsNotReturnedWhenScopedSaveFails() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let legacyData = try legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    try keychain.write(legacyData, service: service, account: "installation")
    let store = KeychainDesktopControlCredentialStore(
        service: service, appURL: URL(string: "https://my.personastack.ai")!, keychain: keychain)
    keychain.failWrites = true

    #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try store.load() }
    #expect(try keychain.read(service: service, account: store.account) == nil)
    #expect(try keychain.read(service: service, account: "installation") == legacyData)
}

@Test func scopedKeychainItemMustMatchItsOriginBeforeUse() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let lanURL = URL(string: "https://personastack.ericgreer.info")!
    var lanInstallation = try JSONDecoder().decode(
        DesktopControlInstallation.self,
        from: legacyInstallationData(gateway: "ws://cluster-agent.personastack.lan/v1/desktop-control/ws"))
    try lanInstallation.bindEnvironment(lanURL)
    let store = KeychainDesktopControlCredentialStore(
        service: service, appURL: URL(string: "https://my.personastack.ai")!, keychain: keychain)
    try keychain.write(JSONEncoder().encode(lanInstallation), service: service, account: store.account)

    #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try store.load() }
    #expect(try keychain.read(service: service, account: store.account) != nil)
}

@Test func sameAppOriginKeepsDesktopEnrollmentsSeparateByGatewayAndMCP() throws {
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    let firstConfiguration = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai", gatewayURL: "https://cluster-agent.personastack.ai", mcpURL: "https://mcp.personastack.ai"
    )
    let secondConfiguration = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai/", gatewayURL: "https://gateway-alt.example", mcpURL: "https://mcp-alt.example"
    )
    let keychain = LegacyKeychainFixture()
    let firstCredentials = KeychainDesktopControlCredentialStore(
        service: "test.desktop-control", appURL: appURL, configuration: firstConfiguration, keychain: keychain
    )
    let secondCredentials = KeychainDesktopControlCredentialStore(
        service: "test.desktop-control", appURL: appURL, configuration: secondConfiguration, keychain: keychain
    )
    var first = try JSONDecoder().decode(
        DesktopControlInstallation.self,
        from: legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    )
    var second = try JSONDecoder().decode(
        DesktopControlInstallation.self,
        from: legacyInstallationData(gateway: "wss://gateway-alt.example/v1/desktop-control/ws")
    )
    try first.bindEnvironment(appURL, configuration: firstConfiguration)
    try second.bindEnvironment(appURL, configuration: secondConfiguration)
    try firstCredentials.save(first)
    try secondCredentials.save(second)

    #expect(firstCredentials.account != secondCredentials.account)
    #expect(try firstCredentials.load() == first)
    #expect(try secondCredentials.load() == second)
}

private func legacyInstallationData(gateway: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "installation_id": "legacy-mac",
        "machine_credential": Data(repeating: 0x42, count: 32).base64EncodedString(),
        "gateway_websocket_url": gateway,
    ])
}

@Test func legacyKeychainItemMigratesToMatchingOriginWithoutDeletingOriginal() throws {
    let keychain = LegacyKeychainFixture()
    let legacyData = try legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    let service = "test.desktop-control"
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    try keychain.write(legacyData, service: service, account: "installation")
    let store = KeychainDesktopControlCredentialStore(service: service, appURL: appURL, keychain: keychain)

    let migrated = try #require(try store.load())
    try migrated.requireEnvironment(appURL)
    #expect(migrated.installationID == "legacy-mac")
    #expect(try keychain.read(service: service, account: "installation") == legacyData)
    let scopedData = try #require(try keychain.read(service: service, account: store.account))
    #expect(try JSONDecoder().decode(DesktopControlInstallation.self, from: scopedData) == migrated)
    #expect(try store.load() == migrated)
}

@Test func legacyMigrationWritesToProfileCapturedBeforeKeychainRead() async throws {
    let keychain = BlockingLegacyKeychainFixture()
    let service = "test.desktop-control"
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    try keychain.write(
        legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws"),
        service: service,
        account: "installation"
    )
    let changed = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai",
        gatewayURL: "https://gateway-alt.example",
        mcpURL: "https://mcp-alt.example"
    )
    let selection = CredentialConfigurationSelection(.production)
    let store = KeychainDesktopControlCredentialStore(
        service: service,
        appURL: appURL,
        configurationProvider: { selection.current },
        keychain: keychain
    )

    let load = Task.detached { try store.load() }
    keychain.waitForLegacyRead()
    selection.current = changed
    keychain.continueLegacyRead()

    let migrated = try #require(try await load.value)
    try migrated.requireEnvironment(appURL, configuration: .production)
    #expect(try keychain.read(service: service, account: "installation:" + DesktopEnvironmentConfiguration.production.preferenceIdentity) != nil)
    #expect(try keychain.read(service: service, account: "installation:" + changed.preferenceIdentity) == nil)
}

@Test func legacyKeychainItemIsIgnoredByWrongOriginAndMigratesInItsOwnOrigin() throws {
    let keychain = LegacyKeychainFixture()
    let legacyData = try legacyInstallationData(gateway: "ws://cluster-agent.personastack.lan/v1/desktop-control/ws")
    let service = "test.desktop-control"
    try keychain.write(legacyData, service: service, account: "installation")
    let production = KeychainDesktopControlCredentialStore(
        service: service, appURL: URL(string: "https://my.personastack.ai")!, keychain: keychain)
    let lanURL = URL(string: "https://personastack.ericgreer.info")!
    let lan = KeychainDesktopControlCredentialStore(service: service, appURL: lanURL, keychain: keychain)

    #expect(try production.load() == nil)
    #expect(try keychain.read(service: service, account: production.account) == nil)
    let migrated = try #require(try lan.load())
    try migrated.requireEnvironment(lanURL)
    #expect(try keychain.read(service: service, account: "installation") == legacyData)
    #expect(try keychain.read(service: service, account: lan.account) != nil)
    try production.delete()
    #expect(try keychain.read(service: service, account: "installation") == legacyData)
    #expect(try lan.load() == migrated)
}

@Test func legacyProductionCredentialCannotMigrateIntoCustomAppOrigin() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let legacyData = try legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    try keychain.write(legacyData, service: service, account: "installation")
    let custom = try DesktopEnvironmentConfiguration(
        appURL: "https://custom.example", gatewayURL: "https://cluster-agent.personastack.ai", mcpURL: "https://mcp.personastack.ai"
    )
    let store = KeychainDesktopControlCredentialStore(
        service: service, appURL: custom.appURL, configuration: custom, keychain: keychain
    )

    #expect(try store.load() == nil)
    #expect(try keychain.read(service: service, account: store.account) == nil)
    #expect(try keychain.read(service: service, account: "installation") == legacyData)
}

@Test func originScopedCredentialMigratesAndDisconnectRemovesItsLegacyCopy() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let appURL = URL(string: "https://my.personastack.ai/user/personas")!
    let originScopedData = try legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    try keychain.write(originScopedData, service: service, account: "installation:https://my.personastack.ai")
    let store = KeychainDesktopControlCredentialStore(service: service, appURL: appURL, keychain: keychain)

    let installation = try #require(try store.load())
    try installation.requireEnvironment(appURL)
    #expect(try keychain.read(service: service, account: store.account) != nil)
    try store.delete()
    #expect(try store.load() == nil)
    #expect(try keychain.read(service: service, account: "installation:https://my.personastack.ai") == nil)
}

@Test func originScopedProductionCredentialDoesNotMigrateIntoCustomProfile() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let account = "installation:https://my.personastack.ai"
    let data = try legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    try keychain.write(data, service: service, account: account)
    let custom = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai", gatewayURL: "https://cluster-agent.personastack.ai", mcpURL: "https://mcp.custom.example"
    )
    let store = KeychainDesktopControlCredentialStore(
        service: service, appURL: custom.appURL, configuration: custom, keychain: keychain
    )

    #expect(try store.load() == nil)
    #expect(try keychain.read(service: service, account: store.account) == nil)
    #expect(try keychain.read(service: service, account: account) == data)
}

@Test func legacyCredentialWithDifferentBoundOriginCannotBeRebound() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    var installation = try JSONDecoder().decode(
        DesktopControlInstallation.self,
        from: legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws")
    )
    try installation.bindEnvironment(URL(string: "https://other.example")!, configuration: try DesktopEnvironmentConfiguration(
        appURL: "https://other.example", gatewayURL: "https://cluster-agent.personastack.ai", mcpURL: "https://mcp.personastack.ai"
    ))
    try keychain.write(JSONEncoder().encode(installation), service: service, account: "installation")
    let store = KeychainDesktopControlCredentialStore(
        service: service, appURL: URL(string: "https://my.personastack.ai")!, keychain: keychain
    )

    #expect(try store.load() == nil)
}

@Test func disconnectRemovesOnlyTheLegacyItemOwnedByThisOrigin() throws {
    let keychain = LegacyKeychainFixture()
    let service = "test.desktop-control"
    let appURL = URL(string: "https://my.personastack.ai")!
    let store = KeychainDesktopControlCredentialStore(service: service, appURL: appURL, keychain: keychain)
    try keychain.write(legacyInstallationData(gateway: "wss://cluster-agent.personastack.ai/v1/desktop-control/ws"),
                       service: service, account: "installation")
    #expect(try store.load() != nil)

    try store.delete()
    #expect(try store.load() == nil)
    #expect(try keychain.read(service: service, account: "installation") == nil)
    #expect(try keychain.read(service: service, account: store.account) == nil)
}

@Test func enrollmentUsesTheAppOriginAndStoresOneMachineIdentity() async throws {
    let credential = Data(repeating: 0x2A, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let response = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    let transport = EnrollmentTransportFixture(response: response)
    let credentials = EnrollmentCredentialStoreFixture()
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: credentials)
    let appURL = URL(string: "https://my.personastack.ai/user/personas?view=all")!

    let installation = try await client.enroll(ticket: "setup-ticket-1", appURL: appURL)
    #expect(installation.installationID == "install-1")
    #expect(try credentials.load() == installation)
    #expect(String(describing: installation).contains("<redacted>"))
    #expect(!String(reflecting: installation).contains(credential))

    let repeated = try await client.enroll(ticket: "different-ticket", appURL: appURL)
    #expect(repeated == installation)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.ai/v1/desktop-control/enroll")
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["enrollment_ticket": "setup-ticket-1"])
}

@Test func enrollmentRejectsInvalidGatewayURLAndCredentialWithoutSaving() async throws {
    let cases = [
        ("not-a-32-byte-secret", "wss://cluster-agent.personastack.ai/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "https://cluster-agent.example.test/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "wss://cluster-agent.example.test/other"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "wss://unrelated.example.test/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "ws://cluster-agent.personastack.ai/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "wss://cluster-agent.personastack.ai:444/v1/desktop-control/ws"),
    ]
    for (credential, gatewayURL) in cases {
        let response = try JSONSerialization.data(withJSONObject: [
            "installation_id": "install-1",
            "machine_credential": credential,
            "gateway_websocket_url": gatewayURL,
        ])
        let store = EnrollmentCredentialStoreFixture()
        let client = DesktopControlEnrollmentClient(transport: EnrollmentTransportFixture(response: response), credentials: store)
        await #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
            try await client.enroll(ticket: "setup-ticket", appURL: URL(string: "https://my.personastack.ai")!)
        }
        #expect(try store.load() == nil)
    }
}

@Test func storedInstallationRejectsGatewayChangedAfterEnvironmentBinding() throws {
    let credential = Data(repeating: 0x2B, count: 32).base64EncodedString()
    let stored = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://unrelated.example.test/v1/desktop-control/ws",
        "environment_origin": "https://my.personastack.ai",
    ])
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: stored)
    #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try installation.requireEnvironment(URL(string: "https://my.personastack.ai")!)
    }
}

@Test func gatewayConnectionRefusesUnboundInstallationBeforeOpeningSocket() async throws {
    let credential = Data(repeating: 0x2C, count: 32).base64EncodedString()
    let response = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: response)
    let connection = DesktopControlGatewayConnection(installation: installation) { _, _ in
        DesktopControlFrame(type: "result")
    }
    await #expect(throws: DesktopControlGatewayConnectionError.invalidURL) {
        try await connection.connect()
    }
}

@Test func readinessUsesTheMachineCredentialAtTheSameAppOrigin() async throws {
    let credential = Data(repeating: 0x31, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let encodedInstallation = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "ws://cluster-agent.personastack.lan/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())
    let appURL = URL(string: "https://personastack.ericgreer.info/user/personas")!

    try installation.bindEnvironment(appURL)
    try await client.reportReady(installation: installation, appURL: appURL)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://personastack.ericgreer.info/v1/desktop-control/ready")
    #expect(requests.first?.bearer == credential)
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["installation_id": "install-1", "readiness": "ready"])
}

@Test func relayStateUsesTheMachineCredentialAndReturnsOnlyTheActiveConfigBit() async throws {
    let credentialBytes = Data(repeating: 0x4A, count: 32)
    let credential = credentialBytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let payload = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-relay-state",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let appURL = URL(string: "https://my.personastack.ai/user/desktop-control")!
    try installation.bindEnvironment(appURL)
    let response = try JSONSerialization.data(withJSONObject: ["has_active_config": false, "has_config": false])
    let transport = EnrollmentTransportFixture(response: response, status: 200)
    let client = DesktopControlEnrollmentClient(transport: transport)

    let hasActiveConfig = try await client.hasActiveConfig(installation: installation, appURL: appURL)

    #expect(!hasActiveConfig)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests[0].url.absoluteString == "https://my.personastack.ai/v1/desktop-control/ready")
    #expect(requests[0].bearer == credential)
    let body = try #require(JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
    #expect(body["installation_id"] as? String == installation.installationID)
    #expect(body["validate_only"] as? Bool == true)
    #expect(body["relay_state_only"] as? Bool == true)
    #expect(Set(body.keys) == Set(["installation_id", "validate_only", "relay_state_only"]))
}

@Test func relayStateRejectsWrongOriginsMalformedBodiesAndUnexpectedStatus() async throws {
    let credentialBytes = Data(repeating: 0x4B, count: 32)
    let credential = credentialBytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let payload = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-relay-state",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    let appURL = URL(string: "https://personastack.ericgreer.info")!
    let transport = EnrollmentTransportFixture(response: Data("{}".utf8), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport)

    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await client.hasActiveConfig(installation: installation, appURL: appURL)
    }

    #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try installation.bindEnvironment(appURL)
    }
    await #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try await client.hasActiveConfig(installation: installation, appURL: URL(string: "https://my.personastack.ai")!)
    }
}

@Test func setupReferenceAttachesToAnExistingMachineWithoutReplacingItsCredential() async throws {
    let credential = Data(repeating: 0x41, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let encodedInstallation = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())

    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    try await client.attach(ticket: "setup-ticket-second-user", installation: installation, appURL: URL(string: "https://my.personastack.ai")!)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.ai/v1/desktop-control/attach")
    #expect(requests.first?.bearer == credential)
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["installation_id": "install-1", "enrollment_ticket": "setup-ticket-second-user"])
}

@Test func revocationUsesTheMachineCredentialAndInstallationIdentity() async throws {
    let credential = Data(repeating: 0x55, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let encodedInstallation = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.personastack.ai/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())

    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    try await client.revokeRemote(installation: installation, appURL: URL(string: "https://my.personastack.ai/user/personas")!)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.ai/v1/desktop-control/revoke")
    #expect(requests.first?.bearer == credential)
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["installation_id": "install-1"])
}

@Test func revocationUsesTheConfiguredPersonaStackServiceOrigin() async throws {
    let credential = Data(repeating: 0x66, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let data = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "ws://cluster-agent.personastack.lan/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())
    let serviceURL = LaunchConfiguration.url(
        arguments: ["PersonaStack", "--personastack-url", "https://personastack.ericgreer.info/user/personas"],
        packagedDefaultURL: "https://my.personastack.ai/user/personas"
    )

    try installation.bindEnvironment(serviceURL)
    try await client.revokeRemote(installation: installation, appURL: serviceURL)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://personastack.ericgreer.info/v1/desktop-control/revoke")
    #expect(requests.first?.bearer == credential)
}

@Test func enrollmentCredentialsCannotCrossEnvironmentOrigins() async throws {
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())
    let data = try JSONSerialization.data(withJSONObject: [
        "installation_id": "machine", "machine_credential": Data(repeating: 1, count: 32).base64EncodedString(),
        "gateway_websocket_url": "ws://cluster-agent.personastack.lan/v1/desktop-control/ws",
    ])
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
    try installation.bindEnvironment(URL(string: "https://personastack.ericgreer.info")!)
    let production = URL(string: "https://my.personastack.ai")!
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try await client.reportReady(installation: installation, appURL: production) }
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try await client.attach(ticket: "ticket", installation: installation, appURL: production) }
    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try await client.revokeRemote(installation: installation, appURL: production) }
    #expect(await transport.recordedRequests().isEmpty)
    #expect(KeychainDesktopControlCredentialStore(appURL: production).account != KeychainDesktopControlCredentialStore(appURL: URL(string: "https://personastack.ericgreer.info")!).account)
    #expect(try DesktopControlEnvironment.origin(URL(string: "https://MY.personastack.ai:443/user/personas")!) == "https://my.personastack.ai")
}

@Test func desktopControlAcceptsCanonicalLANOriginAndRejectsRetiredOrigin() {
    let gateway = URL(string: "ws://cluster-agent.personastack.lan/v1/desktop-control/ws")!
    #expect(DesktopControlEnvironment.allowsGateway(gateway, for: "https://personastack.ericgreer.info"))
    #expect(!DesktopControlEnvironment.allowsGateway(gateway, for: "http://my.personastack.lan"))
    #expect(!DesktopControlEnvironment.allowsGateway(gateway, for: "http://personastack.ericgreer.info"))
    #expect(!DesktopControlEnvironment.allowsGateway(gateway, for: "https://my.personastack.ai"))
}

@Test func authenticatedDesktopRequestsRejectEveryRedirect() {
    let session = URLSession.shared
    let task = session.dataTask(with: URL(string: "https://source.example/secure")!)
    let blocker = DesktopControlRedirectBlocker()
    var redirectedRequest: URLRequest?
    blocker.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://source.example/secure")!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
        newRequest: URLRequest(url: URL(string: "https://other.example/secure")!),
        completionHandler: { redirectedRequest = $0 }
    )

    #expect(redirectedRequest == nil)
}

@Test func retiredLANOriginCannotSendAnEnrollmentTicket() async {
    let transport = EnrollmentTransportFixture(response: Data())
    let client = DesktopControlEnrollmentClient(
        transport: transport,
        credentials: EnrollmentCredentialStoreFixture()
    )

    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await client.enroll(
            ticket: "setup-ticket",
            appURL: URL(string: "http://my.personastack.lan/user/personas")!
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test func originScopedCredentialMigratesWithoutReadingDeniedOldestItem() throws {
    let keychain = LegacyKeychainFixture()
    let service = "fixture"
    let configuration = DesktopEnvironmentConfiguration.production
    let originAccount = "installation:" + configuration.appOrigin
    let data = try legacyInstallationData(gateway: configuration.gatewayWebsocketURL.absoluteString)
    try keychain.write(data, service: service, account: originAccount)
    keychain.deniedAccounts = ["installation"]
    let store = KeychainDesktopControlCredentialStore(service: service, configuration: configuration, keychain: keychain)

    let migrated = try #require(try store.load())
    #expect(migrated.installationID == "legacy-mac")
    #expect(keychain.reads.map(\.account) == [store.account, originAccount])
    #expect(keychain.reads.allSatisfy { $0.interaction == .forbidden })
    #expect(try store.load() == migrated)
}

@Test func deniedCurrentOrOriginCredentialNeverFallsBackToOlderIdentity() throws {
    for currentItem in [false, true] {
        let keychain = LegacyKeychainFixture()
        let configuration = DesktopEnvironmentConfiguration.production
        let store = KeychainDesktopControlCredentialStore(service: "fixture", configuration: configuration, keychain: keychain)
        keychain.deniedAccounts = [currentItem ? store.account : "installation:" + configuration.appOrigin]
        try keychain.write(legacyInstallationData(gateway: configuration.gatewayWebsocketURL.absoluteString),
                           service: "fixture", account: "installation")
        #expect(throws: DesktopControlEnrollmentError.credentialAccessRequired) { try store.load() }
        #expect(!keychain.reads.contains { $0.account == "installation" })
    }
}

@Test func explicitKeychainRecoveryUsesSameScopedCredentialAndLeavesPassiveLoadsPassive() throws {
    let keychain = LegacyKeychainFixture()
    let configuration = DesktopEnvironmentConfiguration.production
    let store = KeychainDesktopControlCredentialStore(service: "fixture", configuration: configuration, keychain: keychain)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from:
        legacyInstallationData(gateway: configuration.gatewayWebsocketURL.absoluteString))
    try installation.bindEnvironment(configuration.appPageURL, configuration: configuration)
    try store.save(installation)
    #expect(try store.loadWithUserInteraction() == installation)
    #expect(try store.load() == installation)
    #expect(keychain.reads.map(\.account) == [store.account, store.account])
    #expect(keychain.reads.map(\.interaction) == [.allowed, .forbidden])
}
