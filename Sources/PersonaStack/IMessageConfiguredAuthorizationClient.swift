import Foundation
import PersonaStackCore

/// Current command authorization at the queue front. No cookies, retry or new credential owner.
struct IMessageConfiguredAuthorizationClient: Sendable {
    typealias ValidateCurrent = @MainActor @Sendable () async throws -> Void
    private let transport: any AgentBridgeHostedTransport
    init(transport: any AgentBridgeHostedTransport = IMessageConfiguredURLTransport()) { self.transport = transport }

    func authorize(_ command: IMessageGatewayCommand, installation: DesktopControlInstallation,
                   configuration: DesktopEnvironmentConfiguration, deadline: Date,
                   humanTextSHA256: String? = nil, validateCurrent: ValidateCurrent) async throws -> IMessageGatewaySnapshot {
        try IMessageGatewayWire.validate(command)
        guard case .configured = command.input, command.target.installationID == installation.installationID else {
            throw IMessageConfiguredAuthorizationError.denied(.scopeDenied)
        }
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        let originalDeadline = min(deadline, try IMessageGatewayWire.utcDate(command.deadlineAt))
        try await requireCurrent(validateCurrent, deadline: originalDeadline)
        let body = try JSONEncoder().encode(IMessageGatewayNativeCommandRequest(command: command))
        guard body.count <= IMessageConfiguredGatewayValidation.maximumCommandControlBytes else { throw IMessageConfiguredAuthorizationError.unavailable }
        var parts = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        parts.path = "/v1/desktop-control/imessage/commands/authorize"; parts.query = nil; parts.fragment = nil
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(0.001, originalDeadline.timeIntervalSinceNow))
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("Bearer \(try Self.proof(installation.machineCredential))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("macos-imessage-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        let response: (Data, Int)
        do { response = try await transport.request(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw IMessageConfiguredAuthorizationError.unavailable }
        try await requireCurrent(validateCurrent, deadline: originalDeadline)
        guard response.0.count <= IMessageConfiguredGatewayValidation.maximumCommandControlBytes else { throw IMessageConfiguredAuthorizationError.unavailable }
        guard response.1 == 200 else {
            if [401, 403].contains(response.1) { throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) }
            throw IMessageConfiguredAuthorizationError.unavailable
        }
        let value: IMessageGatewayNativeAuthorizationResponse
        do { value = try IMessageConfiguredGatewayValidation.decode(IMessageGatewayNativeAuthorizationResponse.self, from: response.0, maximumBytes: IMessageConfiguredGatewayValidation.maximumCommandControlBytes) }
        catch { throw IMessageConfiguredAuthorizationError.unavailable }
        guard value.authorized, let snapshot = value.snapshot else { throw IMessageConfiguredAuthorizationError.denied(value.reasonCode ?? .scopeDenied) }
        try IMessageGatewayWire.validate(command: command, against: snapshot, humanTextSHA256: humanTextSHA256)
        return snapshot
    }
    private func requireCurrent(_ validateCurrent: ValidateCurrent, deadline: Date) async throws {
        try Task.checkCancellation()
        guard deadline > Date() else { throw IMessageConfiguredAuthorizationError.denied(.providerTimeout) }
        try await validateCurrent()
        try Task.checkCancellation()
        guard deadline > Date() else { throw IMessageConfiguredAuthorizationError.denied(.providerTimeout) }
    }
    private static func proof(_ value: String) throws -> String {
        guard (43...44).contains(value.utf8.count) else { throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) }
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let bytes = Data(base64Encoded: normalized), bytes.count == 32 else { throw IMessageConfiguredAuthorizationError.denied(.scopeDenied) }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct IMessageConfiguredURLTransport: AgentBridgeHostedTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = DesktopControlNetworkSession.makeWithoutRedirects(configuration: configuration)
    }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              data.count <= IMessageConfiguredGatewayValidation.maximumCommandControlBytes else { throw IMessageConfiguredAuthorizationError.unavailable }
        return (data, response.statusCode)
    }
}
