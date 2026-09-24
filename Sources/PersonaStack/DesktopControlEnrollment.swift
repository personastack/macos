import Foundation
import Security

struct DesktopControlInstallation: Codable, Equatable, Sendable {
    let installationID: String
    let machineCredential: String
    let gatewayWebsocketURL: URL

    enum CodingKeys: String, CodingKey {
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
        self.installationID = installationID
        self.machineCredential = machineCredential
        self.gatewayWebsocketURL = gatewayURL
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

enum DesktopControlEnrollmentError: Error, Equatable {
    case invalidRequest
    case rejected
    case invalidResponse
    case credentialStoreUnavailable
    case serviceRegistrationFailed
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

struct KeychainDesktopControlCredentialStore: DesktopControlCredentialStoring {
    private let service: String
    private let account = "installation"

    init(service: String = "ai.personastack.desktop-control") {
        self.service = service
    }

    func save(_ installation: DesktopControlInstallation) throws {
        let data = try JSONEncoder().encode(installation)
        let query = baseQuery
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

    func load() throws -> DesktopControlInstallation? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let installation = try? JSONDecoder().decode(DesktopControlInstallation.self, from: data) else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        return installation
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

protocol DesktopControlEnrollmentTransport: Sendable {
    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int)
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

actor DesktopControlEnrollmentClient {
    private let transport: any DesktopControlEnrollmentTransport
    private let credentials: any DesktopControlCredentialStoring

    init(transport: any DesktopControlEnrollmentTransport = URLSessionDesktopControlEnrollmentTransport(), credentials: any DesktopControlCredentialStoring = KeychainDesktopControlCredentialStore()) {
        self.transport = transport
        self.credentials = credentials
    }

    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)? = nil
    ) async throws -> DesktopControlInstallation {
        if let existing = try credentials.load() { return existing }
        guard !ticket.isEmpty, ticket.utf8.count <= 512,
              let endpoint = Self.enrollmentURL(appURL) else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["enrollment_ticket": ticket])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: nil)
        guard status == 201, data.count <= 4096 else {
            throw DesktopControlEnrollmentError.rejected
        }
        let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: data)
        if let commitCredential { try await commitCredential(installation) }
        else { try credentials.save(installation) }
        return installation
    }

    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws {
        guard let endpoint = Self.endpoint(appURL, path: "/v1/desktop-control/ready") else {
            throw DesktopControlEnrollmentError.invalidRequest
        }
        let body = try JSONSerialization.data(withJSONObject: ["installation_id": installation.installationID, "readiness": "ready"])
        let (data, status) = try await transport.post(url: endpoint, body: body, bearer: installation.machineCredential)
        guard status == 204, data.isEmpty else { throw DesktopControlEnrollmentError.rejected }
    }

    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws {
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
