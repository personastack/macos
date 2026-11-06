import Foundation
import PersonaStackCore
import Testing
@testable import PersonaStack

private let machineTestNow = Date(timeIntervalSince1970: 1_700_000_000)
private let machineTestExpiry = "2030-01-02T03:04:05Z"
private func machinePendingFixture(_ configuration: DesktopEnvironmentConfiguration = .production) throws -> IMessagePendingEnrollment {
    try IMessagePendingEnrollment(setupReference: String(repeating: "A", count: 43), naturalUserID: "human",
        workspaceID: "workspace", environmentIdentity: configuration.preferenceIdentity,
        expiresAt: machineTestExpiry, credentialBytes: Data(repeating: 0xFB, count: 32))
}
private func machineScopeFixture(_ pending: IMessagePendingEnrollment,
                                 origin: String = DesktopEnvironmentConfiguration.production.appOrigin) throws -> IMessageHostedNativeScope {
    try JSONDecoder().decode(IMessageHostedNativeScope.self, from: JSONSerialization.data(withJSONObject: [
        "natural_user_id": pending.naturalUserID, "workspace_id": pending.workspaceID, "app_origin": origin,
    ]))
}
private func machineJourneyFixture(_ pending: IMessagePendingEnrollment,
                                   expiry: String? = nil) throws -> IMessageHostedJourney {
    try JSONDecoder().decode(IMessageHostedJourney.self, from: JSONSerialization.data(withJSONObject: [
        "setup_reference": pending.setupReference, "generation": 1, "expires_at": expiry ?? pending.expiresAt, "mac_verified": false,
    ]))
}
private func machineTicketFixture(expiry: String = "2029-01-02T03:04:05Z") throws -> IMessageHostedEnrollmentTicket {
    try JSONDecoder().decode(IMessageHostedEnrollmentTicket.self, from: JSONSerialization.data(withJSONObject: [
        "enrollment_ticket": String(repeating: "A", count: 43), "expires_at": expiry,
    ]))
}
private func machineResponseFixture(id: String = "installation", gateway: URL = DesktopEnvironmentConfiguration.production.gatewayWebsocketURL) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["installation_id": id, "gateway_websocket_url": gateway.absoluteString])
}

private actor MachineTransportFixture: AgentBridgeHostedTransport {
    let path: String
    let proof: String
    let installationID: String?
    let response: Data
    let status: Int
    let beforeResponse: (@Sendable () async -> Void)?
    let throwsError: Bool
    private(set) var calls = 0
    init(path: String = "/v1/desktop-control/enroll", proof: String, installationID: String? = nil,
         response: Data, status: Int = 201, throwsError: Bool = false,
         beforeResponse: (@Sendable () async -> Void)? = nil) {
        self.path = path; self.proof = proof; self.installationID = installationID
        self.response = response; self.status = status; self.throwsError = throwsError; self.beforeResponse = beforeResponse
    }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        guard calls == 1 else { Issue.record("Unexpected repeated machine request"); throw IMessageMachineSetupError.rejected }
        #expect(request.url?.absoluteString == DesktopEnvironmentConfiguration.production.appOrigin + path)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 15)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + proof)
        #expect(request.value(forHTTPHeaderField: "X-PersonaStack-Native-Client") == "macos-imessage-v1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) ==
            ["authorization", "x-personastack-native-client", "content-type", "accept"])
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        var expected = ["family": "imessage", "enrollment_ticket": String(repeating: "A", count: 43)]
        if let installationID { expected["installation_id"] = installationID }
        #expect(body == expected)
        #expect(!String(decoding: data, as: UTF8.self).contains(proof))
        if let beforeResponse { await beforeResponse() }
        if throwsError { throw MachinePrivateError() }
        return (response, status)
    }
}
private struct MachinePrivateError: Error, CustomStringConvertible {
    var description: String { "private-proof-and-transport-url" }
}
@MainActor private final class MachineGenerationFence {
    var generation = UUID()
    var calls = 0
    func validate(_ expected: UUID) throws {
        calls += 1
        guard generation == expected else { throw MachinePrivateError() }
    }
    func replace() { generation = UUID() }
}

