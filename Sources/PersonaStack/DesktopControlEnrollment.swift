import Foundation
import Security
import PersonaStackCore

struct DesktopControlInstallation: Codable, Equatable, Sendable {
    let installationID: String
    let machineCredential: String
    let gatewayWebsocketURL: URL
    private(set) var environmentOrigin: String?

    enum CodingKeys: String, CodingKey {
        case environmentOrigin = "environment_origin"
        case installationID = "installation_id"
        case machineCredential = "machine_credential"
        case gatewayWebsocketURL = "gateway_websocket_url"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let installationID = try values.decode(String.self, forKey: .installationID)
        let machineCredential = try values.decode(String.self, forKey: .machineCredential)
        let gatewayURLString = try values.decode(String.self, forKey: .gatewayWebsocketURL)
        guard !installationID.isEmpty,
              let credential = Self.decodeCredential(machineCredential), credential.count == 32,
              let gatewayURL = URL(string: gatewayURLString), Self.validGatewayURL(gatewayURL) else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        let environmentOrigin = try values.decodeIfPresent(String.self, forKey: .environmentOrigin)
        self.environmentOrigin = environmentOrigin
        self.installationID = installationID
        self.machineCredential = machineCredential
        self.gatewayWebsocketURL = gatewayURL
    }

    mutating func bindEnvironment(_ appURL: URL, configuration: DesktopEnvironmentConfiguration? = nil) throws {
        let origin = try DesktopControlEnvironment.origin(appURL)
        guard DesktopControlEnvironment.allowsGateway(gatewayWebsocketURL, for: origin, configuration: configuration) else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        environmentOrigin = origin
    }

    func requireEnvironment(_ appURL: URL, configuration: DesktopEnvironmentConfiguration? = nil) throws {
        guard environmentOrigin == (try DesktopControlEnvironment.origin(appURL)),
              let environmentOrigin,
              DesktopControlEnvironment.allowsGateway(gatewayWebsocketURL, for: environmentOrigin, configuration: configuration) else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
    }

    func requireBoundGateway() throws {
        guard let environmentOrigin,
              DesktopControlEnvironment.allowsGateway(gatewayWebsocketURL, for: environmentOrigin) else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
    }

    private static func decodeCredential(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func validGatewayURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return ["ws", "wss"].contains(components.scheme?.lowercased() ?? "")
            && components.host != nil
            && components.user == nil
            && components.password == nil
            && components.path == "/v1/desktop-control/ws"
            && components.query == nil
            && components.fragment == nil
    }
}

extension DesktopControlInstallation: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "DesktopControlInstallation(installationID: \(installationID), machineCredential: <redacted>, gatewayWebsocketURL: \(gatewayWebsocketURL))"
    }

    var debugDescription: String { description }
}

enum DesktopControlEnrollmentError: Error, Equatable {
    case invalidRequest
    case rejected
    case invalidResponse
    case credentialStoreUnavailable
    case credentialAccessRequired
    case installationMissing
    case nativeCapabilitiesUnavailable
    case revocationFailed
}

extension DesktopControlEnrollmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Desktop Control setup request is invalid or expired. Refresh the setup page and retry."
        case .rejected:
            "Desktop Control could not enroll this installation. Refresh setup to request a new ticket, then retry."
        case .invalidResponse:
            "The server returned an invalid Desktop Control enrollment response."
        case .credentialStoreUnavailable:
            "PersonaStack could not read or save this Mac's Desktop Control credential. Check local storage access and retry."
        case .credentialAccessRequired:
            "The previous Desktop Control credential cannot be read. Set up this Mac again while signed in to PersonaStack."
        case .installationMissing:
            "This Mac has no Desktop Control enrollment. Open PersonaStack and set up Desktop Control again."
        case .nativeCapabilitiesUnavailable:
            "PersonaStack could not verify local file access and streaming shell execution. Check macOS permissions and retry."
        case .revocationFailed:
            "PersonaStack could not revoke this desktop connection. Remote control remains paused. Check the connection and retry."
        }
    }
}

protocol DesktopControlCredentialStoring: Sendable {
    func save(_ installation: DesktopControlInstallation) throws
    func load() throws -> DesktopControlInstallation?
    func loadWithUserInteraction() throws -> DesktopControlInstallation?
    func delete() throws
}

extension DesktopControlCredentialStoring {
    func loadWithUserInteraction() throws -> DesktopControlInstallation? { try load() }
}

enum DesktopControlEnvironment {
    static func supportsAppOrigin(_ appURL: URL) -> Bool {
        return (try? DesktopEnvironmentConfigurationStore.shared.environment(for: appURL)) != nil
    }

