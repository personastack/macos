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
        if let environmentOrigin,
           !DesktopControlEnvironment.allowsGateway(gatewayURL, for: environmentOrigin) {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        self.environmentOrigin = environmentOrigin
        self.installationID = installationID
        self.machineCredential = machineCredential
        self.gatewayWebsocketURL = gatewayURL
    }

    mutating func bindEnvironment(_ appURL: URL) throws {
        let origin = try DesktopControlEnvironment.origin(appURL)
        guard DesktopControlEnvironment.allowsGateway(gatewayWebsocketURL, for: origin) else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        environmentOrigin = origin
    }

    func requireEnvironment(_ appURL: URL) throws {
        guard environmentOrigin == (try DesktopControlEnvironment.origin(appURL)),
              let environmentOrigin,
              DesktopControlEnvironment.allowsGateway(gatewayWebsocketURL, for: environmentOrigin) else {
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
    case serviceRegistrationFailed
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
            "macOS Keychain could not store the Desktop Control installation. Check Keychain access and retry."
        case .serviceRegistrationFailed:
            "PersonaStack could not register its background login service. Check Login Items settings and retry."
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
    func delete() throws
}

enum DesktopControlEnvironment {
    private static let gatewayPath = "/v1/desktop-control/ws"

    static func allowsGateway(_ gatewayURL: URL, for origin: String) -> Bool {
        let expected: (scheme: String, host: String)
        switch origin {
        case "https://my.personastack.ai":
            expected = ("wss", "cluster-agent.personastack.ai")
        case "http://my.personastack.lan":
            expected = ("ws", "cluster-agent.personastack.lan")
        default:
            return false
        }
        guard let parts = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false) else { return false }
        let defaultPort = expected.scheme == "wss" ? 443 : 80
        return parts.scheme?.lowercased() == expected.scheme
            && parts.host?.lowercased() == expected.host
            && (parts.port == nil || parts.port == defaultPort)
            && parts.user == nil && parts.password == nil
            && parts.path == gatewayPath && parts.query == nil && parts.fragment == nil
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

protocol DesktopControlKeychainAccess: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

struct SystemDesktopControlKeychainAccess: DesktopControlKeychainAccess {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw DesktopControlEnrollmentError.credentialStoreUnavailable
            }
            return
        }
        guard status == errSecSuccess else { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
    }

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

struct KeychainDesktopControlCredentialStore: DesktopControlCredentialStoring {
    private let service: String
    private let appURL: URL
    private let keychain: any DesktopControlKeychainAccess
    let account: String

    init(service: String = "ai.personastack.desktop-control", appURL: URL = LaunchConfiguration.url(),
         keychain: any DesktopControlKeychainAccess = SystemDesktopControlKeychainAccess()) {
        self.service = service
        self.appURL = appURL
        self.keychain = keychain
        self.account = "installation:" + ((try? DesktopControlEnvironment.origin(appURL)) ?? "invalid")
    }

    func save(_ installation: DesktopControlInstallation) throws {
        try keychain.write(JSONEncoder().encode(installation), service: service, account: account)
    }

    func load() throws -> DesktopControlInstallation? {
        if let data = try keychain.read(service: service, account: account) {
            guard let installation = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data) else {
                throw DesktopControlEnrollmentError.credentialStoreUnavailable
            }
            try installation.requireEnvironment(appURL)
            return installation
        }
        guard var legacy = try matchingLegacyInstallation() else { return nil }
        try legacy.bindEnvironment(appURL)
        try save(legacy)
        return legacy
    }

    func delete() throws {
        // A migrated legacy credential must not reappear after an explicit
        // disconnect. An item owned by the other environment is untouched.
        if try matchingLegacyInstallation() != nil {
            try keychain.remove(service: service, account: "installation")
        }
        try keychain.remove(service: service, account: account)
    }

    private func matchingLegacyInstallation() throws -> DesktopControlInstallation? {
        // Older builds used one account for every environment. Its gateway is
        // the only safe evidence of which official origin owns the item.
        guard let origin = try? DesktopControlEnvironment.origin(appURL),
              let data = try keychain.read(service: service, account: "installation"),
              let legacy = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data),
              DesktopControlEnvironment.allowsGateway(legacy.gatewayWebsocketURL, for: origin) else {
            return nil
        }
        return legacy
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

    init(session: URLSession = .shared) {
        self.session = session
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
        let credentials = credentials ?? KeychainDesktopControlCredentialStore(appURL: appURL)
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
        guard status == 200, data.count <= 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["has_active_config"],
              let hasActiveConfig = object["has_active_config"] as? Bool else {
            throw DesktopControlEnrollmentError.invalidResponse
        }
        return hasActiveConfig
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
