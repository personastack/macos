import Foundation
import Testing
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

@Test func enrollmentUsesTheAppOriginAndStoresOneMachineIdentity() async throws {
    let credential = Data(repeating: 0x2A, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let response = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.example.test/v1/desktop-control/ws",
    ])
    let transport = EnrollmentTransportFixture(response: response)
    let credentials = EnrollmentCredentialStoreFixture()
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: credentials)
    let appURL = URL(string: "https://my.personastack.test/user/personas?view=all")!

    let installation = try await client.enroll(ticket: "setup-ticket-1", appURL: appURL)
    #expect(installation.installationID == "install-1")
    #expect(try credentials.load() == installation)

    let repeated = try await client.enroll(ticket: "different-ticket", appURL: appURL)
    #expect(repeated == installation)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.test/v1/desktop-control/enroll")
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["enrollment_ticket": "setup-ticket-1"])
}

@Test func enrollmentRejectsInvalidGatewayURLAndCredentialWithoutSaving() async throws {
    let cases = [
        ("not-a-32-byte-secret", "wss://cluster-agent.example.test/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "https://cluster-agent.example.test/v1/desktop-control/ws"),
        (Data(repeating: 0x1, count: 32).base64EncodedString(), "wss://cluster-agent.example.test/other"),
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
            try await client.enroll(ticket: "setup-ticket", appURL: URL(string: "https://my.personastack.test")!)
        }
        #expect(try store.load() == nil)
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
        "gateway_websocket_url": "ws://cluster-agent.lan/v1/desktop-control/ws",
    ])
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())
    let appURL = URL(string: "http://my.personastack.lan/user/personas")!

    try await client.reportReady(installation: installation, appURL: appURL)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "http://my.personastack.lan/v1/desktop-control/ready")
    #expect(requests.first?.bearer == credential)
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["installation_id": "install-1", "readiness": "ready"])
}

@Test func setupReferenceAttachesToAnExistingMachineWithoutReplacingItsCredential() async throws {
    let credential = Data(repeating: 0x41, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let encodedInstallation = try JSONSerialization.data(withJSONObject: [
        "installation_id": "install-1",
        "machine_credential": credential,
        "gateway_websocket_url": "wss://cluster-agent.example.test/v1/desktop-control/ws",
    ])
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())

    try await client.attach(ticket: "setup-ticket-second-user", installation: installation, appURL: URL(string: "https://my.personastack.test")!)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.test/v1/desktop-control/attach")
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
        "gateway_websocket_url": "wss://cluster-agent.example.test/v1/desktop-control/ws",
    ])
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: encodedInstallation)
    let transport = EnrollmentTransportFixture(response: Data(), status: 204)
    let client = DesktopControlEnrollmentClient(transport: transport, credentials: EnrollmentCredentialStoreFixture())

    try await client.revokeRemote(installation: installation, appURL: URL(string: "https://my.personastack.test/user/personas")!)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.url.absoluteString == "https://my.personastack.test/v1/desktop-control/revoke")
    #expect(requests.first?.bearer == credential)
    let body = try #require(requests.first?.body)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(payload == ["installation_id": "install-1"])
}