/// Native filesystem fixtures obtain receipts through the real finite client.
/// They cannot construct the fileprivate production receipt initializer.
func machineResetReceiptFixture(pending: IMessagePendingEnrollment, generation: UUID,
                                configuration: DesktopEnvironmentConfiguration = .production) async throws -> IMessageEnrollmentResetReceipt {
    let transport = MachineTransportFixture(proof: pending.machineCredential,
        response: Data("server-error-body-is-not-authority".utf8), status: 410)
    let result = try await IMessageMachineSetupClient(transport: transport).enroll(configuration: configuration,
        pending: pending, verifiedScope: machineScopeFixture(pending, origin: configuration.appOrigin),
        journey: machineJourneyFixture(pending), ticket: machineTicketFixture(), coordinatorGeneration: generation,
        now: machineTestNow, validateScope: { value in #expect(value == generation) })
    guard case .resetRequired(let receipt) = result else { throw IMessageMachineSetupError.invalidResponse }
    return receipt
}

@Test func iMessageMachineInstallationInitializerPinsGatewayProofAndIdentity() throws {
    let pending = try machinePendingFixture()
    let installation = try DesktopControlInstallation(installationID: "installation", machineCredential: pending.machineCredential,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    #expect(installation.machineCredential == pending.machineCredential)
    #expect(installation.environmentOrigin == DesktopEnvironmentConfiguration.production.appOrigin)
    for id in ["", " id", "id\n", String(repeating: "i", count: 257)] {
        #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
            try DesktopControlInstallation(installationID: id, machineCredential: pending.machineCredential,
                gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
        }
    }
    #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try DesktopControlInstallation(installationID: "installation", machineCredential: "invalid-proof",
            gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    }
    #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try DesktopControlInstallation(installationID: "installation", machineCredential: pending.machineCredential,
            gatewayWebsocketURL: DesktopEnvironmentConfiguration.lan.gatewayWebsocketURL, configuration: .production)
    }
}

@Test @MainActor func iMessageMachineEnrollUsesExactFiniteWireAndRetainedProof() async throws {
    let pending = try machinePendingFixture()
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: try machineResponseFixture())
    let fence = MachineGenerationFence()
    let result = try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
        pending: pending, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
        ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    guard case .enrolled(let installation) = result else { Issue.record("Unexpected reset receipt"); return }
    #expect(installation.installationID == "installation")
    #expect(installation.machineCredential == pending.machineCredential)
    #expect(installation.environmentOrigin == DesktopEnvironmentConfiguration.production.appOrigin)
    #expect(fence.calls == 2)
    #expect(await transport.calls == 1)
}

