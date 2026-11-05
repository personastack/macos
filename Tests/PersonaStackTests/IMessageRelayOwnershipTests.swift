import Foundation
import Testing
import PersonaStackCore
@testable import PersonaStack

private actor IMessageRelayTransportFixture: DesktopControlEnrollmentTransport {
    private var response: Data
    private var status = 200
    private(set) var requests: [(URL, Data, String?)] = []

    init(_ response: String) { self.response = Data(response.utf8) }

    func replace(_ response: String, status: Int = 200) {
        self.response = Data(response.utf8)
        self.status = status
    }

    func post(url: URL, body: Data, bearer: String?) async throws -> (Data, Int) {
        requests.append((url, body, bearer))
        return (response, status)
    }
}

private func iMessageRelayInstallation() throws -> DesktopControlInstallation {
    try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"shared-mac","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8))
}

@Test func iMessageRelayOwnershipPreservesDesktopSetupState() async throws {
    let transport = IMessageRelayTransportFixture(#"{"has_active_config":false,"has_config":false,"has_active_imessage_config":true,"has_imessage_config":true}"#)
    let client = DesktopControlEnrollmentClient(transport: transport)
    let installation = try iMessageRelayInstallation()
    let appURL = URL(string: "https://my.personastack.ai")!
    let state = try await client.configurationState(installation: installation, appURL: appURL)
    #expect(!state.hasConfig && !state.hasActiveConfig)
    #expect(state.hasIMessageConfig && state.hasActiveIMessageConfig)
    #expect(try await client.hasActiveConfig(installation: installation, appURL: appURL))
    let requests = await transport.requests
    #expect(requests.count == 2)
    for (url, body, bearer) in requests {
        #expect(url.absoluteString == "https://my.personastack.ai/v1/desktop-control/ready")
        #expect(bearer == installation.machineCredential)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == Set(["installation_id", "validate_only", "relay_state_only"]))
        #expect(object["installation_id"] as? String == installation.installationID)
        #expect(object["validate_only"] as? Bool == true)
        #expect(object["relay_state_only"] as? Bool == true)
    }
}

@Test func iMessageRelayOwnershipSurvivesEitherFamilyRemoval() async throws {
    let transport = IMessageRelayTransportFixture(#"{"has_active_config":true,"has_config":true,"has_active_imessage_config":true,"has_imessage_config":true}"#)
    let client = DesktopControlEnrollmentClient(transport: transport)
    let installation = try iMessageRelayInstallation()
    let appURL = URL(string: "https://my.personastack.ai")!
    for payload in [
        #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":true,"has_imessage_config":true}"#,
        #"{"has_active_config":true,"has_config":true,"has_active_imessage_config":false,"has_imessage_config":false}"#,
        #"{"has_active_config":true,"has_config":true}"#,
    ] {
        await transport.replace(payload)
        #expect(try await client.hasActiveConfig(installation: installation, appURL: appURL))
    }
    await transport.replace(#"{"has_active_config":false,"has_config":true,"has_active_imessage_config":false,"has_imessage_config":true}"#)
    #expect(!(try await client.hasActiveConfig(installation: installation, appURL: appURL)))
    let legacy = try JSONDecoder().decode(DesktopControlConfigurationState.self, from: Data(#"{"has_active_config":false,"has_config":false}"#.utf8))
    #expect(!legacy.hasIMessageConfig && !legacy.hasActiveIMessageConfig && !legacy.hasActiveRelayCapability)
}

@Test(arguments: [
    #"{"has_active_config":true,"has_config":false,"has_active_imessage_config":true,"has_imessage_config":true}"#,
    #"{"has_active_config":true,"has_config":true,"has_active_imessage_config":true,"has_imessage_config":false}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":null,"has_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":false,"has_active_imessage_config":"true","has_imessage_config":true}"#,
    #"{"has_active_config":false,"has_config":false,"has_imessage_config":null}"#,
]) func iMessageRelayOwnershipRejectsMalformedState(payload: String) async throws {
    let client = DesktopControlEnrollmentClient(transport: IMessageRelayTransportFixture(payload))
    let installation = try iMessageRelayInstallation()
    await #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try await client.hasActiveConfig(installation: installation, appURL: URL(string: "https://my.personastack.ai")!)
    }
}

private struct IMessageRelayNeverInstall: DesktopControlDriverInstalling {
    func discoverExisting() async throws -> CuaDriverInstallation? { Issue.record("Relay ownership must not discover CUA"); return nil }
    func install() async throws -> CuaDriverInstallation { Issue.record("Relay ownership must not install CUA"); throw CancellationError() }
}

private struct IMessageRelayCredentialFixture: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation
    func load() throws -> DesktopControlInstallation? { installation }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Relay ownership must not save credentials") }
    func delete() throws { Issue.record("Relay ownership must not delete credentials") }
}

@Test @MainActor func iMessageRelayRuntimeKeepsSocketWhileDesktopControlIsPausedOrRemoved() async throws {
    let transport = IMessageRelayTransportFixture(#"{"has_active_config":false,"has_config":false,"has_active_imessage_config":true,"has_imessage_config":true}"#)
    let installation = try iMessageRelayInstallation()
    let preferences = try #require(UserDefaults(suiteName: "IMessageRelayOwnership-\(UUID().uuidString)"))
    // API registration retains the socket only after explicit native Connect.
    preferences.set(true, forKey: IMessagePreferenceKeys.relayEnabled(.production))
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: IMessageRelayNeverInstall(), credentials: IMessageRelayCredentialFixture(installation: installation),
        installation: installation, connected: true, readiness: "paused", paused: true,
        relayStateReader: DesktopControlEnrollmentClient(transport: transport), preferences: preferences)
    try await runtime.finishSetupIfIdle()
    #expect(runtime.gatewayConnected && runtime.paused && runtime.readiness == "paused")
    await transport.replace("{}", status: 503)
    await #expect(throws: DesktopControlEnrollmentError.invalidResponse) { try await runtime.finishSetupIfIdle() }
    #expect(runtime.gatewayConnected)
    await transport.replace(#"{"has_active_config":false,"has_config":true,"has_active_imessage_config":false,"has_imessage_config":true}"#)
    try await runtime.finishSetupIfIdle()
    #expect(!runtime.gatewayConnected)
    await runtime.shutdownForQuit()
}