    static func allowsGateway(_ gatewayURL: URL, for origin: String,
                              configuration suppliedConfiguration: DesktopEnvironmentConfiguration? = nil) -> Bool {
        guard let appURL = URL(string: origin),
              let configuration = suppliedConfiguration ?? (try? DesktopEnvironmentConfigurationStore.shared.environment(for: appURL)),
              configuration.appOrigin == origin else { return false }
        return sameEndpoint(gatewayURL, configuration.gatewayWebsocketURL)
    }

    static func sameEndpoint(_ actual: URL, _ expected: URL) -> Bool {
        guard let actualParts = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              let expectedParts = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { return false }
        return actualParts.scheme?.lowercased() == expectedParts.scheme?.lowercased()
            && actualParts.host?.lowercased() == expectedParts.host?.lowercased()
            && actualParts.port == expectedParts.port
            && actualParts.path == expectedParts.path
            && actualParts.user == nil && actualParts.password == nil
            && actualParts.query == nil && actualParts.fragment == nil
    }

    static func origin(_ appURL: URL) throws -> String {
        guard let parts = URLComponents(url: appURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = parts.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }
}

enum DesktopControlKeychainInteraction: Sendable {
    case forbidden, allowed
}

protocol DesktopControlKeychainAccess: Sendable {
    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data?
    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws
    func remove(service: String, account: String) throws
}

extension DesktopControlKeychainAccess {
    func read(service: String, account: String) throws -> Data? {
        try read(service: service, account: account, interaction: .forbidden)
    }