@Test @MainActor func iMessageMachineAttachCanonicalizesHeaderAndPreservesSavedRepresentation() async throws {
    let pending = try machinePendingFixture()
    let saved = try DesktopControlInstallation(installationID: "installation",
        machineCredential: pending.credentialBytes.base64EncodedString(),
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    let transport = MachineTransportFixture(path: "/v1/desktop-control/attach", proof: pending.machineCredential,
        installationID: saved.installationID, response: try machineResponseFixture(), status: 200)
    let fence = MachineGenerationFence()
    let returned = try await IMessageMachineSetupClient(transport: transport).attach(configuration: .production,
        installation: saved, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
        ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    #expect(returned == saved)
    #expect(fence.calls == 2)
    #expect(await transport.calls == 1)
}

@Test(arguments: ["550e8400-e29b-41d4-a716-446655440000", "550E8400-E29B-41D4-A716-446655440000"])
@MainActor func iMessageMachineAttachAcceptsPersistedUUIDAndResponseIdentity(id: String) async throws {
    let pending = try machinePendingFixture()
    let raw = try JSONSerialization.data(withJSONObject: [
        "installation_id": id, "machine_credential": pending.machineCredential,
        "gateway_websocket_url": DesktopEnvironmentConfiguration.production.gatewayWebsocketURL.absoluteString,
        "environment_origin": DesktopEnvironmentConfiguration.production.appOrigin,
    ])
    let saved = try JSONDecoder().decode(DesktopControlInstallation.self, from: raw)
    let transport = MachineTransportFixture(path: "/v1/desktop-control/attach", proof: pending.machineCredential,
        installationID: id, response: try machineResponseFixture(id: id), status: 200)
    let fence = MachineGenerationFence()
    let returned = try await IMessageMachineSetupClient(transport: transport).attach(configuration: .production,
        installation: saved, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
        ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow,
        validateScope: { try fence.validate($0) })
    #expect(returned == saved)
    #expect(returned.installationID == id)
    #expect(await transport.calls == 1)
    #expect(fence.calls == 2)
}

@Test(arguments: ["\u{0000}", "\u{001F}", "\u{007F}", "\u{0085}"])
@MainActor func iMessageMachineAttachRejectsEmbeddedControlScalarsBeforeTransport(control: String) async throws {
    let pending = try machinePendingFixture()
    let id = "550e8400-e29b-41d4-" + control + "a716-446655440000"
    // Persisted installations use Codable. The attach boundary must reject
    // invalid identities independently of the new-installation initializer.
    let raw = try JSONSerialization.data(withJSONObject: [
        "installation_id": id, "machine_credential": pending.machineCredential,
        "gateway_websocket_url": DesktopEnvironmentConfiguration.production.gatewayWebsocketURL.absoluteString,
        "environment_origin": DesktopEnvironmentConfiguration.production.appOrigin,
    ])
    let saved = try JSONDecoder().decode(DesktopControlInstallation.self, from: raw)
    let transport = MachineTransportFixture(path: "/v1/desktop-control/attach", proof: pending.machineCredential,
        installationID: id, response: Data(), status: 200)
    let fence = MachineGenerationFence()
    await #expect(throws: IMessageMachineSetupError.invalidRequest) {
        try await IMessageMachineSetupClient(transport: transport).attach(configuration: .production,
            installation: saved, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow,
            validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 0)
    #expect(fence.calls == 0)
    #expect(throws: DesktopControlEnrollmentError.invalidResponse) {
        try DesktopControlInstallation(installationID: id, machineCredential: pending.machineCredential,
            gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    }
}

@Test(arguments: [400, 401, 403, 404, 409, 410, 429, 500, 503, 302, 307])
@MainActor func iMessageMachineOnlyExactEnrollGoneCreatesResetReceipt(status: Int) async throws {
    let pending = try machinePendingFixture()
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: Data("private-proof-and-body".utf8), status: status)
    let fence = MachineGenerationFence()
    do {
        let result = try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
            pending: pending, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
        guard status == 410, case .resetRequired(let receipt) = result else { Issue.record("Nonterminal status produced authority"); return }
        #expect(receipt.pending == pending)
        #expect(receipt.coordinatorGeneration == fence.generation)
        #expect(receipt.environmentIdentity == pending.environmentIdentity)
        let visible = String(describing: receipt) + String(reflecting: receipt) + String(describing: receipt.customMirror)
        #expect(!visible.contains(pending.machineCredential))
        #expect(!visible.contains(pending.setupReference))
        #expect(!visible.contains(pending.environmentIdentity))
    } catch {
        #expect(status != 410)
        let expected: IMessageMachineSetupError
        switch status {
        case 400: expected = .invalidRequest
        case 401, 403, 404, 409: expected = .rejected
        case 429: expected = .rateLimited
        default: expected = .serviceUnavailable
        }
        #expect(error as? IMessageMachineSetupError == expected)
        #expect(!String(describing: error).contains("private-proof-and-body"))
    }
    #expect(await transport.calls == 1)
}

@Test(arguments: [410, 200])
@MainActor func iMessageMachineAttachNeverResetsAndPinsReturnedInstallation(status: Int) async throws {
    let pending = try machinePendingFixture()
    let installation = try DesktopControlInstallation(installationID: "installation", machineCredential: pending.machineCredential,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    let transport = MachineTransportFixture(path: "/v1/desktop-control/attach", proof: pending.machineCredential,
        installationID: installation.installationID, response: try machineResponseFixture(id: "foreign-installation"), status: status)
    let fence = MachineGenerationFence()
    await #expect(throws: status == 410 ? IMessageMachineSetupError.rejected : .invalidResponse) {
        try await IMessageMachineSetupClient(transport: transport).attach(configuration: .production,
            installation: installation, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 1)
}

@Test @MainActor func iMessageMachineAttachRejectsForeignEnvironmentBeforeTransport() async throws {
    let pending = try machinePendingFixture()
    let installation = try DesktopControlInstallation(installationID: "installation", machineCredential: pending.machineCredential,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.lan.gatewayWebsocketURL, configuration: .lan)
    let transport = MachineTransportFixture(path: "/v1/desktop-control/attach", proof: pending.machineCredential,
        installationID: installation.installationID, response: Data(), status: 410)
    let fence = MachineGenerationFence()
    await #expect(throws: IMessageMachineSetupError.scopeChanged) {
        try await IMessageMachineSetupClient(transport: transport).attach(configuration: .production,
            installation: installation, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow,
            validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 0)
}

@Test(arguments: ["unknown", "duplicate", "escaped-duplicate", "null", "secret", "foreign-gateway", "missing", "array", "trailing", "oversized", "utf8"])
@MainActor func iMessageMachineMetadataRepliesFailClosed(kind: String) async throws {
    let pending = try machinePendingFixture()
    let valid = String(decoding: try machineResponseFixture(), as: UTF8.self)
    let raw: Data
    switch kind {
    case "unknown": raw = Data(String(valid.dropLast()).appending(",\"extra\":1}").utf8)
    case "duplicate": raw = Data(String(valid.dropLast()).appending(",\"installation_id\":\"installation\"}").utf8)
    case "escaped-duplicate": raw = Data(String(valid.dropLast()).appending(",\"installation\\u005fid\":\"installation\"}").utf8)
    case "null": raw = Data("{\"installation_id\":null,\"gateway_websocket_url\":\"wss://example.test\"}".utf8)
    case "secret": raw = Data(String(valid.dropLast()).appending(",\"machine_credential\":\"private-proof\"}").utf8)
    case "foreign-gateway": raw = try machineResponseFixture(gateway: DesktopEnvironmentConfiguration.lan.gatewayWebsocketURL)
    case "missing": raw = Data("{}".utf8)
    case "array": raw = Data("[]".utf8)
    case "trailing": raw = Data((valid + "{}").utf8)
    case "oversized": raw = Data(repeating: 0x20, count: 4097)
    default: raw = Data([0xFF])
    }
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: raw)
    let fence = MachineGenerationFence()
    await #expect(throws: IMessageMachineSetupError.invalidResponse) {
        try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
            pending: pending, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 1)
}

