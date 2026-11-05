import Foundation
import PersonaStackCore

enum IMessageMachineSetupError: Error, Equatable, Sendable {
    case invalidRequest, invalidResponse, scopeChanged, rejected, rateLimited, serviceUnavailable
}

/// Only this file can mint a terminal receipt after the exact enroll response.
/// It is memory-only and conveys no authority to a page or a different setup.
struct IMessageEnrollmentResetReceipt: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let pending: IMessagePendingEnrollment
    let environmentIdentity: String
    let verifiedScope: IMessageHostedNativeScope
    let coordinatorGeneration: UUID
    fileprivate init(pending: IMessagePendingEnrollment, configuration: DesktopEnvironmentConfiguration,
                     verifiedScope: IMessageHostedNativeScope, coordinatorGeneration: UUID) {
        self.pending = pending; environmentIdentity = configuration.preferenceIdentity
        self.verifiedScope = verifiedScope; self.coordinatorGeneration = coordinatorGeneration
    }
    var description: String { "IMessageEnrollmentResetReceipt(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

enum IMessageMachineEnrollmentResult: Sendable {
    case enrolled(DesktopControlInstallation)
    case resetRequired(IMessageEnrollmentResetReceipt)
}

/// Finite native machine transport. Hosted sessions, consent and setup UI stay
/// with their existing owners. No application factory installs this client yet.
struct IMessageMachineSetupClient: Sendable {
    typealias ValidateScope = @MainActor @Sendable (UUID) async throws -> Void
    private let transport: any AgentBridgeHostedTransport
    init(transport: any AgentBridgeHostedTransport = AgentBridgeURLTransport()) { self.transport = transport }

    func enroll(configuration: DesktopEnvironmentConfiguration, pending: IMessagePendingEnrollment,
                verifiedScope: IMessageHostedNativeScope, journey: IMessageHostedJourney,
                ticket: IMessageHostedEnrollmentTicket, coordinatorGeneration: UUID,
                now: Date = Date(), validateScope: ValidateScope) async throws -> IMessageMachineEnrollmentResult {
        try validate(configuration, scope: verifiedScope, journey: journey, ticket: ticket, now: now)
        do {
            try pending.requireJourney(setupReference: journey.setupReference, naturalUserID: verifiedScope.naturalUserID,
                workspaceID: verifiedScope.workspaceID, environmentIdentity: configuration.preferenceIdentity, expiresAt: journey.expiresAt)
            try pending.requireUsable(now: now)
        } catch { throw IMessageMachineSetupError.scopeChanged }
        let (data, status) = try await perform(configuration, operation: .enroll,
            ticket: ticket.enrollmentTicket, proof: pending.machineCredential,
            coordinatorGeneration: coordinatorGeneration, validateScope: validateScope)
        if status == 410 {
            return .resetRequired(.init(pending: pending, configuration: configuration,
                verifiedScope: verifiedScope, coordinatorGeneration: coordinatorGeneration))
        }
        guard status == 201 else { throw Self.statusError(status) }
        let installation = try decodeInstallation(data, proof: pending.machineCredential, configuration: configuration)
        return .enrolled(installation)
    }

    func attach(configuration: DesktopEnvironmentConfiguration, installation: DesktopControlInstallation,
                verifiedScope: IMessageHostedNativeScope, journey: IMessageHostedJourney,
                ticket: IMessageHostedEnrollmentTicket, coordinatorGeneration: UUID,
                now: Date = Date(), validateScope: ValidateScope) async throws -> DesktopControlInstallation {
        try validate(configuration, scope: verifiedScope, journey: journey, ticket: ticket, now: now)
        do { try installation.requireEnvironment(configuration.appPageURL, configuration: configuration) }
        catch { throw IMessageMachineSetupError.scopeChanged }
        guard installation.gatewayWebsocketURL == configuration.gatewayWebsocketURL,
              Self.validID(installation.installationID) else { throw IMessageMachineSetupError.invalidRequest }
        let (data, status) = try await perform(configuration, operation: .attach(installation.installationID),
            ticket: ticket.enrollmentTicket, proof: installation.machineCredential,
            coordinatorGeneration: coordinatorGeneration, validateScope: validateScope)
        guard status == 200 else { throw Self.statusError(status) }
        let returned = try decodeInstallation(data, proof: installation.machineCredential, configuration: configuration)
        guard returned.installationID == installation.installationID else { throw IMessageMachineSetupError.invalidResponse }
        return returned
    }

    private enum Operation {
        case enroll, attach(String)
        var path: String {
            switch self { case .enroll: "/v1/desktop-control/enroll"; case .attach: "/v1/desktop-control/attach" }
        }
        var installationID: String? { switch self { case .enroll: nil; case .attach(let id): id } }
    }

    private func validate(_ configuration: DesktopEnvironmentConfiguration, scope: IMessageHostedNativeScope,
                          journey: IMessageHostedJourney, ticket: IMessageHostedEnrollmentTicket, now: Date) throws {
        let canonical = try? DesktopEnvironmentConfiguration(appURL: configuration.appURL.absoluteString,
            gatewayURL: configuration.gatewayURL.absoluteString, mcpURL: configuration.mcpURL.absoluteString)
        guard canonical == configuration, scope.appOrigin == configuration.appOrigin,
              journey.generation > 0 else { throw IMessageMachineSetupError.scopeChanged }
        do {
            let journeyExpiry = try IMessageGatewayWire.utcDate(journey.expiresAt)
            let ticketExpiry = try IMessageGatewayWire.utcDate(ticket.expiresAt)
            guard journeyExpiry > now, ticketExpiry > now, ticketExpiry <= journeyExpiry else {
                throw IMessageMachineSetupError.invalidRequest
            }
        } catch { throw IMessageMachineSetupError.invalidRequest }
    }

    private func perform(_ configuration: DesktopEnvironmentConfiguration, operation: Operation, ticket: String,
                         proof: String, coordinatorGeneration: UUID, validateScope: ValidateScope) async throws -> (Data, Int) {
        let bearer = try Self.canonicalProof(proof)
        var endpoint = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        endpoint.path = operation.path
        var request = URLRequest(url: endpoint.url!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.httpBody = try JSONEncoder().encode(Request(enrollmentTicket: ticket, installationID: operation.installationID))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("macos-imessage-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        try Task.checkCancellation(); try await requireScope(validateScope, generation: coordinatorGeneration)
        let data: Data, status: Int
        do { (data, status) = try await transport.request(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw IMessageMachineSetupError.serviceUnavailable }
        try Task.checkCancellation(); try await requireScope(validateScope, generation: coordinatorGeneration)
        guard data.count <= 4096 else { throw IMessageMachineSetupError.invalidResponse }
        return (data, status)
    }

    private func requireScope(_ validateScope: ValidateScope, generation: UUID) async throws {
        do {
            try await validateScope(generation)
            try Task.checkCancellation()
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw IMessageMachineSetupError.scopeChanged }
    }

    private func decodeInstallation(_ data: Data, proof: String,
                                    configuration: DesktopEnvironmentConfiguration) throws -> DesktopControlInstallation {
        do {
            try IMessageJSONDocument.validate(data: data, maximumBytes: 4096)
            let response = try JSONDecoder().decode(Response.self, from: data)
            return try DesktopControlInstallation(installationID: response.installationID, machineCredential: proof,
                gatewayWebsocketURL: response.gatewayWebsocketURL, configuration: configuration)
        } catch { throw IMessageMachineSetupError.invalidResponse }
    }

    static func canonicalProof(_ value: String) throws -> String {
        guard value.utf8.count <= 44 else { throw IMessageMachineSetupError.invalidRequest }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { throw IMessageMachineSetupError.invalidRequest }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func statusError(_ status: Int) -> IMessageMachineSetupError {
        switch status {
        case 400: .invalidRequest
        case 401, 403, 404, 409, 410: .rejected
        case 429: .rateLimited
        default: .serviceUnavailable
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private struct Request: Encodable {
        let family = "imessage"
        let enrollmentTicket: String
        let installationID: String?
        enum CodingKeys: String, CodingKey { case family, enrollmentTicket = "enrollment_ticket", installationID = "installation_id" }
    }

    private struct Response: Decodable {
        let installationID: String
        let gatewayWebsocketURL: URL
        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: AnyKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == ["installation_id", "gateway_websocket_url"] else {
                throw IMessageMachineSetupError.invalidResponse
            }
            let c = try decoder.container(keyedBy: Keys.self)
            installationID = try c.decode(String.self, forKey: .installationID)
            let raw = try c.decode(String.self, forKey: .gatewayWebsocketURL)
            guard Self.validGateway(raw), let url = URL(string: raw) else { throw IMessageMachineSetupError.invalidResponse }
            gatewayWebsocketURL = url
        }
        private static func validGateway(_ value: String) -> Bool {
            value.utf8.count <= 2048 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
        }
        private enum Keys: String, CodingKey { case installationID = "installation_id", gatewayWebsocketURL = "gateway_websocket_url" }
        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }
}