    func write(_ data: Data, service: String, account: String) throws {
        try write(data, service: service, account: account, interaction: .forbidden)
    }
}

final class DesktopControlRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DesktopControlRedirectBlocker()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DesktopControlNetworkSession {
    static func makeWithoutRedirects(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        URLSession(configuration: configuration, delegate: DesktopControlRedirectBlocker.shared, delegateQueue: nil)
    }
}

/// The login Keychain uses SecAccess ACLs. Data-protection query flags do not
/// disable its authorization UI, so all direct calls share the interaction gate.
protocol DesktopControlKeychainSecurity: Sendable {
    func interactionAllowed() -> (OSStatus, Bool)
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemDesktopControlKeychainSecurity: DesktopControlKeychainSecurity {
    func interactionAllowed() -> (OSStatus, Bool) {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }

    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct SystemDesktopControlKeychainAccess: DesktopControlKeychainAccess {
    private static let interactionLock = NSLock()
    private let security: any DesktopControlKeychainSecurity

    init(security: any DesktopControlKeychainSecurity = SystemDesktopControlKeychainSecurity()) {
        self.security = security
    }

    func read(service: String, account: String, interaction: DesktopControlKeychainInteraction) throws -> Data? {
        try withInteraction(interaction) {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = kCFBooleanTrue
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = security.copyMatching(query)
            if status == errSecItemNotFound { return nil }
            try requireSuccess(status)
            guard let data else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
            return data
        }
    }

    func write(_ data: Data, service: String, account: String, interaction: DesktopControlKeychainInteraction) throws {
        try withInteraction(interaction) {
            let query = baseQuery(service: service, account: account)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = security.update(query, attributes: attributes)
            if status == errSecItemNotFound {
                var item = query
                attributes.forEach { item[$0.key] = $0.value }
                // Omit kSecAttrAccess to keep the default creator-only ACL. The
                // persistent release signature identifies this app across updates.
                try requireSuccess(security.add(item))
                return
            }
            try requireSuccess(status)
        }
    }

    func remove(service: String, account: String) throws {
        try withInteraction(.forbidden) {
            let status = security.delete(baseQuery(service: service, account: account))
            if status != errSecItemNotFound { try requireSuccess(status) }
        }
    }

    private func withInteraction<T>(_ interaction: DesktopControlKeychainInteraction,
                                    operation: () throws -> T) throws -> T {
        // SecKeychain's interaction setting is process-global. Serialize our
        // reads AND writes so a page load cannot borrow a menu action's grant.
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        let (status, previous) = security.interactionAllowed()
        try requireSuccess(status)
        let result = Result {
            try requireSuccess(security.setInteractionAllowed(interaction == .allowed))
            return try operation()
        }
        try requireSuccess(security.setInteractionAllowed(previous))
        return try result.get()
    }

    private func requireSuccess(_ status: OSStatus) throws {
        if status == errSecSuccess { return }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw DesktopControlEnrollmentError.credentialAccessRequired
        }
        throw DesktopControlEnrollmentError.credentialStoreUnavailable
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

struct KeychainDesktopControlCredentialStore: DesktopControlCredentialStoring {
    private let service: String
    private let appURLOverride: URL?
    private let configurationOverride: DesktopEnvironmentConfiguration?
    private let configurationProvider: (@Sendable () -> DesktopEnvironmentConfiguration)?
    private let keychain: any DesktopControlKeychainAccess
    var account: String {
        (try? credentialContext().account) ?? "installation:invalid"
    }

    init(service: String = "ai.personastack.desktop-control", appURL: URL? = nil,
         configuration: DesktopEnvironmentConfiguration? = nil,
         configurationProvider: (@Sendable () -> DesktopEnvironmentConfiguration)? = nil,
         keychain: any DesktopControlKeychainAccess = SystemDesktopControlKeychainAccess()) {
        self.service = service
        self.appURLOverride = appURL
        self.configurationOverride = configuration
        self.configurationProvider = configurationProvider
        self.keychain = keychain
    }

    func save(_ installation: DesktopControlInstallation) throws {
        let context = try credentialContext()
        try keychain.write(JSONEncoder().encode(installation), service: service, account: context.account)
    }

    func load() throws -> DesktopControlInstallation? {
        try load(interaction: .forbidden)
    }

    func loadWithUserInteraction() throws -> DesktopControlInstallation? {
        try load(interaction: .allowed)
    }

    /// Disk migration reads the old identity without writing another Keychain
    /// item or asking macOS to authorize access.
    func loadForMigration() throws -> DesktopControlInstallation? {
        try load(interaction: .forbidden, migrateInKeychain: false)
    }

    private func load(interaction: DesktopControlKeychainInteraction,
                      migrateInKeychain: Bool = true) throws -> DesktopControlInstallation? {
        let context = try credentialContext()
        if let data = try keychain.read(service: service, account: context.account, interaction: interaction) {
            guard let installation = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data) else {
                throw DesktopControlEnrollmentError.credentialStoreUnavailable
            }
            try installation.requireEnvironment(context.appURL, configuration: context.configuration)
            return installation
        }
        guard var legacy = try matchingOriginScopedInstallation(configuration: context.configuration, interaction: interaction)
            ?? matchingLegacyInstallation(configuration: context.configuration, appURL: context.appURL, interaction: interaction) else { return nil }
        try legacy.bindEnvironment(context.appURL, configuration: context.configuration)
        if migrateInKeychain {
            try keychain.write(JSONEncoder().encode(legacy), service: service, account: context.account, interaction: interaction)
        }
        return legacy
    }

    func delete() throws {
        let context = try credentialContext()
        // A migrated legacy credential must not reappear after an explicit
        // disconnect. An item owned by the other environment is untouched.
        if try matchingLegacyInstallation(configuration: context.configuration, appURL: context.appURL) != nil {
            try keychain.remove(service: service, account: "installation")
        }
        if try matchingOriginScopedInstallation(configuration: context.configuration) != nil {
            try keychain.remove(service: service, account: "installation:" + context.configuration.appOrigin)
        }
        try keychain.remove(service: service, account: context.account)
    }

    private func credentialContext() throws -> (appURL: URL, configuration: DesktopEnvironmentConfiguration, account: String) {
        let appURL: URL
        let configuration: DesktopEnvironmentConfiguration
        if let configurationOverride {
            configuration = configurationOverride
            appURL = appURLOverride ?? configuration.appPageURL
        } else if let configurationProvider {
            configuration = configurationProvider()
            appURL = appURLOverride ?? configuration.appPageURL
        } else if let appURLOverride {
            appURL = appURLOverride
            guard let selected = try? DesktopEnvironmentConfigurationStore.shared.environment(for: appURL) else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
            configuration = selected
        } else {
            guard let selected = try? LaunchConfiguration.selectedEnvironment() else {
                throw DesktopControlEnrollmentError.invalidRequest
            }
            configuration = selected
            appURL = selected.appPageURL
        }
        guard (try? DesktopControlEnvironment.origin(appURL)) == configuration.appOrigin else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        return (appURL, configuration, "installation:" + configuration.preferenceIdentity)
    }

    private func matchingLegacyInstallation(configuration: DesktopEnvironmentConfiguration,
                                            appURL: URL, interaction: DesktopControlKeychainInteraction = .forbidden) throws -> DesktopControlInstallation? {
        // The oldest build used one account for every environment. Only its
        // original production and LAN service pairs can identify ownership.
        guard configuration == .production || configuration == .lan,
              let origin = try? DesktopControlEnvironment.origin(appURL), origin == configuration.appOrigin,
              let data = try keychain.read(service: service, account: "installation", interaction: interaction),
              let legacy = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data),
              legacy.environmentOrigin == nil || legacy.environmentOrigin == origin,
              DesktopControlEnvironment.allowsGateway(legacy.gatewayWebsocketURL, for: origin, configuration: configuration) else {
            return nil
        }
        return legacy
    }

    private func matchingOriginScopedInstallation(configuration: DesktopEnvironmentConfiguration,
                                                   interaction: DesktopControlKeychainInteraction = .forbidden) throws -> DesktopControlInstallation? {
        let origin = configuration.appOrigin
        guard configuration == .production || configuration == .lan,
              let data = try keychain.read(service: service, account: "installation:" + origin, interaction: interaction),
              let installation = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data),
              installation.environmentOrigin == nil || installation.environmentOrigin == origin,
              DesktopControlEnvironment.allowsGateway(installation.gatewayWebsocketURL, for: origin, configuration: configuration) else {
            return nil
        }
        return installation
    }
}

protocol DesktopControlEnrollmentTransport: Sendable {
    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int)
}