@Test(arguments: ["origin", "journey", "ticket", "before-fence"])
@MainActor func iMessageMachineInvalidScopeOrExpiryMakesZeroRequests(kind: String) async throws {
    let pending = try machinePendingFixture()
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: Data())
    let fence = MachineGenerationFence()
    let generation = fence.generation
    if kind == "before-fence" { fence.replace() }
    await #expect(throws: (any Error).self) {
        try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
            pending: pending, verifiedScope: machineScopeFixture(pending, origin: kind == "origin" ? "https://foreign.example" : DesktopEnvironmentConfiguration.production.appOrigin),
            journey: machineJourneyFixture(pending, expiry: kind == "journey" ? "2020-01-02T03:04:05Z" : nil),
            ticket: machineTicketFixture(expiry: kind == "ticket" ? "2020-01-02T03:04:05Z" : "2029-01-02T03:04:05Z"),
            coordinatorGeneration: generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 0)
}

@Test(arguments: [201, 410])
@MainActor func iMessageMachinePostResponseGenerationFenceRejectsSuccessAndReset(status: Int) async throws {
    let pending = try machinePendingFixture()
    let fence = MachineGenerationFence()
    let generation = fence.generation
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: try machineResponseFixture(), status: status,
        beforeResponse: { await fence.replace() })
    await #expect(throws: IMessageMachineSetupError.scopeChanged) {
        try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
            pending: pending, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    }
    #expect(fence.calls == 2)
    #expect(await transport.calls == 1)
}

@Test(arguments: ["transport", "oversized-gone"])
@MainActor func iMessageMachineUnavailableOrOversizedResponseNeverReturnsReset(kind: String) async throws {
    let pending = try machinePendingFixture()
    let transport = MachineTransportFixture(proof: pending.machineCredential, response: Data(repeating: 0x20, count: 4097),
        status: 410, throwsError: kind == "transport")
    let fence = MachineGenerationFence()
    await #expect(throws: kind == "transport" ? IMessageMachineSetupError.serviceUnavailable : .invalidResponse) {
        try await IMessageMachineSetupClient(transport: transport).enroll(configuration: .production,
            pending: pending, verifiedScope: machineScopeFixture(pending), journey: machineJourneyFixture(pending),
            ticket: machineTicketFixture(), coordinatorGeneration: fence.generation, now: machineTestNow, validateScope: { try fence.validate($0) })
    }
    #expect(await transport.calls == 1)
}

@MainActor private final class MachineHeldScopeFence {
    let generation = UUID()
    let heldCall: Int
    private(set) var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    init(heldCall: Int) { self.heldCall = heldCall }
    func validate(_ expected: UUID) async throws {
        #expect(expected == generation)
        calls += 1
        if calls == heldCall {
            await withCheckedContinuation { continuation in
                held = continuation
                entered?.resume(); entered = nil
            }
        }
        // Deliberately return normally after cancellation. The client owns the
        // cancellation check after every awaited authority callback.
    }
    func waitUntilHeld() async {
        if held == nil { await withCheckedContinuation { entered = $0 } }
    }
    func release() { held?.resume(); held = nil }
}

@Test(arguments: ["pre-enroll201", "final-enroll201", "pre-enroll410", "final-enroll410", "pre-attach200", "final-attach200"])
@MainActor func iMessageMachineCancellationInsideScopeCallbacksNeverDispatchesOrReturnsAuthority(point: String) async throws {
    let pending = try machinePendingFixture()
    let isAttach = point.contains("attach")
    let isPre = point.hasPrefix("pre")
    let status = isAttach ? 200 : point.hasSuffix("410") ? 410 : 201
    let transport = MachineTransportFixture(path: isAttach ? "/v1/desktop-control/attach" : "/v1/desktop-control/enroll",
        proof: pending.machineCredential, installationID: isAttach ? "installation" : nil,
        response: try machineResponseFixture(), status: status)
    let client = IMessageMachineSetupClient(transport: transport)
    let fence = MachineHeldScopeFence(heldCall: isPre ? 1 : 2)
    let scope = try machineScopeFixture(pending)
    let journey = try machineJourneyFixture(pending)
    let ticket = try machineTicketFixture()
    let installation = try DesktopControlInstallation(installationID: "installation", machineCredential: pending.machineCredential,
        gatewayWebsocketURL: DesktopEnvironmentConfiguration.production.gatewayWebsocketURL, configuration: .production)
    let operation = Task { @MainActor in
        if isAttach {
            _ = try await client.attach(configuration: .production, installation: installation, verifiedScope: scope,
                journey: journey, ticket: ticket, coordinatorGeneration: fence.generation, now: machineTestNow,
                validateScope: { try await fence.validate($0) })
        } else {
            _ = try await client.enroll(configuration: .production, pending: pending, verifiedScope: scope,
                journey: journey, ticket: ticket, coordinatorGeneration: fence.generation, now: machineTestNow,
                validateScope: { try await fence.validate($0) })
        }
    }
    await fence.waitUntilHeld()
    operation.cancel()
    fence.release()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(await transport.calls == (isPre ? 0 : 1))
    #expect(fence.calls == (isPre ? 1 : 2))
}