protocol DesktopControlRelayStateReading: Sendable {
    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool
}

actor URLSessionDesktopControlEnrollmentTransport: DesktopControlEnrollmentTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? DesktopControlNetworkSession.makeWithoutRedirects()
    }

    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { return (Data(), 0) }
        return (data, response.statusCode)
    }
}

struct DesktopControlConfigurationState: Decodable, Sendable {
    let hasActiveConfig: Bool
    let hasConfig: Bool

    enum CodingKeys: String, CodingKey {
        case hasActiveConfig = "has_active_config"
        case hasConfig = "has_config"
    }
}

actor DesktopControlEnrollmentClient: DesktopControlRelayStateReading {
    private let transport: any DesktopControlEnrollmentTransport
    private let credentials: (any DesktopControlCredentialStoring)?

    init(transport: any DesktopControlEnrollmentTransport = URLSessionDesktopControlEnrollmentTransport(), credentials: (any DesktopControlCredentialStoring)? = nil) {
        self.transport = transport
        self.credentials = credentials
    }

    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)? = nil
    ) async throws -> DesktopControlInstallation {
        guard DesktopControlEnvironment.supportsAppOrigin(appURL) else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let credentials = credentials ?? FileDesktopControlCredentialStore(appURL: appURL)
        if let existing = try credentials.load() {
            try existing.requireEnvironment(appURL)
            return existing
        }
        guard !ticket.isEmpty, ticket.utf8.count <= 512,
              let endpoint = Self.enrollmentURL(appURL) else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["enrollment_ticket": ticket])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: nil)
        guard status == 201, data.count <= 4096 else {
            throw DesktopControlEnrollmentError.rejected
        }
        var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
        try installation.bindEnvironment(appURL)
        if let commitCredential { try await commitCredential(installation) }
        else { try credentials.save(installation) }
        return installation
    }

    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws {
        try installation.requireEnvironment(appURL)
        guard let endpoint = Self.endpoint(appURL, path: "/v1/desktop-control/ready") else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["installation_id": installation.installationID, "readiness": "ready"])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: installation.machineCredential)
        guard status == 204, data.isEmpty else { throw DesktopControlEnrollmentError.rejected }
    }

    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool {
        try await configurationState(installation: installation, appURL: appURL).hasActiveConfig
    }

    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        try installation.requireEnvironment(appURL)
        guard let endpoint = Self.endpoint(appURL, path: "/v1/desktop-control/ready") else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "installation_id": installation.installationID,
            "validate_only": true,
            "relay_state_only": true,
        ])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: installation.machineCredential)
        guard status == 200, data.count <= 1024 else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        guard let state = try? JSONDecoder().decode(DesktopControlConfigurationState.self, from: data),
              !state.hasActiveConfig || state.hasConfig else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        return state
    }

    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws {
        try installation.requireEnvironment(appURL)
        guard !ticket.isEmpty, ticket.utf8.count <= 512,
              let endpoint = Self.endpoint(appURL, path: "/v1/desktop-control/attach") else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "enrollment_ticket": ticket,
            "installation_id": installation.installationID,
        ])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: installation.machineCredential)
        guard status == 204, data.isEmpty else { throw DesktopControlEnrollmentError.rejected }
    }

    func revokeRemote(installation: DesktopControlInstallation, appURL: URL) async throws {
        try installation.requireEnvironment(appURL)
        guard let endpoint = Self.endpoint(appURL, path: "/v1/desktop-control/revoke") else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["installation_id": installation.installationID])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: installation.machineCredential)
        guard status == 204, data.isEmpty else { throw DesktopControlEnrollmentError.revocationFailed }
    }

    private static func enrollmentURL(_ appURL: URL) -> URL? {
		endpoint(appURL, path: "/v1/desktop-control/enroll")
	}

	private static func endpoint(_ appURL: URL, path: String) -> URL? {
        guard let components = URLComponents(url: appURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        var endpoint = components
        endpoint.path = path
        endpoint.query = nil
        endpoint.fragment = nil
        return endpoint.url
    }
}
