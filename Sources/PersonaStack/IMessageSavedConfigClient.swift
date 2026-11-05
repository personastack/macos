import Foundation
import CryptoKit
import PersonaStackCore

struct IMessageSavedStatus: Decodable, Sendable {
    let integrationID: String
    let state: String
    let receiveState: String
    let readEnabled: Bool
    let sendEnabled: Bool
    let receiveEnabled: Bool
    let reasonCode: IMessageGatewayFailureCode?
    let lastConnectedAt: String?
    let lastReceiveScanAt: String?
    let pendingCount: Int64
    let oldestPendingAt: String?
    let continuityGapConversationIDs: [String]
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: [.reasonCode, .lastConnectedAt, .lastReceiveScanAt, .oldestPendingAt])
        integrationID = try c.decode(String.self, forKey: .integrationID)
        state = try c.decode(String.self, forKey: .state); receiveState = try c.decode(String.self, forKey: .receiveState)
        readEnabled = try c.decode(Bool.self, forKey: .readEnabled); sendEnabled = try c.decode(Bool.self, forKey: .sendEnabled)
        receiveEnabled = try c.decode(Bool.self, forKey: .receiveEnabled)
        reasonCode = try c.decodeIfPresent(IMessageGatewayFailureCode.self, forKey: .reasonCode)
        lastConnectedAt = try c.decodeIfPresent(String.self, forKey: .lastConnectedAt)
        lastReceiveScanAt = try c.decodeIfPresent(String.self, forKey: .lastReceiveScanAt)
        pendingCount = try c.decode(Int64.self, forKey: .pendingCount)
        oldestPendingAt = try c.decodeIfPresent(String.self, forKey: .oldestPendingAt)
        continuityGapConversationIDs = try c.decode([String].self, forKey: .continuityGapConversationIDs)
        guard hostedID(integrationID), ["connected", "reconnecting", "offline", "paused", "needs_attention", "disabled"].contains(state),
              ["unassigned", "disabled", "pending", "receiving", "catching_up", "degraded", "offline", "needs_attention"].contains(receiveState),
              (0...10000).contains(pendingCount), (pendingCount > 0) == (oldestPendingAt != nil),
              continuityGapConversationIDs.count <= 32, Set(continuityGapConversationIDs).count == continuityGapConversationIDs.count,
              continuityGapConversationIDs.allSatisfy(hostedID) else {
            throw IMessageHostedSetupError.invalidResponse
        }
        for value in [lastConnectedAt, lastReceiveScanAt, oldestPendingAt].compactMap({ $0 }) { _ = try IMessageGatewayWire.utcDate(value) }
    }
    enum Keys: String, CodingKey, CaseIterable {
        case integrationID = "integration_id", state, receiveState = "receive_state", readEnabled = "read_enabled"
        case sendEnabled = "send_enabled", receiveEnabled = "receive_enabled", reasonCode = "reason_code"
        case lastConnectedAt = "last_connected_at", lastReceiveScanAt = "last_receive_scan_at"
        case pendingCount = "pending_count", oldestPendingAt = "oldest_pending_at"
        case continuityGapConversationIDs = "continuity_gap_conversation_ids"
    }
}

struct IMessageSavedConfig: Decodable, Sendable {
    let installationID: String
    let macName: String
    let accountLabel: String
    let readEnabled: Bool
    let sendEnabled: Bool
    let paused: Bool
    let conversations: [IMessageGatewayPublicConversation]
    let status: IMessageSavedStatus
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        installationID = try c.decode(String.self, forKey: .installationID)
        macName = try c.decode(String.self, forKey: .macName); accountLabel = try c.decode(String.self, forKey: .accountLabel)
        readEnabled = try c.decode(Bool.self, forKey: .readEnabled); sendEnabled = try c.decode(Bool.self, forKey: .sendEnabled)
        paused = try c.decode(Bool.self, forKey: .paused)
        conversations = try c.decode([IMessageGatewayPublicConversation].self, forKey: .conversations)
        status = try c.decode(IMessageSavedStatus.self, forKey: .status)
        guard hostedID(installationID), hostedID(macName), hostedID(accountLabel),
              (1...32).contains(conversations.count), Set(conversations.map(\.conversationID)).count == conversations.count,
              status.readEnabled == readEnabled, status.sendEnabled == sendEnabled,
              conversations.map(\.conversationID).filter({ status.continuityGapConversationIDs.contains($0) }) == status.continuityGapConversationIDs else {
            throw IMessageHostedSetupError.invalidResponse
        }
    }
    enum Keys: String, CodingKey, CaseIterable {
        case installationID = "installation_id", macName = "mac_name", accountLabel = "account_label", readEnabled = "read_enabled"
        case sendEnabled = "send_enabled", paused, conversations, status
    }
}

struct IMessageSavedReadback: Decodable, Sendable {
    let integrationConfigID: String
    let name: String
    let configVersion: Int64
    let config: IMessageSavedConfig
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self)
        integrationConfigID = try c.decode(String.self, forKey: .integrationConfigID); name = try c.decode(String.self, forKey: .name)
        let raw = try c.decode(String.self, forKey: .configVersion)
        guard let version = Int64(raw), version > 0, String(version) == raw else { throw IMessageHostedSetupError.invalidResponse }
        configVersion = version; config = try c.decode(IMessageSavedConfig.self, forKey: .config)
        guard hostedID(integrationConfigID), hostedID(name), config.status.integrationID == integrationConfigID else { throw IMessageHostedSetupError.invalidResponse }
    }
    enum Keys: String, CodingKey, CaseIterable { case integrationConfigID = "integration_config_id", name, configVersion = "config_version", config }
}

struct IMessageHumanActionRequest: Encodable, Sendable, CustomStringConvertible {
    let expectedConfigVersion: Int64
    let action: IMessageGatewayHumanAction
    let conversationID: String?
    let clientRequestID: String?
    let text: String?
    var description: String { "IMessageHumanActionRequest(<redacted>)" }
    enum CodingKeys: String, CodingKey {
        case expectedConfigVersion = "expected_config_version", action, conversationID = "conversation_id", clientRequestID = "client_request_id", text
    }
}

struct IMessageHumanActionResponse: Decodable, Sendable {
    let command: IMessageGatewayCommand?
    let status: IMessageSavedStatus?
    let sendMessage: IMessageGatewaySendMessageResult?
    let failure: IMessageGatewayFailure?
    init(from decoder: Decoder) throws {
        let c = try hostedContainer(decoder, Keys.self, optional: Set(Keys.allCases))
        command = try c.decodeIfPresent(IMessageGatewayCommand.self, forKey: .command)
        status = try c.decodeIfPresent(IMessageSavedStatus.self, forKey: .status)
        sendMessage = try c.decodeIfPresent(IMessageGatewaySendMessageResult.self, forKey: .sendMessage)
        failure = try c.decodeIfPresent(IMessageGatewayFailure.self, forKey: .failure)
        guard [command != nil, status != nil, sendMessage != nil, failure != nil].filter({ $0 }).count == 1 else { throw IMessageHostedSetupError.invalidResponse }
    }
    enum Keys: String, CodingKey, CaseIterable { case command, status, sendMessage = "send_message", failure }
}

/// Finite saved settings and human actions. Human cookies and machine proof
/// never share a request. No generic page proxy, redirect or mutation retry.
struct IMessageSavedConfigClient: Sendable {
    typealias ValidateCurrent = IMessageHostedSetupClient.ValidateScope
    private let transport: any AgentBridgeHostedTransport
    private let hosted: IMessageHostedSetupClient
    static let maximumReadbackBytes = (8 << 20) + 16384
    static let maximumConfigUpdateBytes = 128 << 10
    init(transport: any AgentBridgeHostedTransport = IMessageSavedURLTransport()) {
        self.transport = transport; hosted = .init(transport: transport)
    }
    func read(_ id: String, configuration: DesktopEnvironmentConfiguration, cookies: String,
              scope: IMessageHostedNativeScope, validateCurrent: ValidateCurrent) async throws -> IMessageSavedReadback {
        let data = try await humanRequest(id: id, suffix: "", method: "GET", body: nil, configuration: configuration,
            cookies: cookies, csrf: nil, scope: scope, deadline: Date().addingTimeInterval(10), validateCurrent: validateCurrent)
        let result = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: data, maximumBytes: Self.maximumReadbackBytes)
        guard result.integrationConfigID == id else { throw IMessageHostedSetupError.scopeChanged }
        return result
    }
    func pause(_ saved: IMessageSavedReadback, configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
               scope: IMessageHostedNativeScope, validateCurrent: ValidateCurrent) async throws -> IMessageSavedReadback {
        let body = try JSONEncoder().encode(SavedVersionRequest(expectedConfigVersion: String(saved.configVersion)))
        let data = try await humanRequest(id: saved.integrationConfigID, suffix: "/pause", method: "POST", body: body,
            configuration: configuration, cookies: cookies, csrf: csrf, scope: scope, deadline: Date().addingTimeInterval(10), validateCurrent: validateCurrent)
        return try correlatedReadback(data, id: saved.integrationConfigID, minimumVersion: saved.configVersion)
    }
    func update(_ saved: IMessageSavedReadback, flow: IMessageSavedPageCommand.Action, receipt: IMessageHostedApprovalReceipt,
                consent: IMessageSetupFinalConsent, configuration: DesktopEnvironmentConfiguration, cookies: String, csrf: String,
                scope: IMessageHostedNativeScope, resumeConversationIDs: [String] = [], validateCurrent: ValidateCurrent) async throws -> IMessageSavedReadback {
        guard receipt.consent == consent, consent.deadline > Date(), try IMessageGatewayWire.utcDate(receipt.expiresAt) > Date(),
              consent.environmentIdentity == configuration.preferenceIdentity, saved.config.installationID == consent.installationID else { throw IMessageHostedSetupError.scopeChanged }
        let suffix = flow == .resume ? "/resume" : (flow == .resumeFromNow ? "/resume-from-now" : "")
        let fromNow = flow == .resumeFromNow
        guard fromNow ? (saved.config.readEnabled && consent.readEnabled == saved.config.readEnabled && consent.sendEnabled == saved.config.sendEnabled &&
            !resumeConversationIDs.isEmpty && Set(resumeConversationIDs).count == resumeConversationIDs.count &&
            saved.config.status.continuityGapConversationIDs.filter({ resumeConversationIDs.contains($0) }) == resumeConversationIDs) : resumeConversationIDs.isEmpty else {
            throw IMessageHostedSetupError.invalidRequest
        }
        let body = try IMessageSavedConfigUpdateRequest(expectedConfigVersion: String(saved.configVersion), name: saved.name,
            conversationIDs: fromNow ? saved.config.conversations.map(\.conversationID) : consent.conversations.map(\.conversationID),
            readEnabled: consent.readEnabled, sendEnabled: consent.sendEnabled,
            nativeApprovalReceipt: receipt.value, resumeConversationIDs: fromNow ? resumeConversationIDs : nil).encodedBody()
        let data = try await humanRequest(id: saved.integrationConfigID, suffix: suffix, method: suffix.isEmpty ? "PATCH" : "POST", body: body,
            configuration: configuration, cookies: cookies, csrf: csrf, scope: scope, deadline: consent.deadline, validateCurrent: validateCurrent)
        return try correlatedReadback(data, id: saved.integrationConfigID, minimumVersion: saved.configVersion)
    }
    func prepare(_ input: IMessageHumanActionRequest, saved: IMessageSavedReadback, configuration: DesktopEnvironmentConfiguration,
                 cookies: String, csrf: String, scope: IMessageHostedNativeScope, deadline: Date,
                 validateCurrent: ValidateCurrent) async throws -> IMessageHumanActionResponse {
        try validateInput(input, saved: saved)
        let body = try JSONEncoder().encode(input)
        let data = try await humanRequest(id: saved.integrationConfigID, suffix: input.action == .check ? "/check" : "/test-send", method: "POST", body: body,
            configuration: configuration, cookies: cookies, csrf: csrf, scope: scope, deadline: deadline, validateCurrent: validateCurrent)
        let result = try decode(IMessageHumanActionResponse.self, data)
        try validateHuman(result, input: input, saved: saved, scope: scope, prepared: true)
        return result
    }
    func redeem(_ command: IMessageGatewayCommand, input: IMessageHumanActionRequest, saved: IMessageSavedReadback,
                installation: DesktopControlInstallation, configuration: DesktopEnvironmentConfiguration, scope: IMessageHostedNativeScope,
                deadline: Date, validateCurrent: ValidateCurrent) async throws -> IMessageHumanActionResponse {
        try validateInput(input, saved: saved)
        try validateIssued(command, input: input, saved: saved, scope: scope)
        let budget = command.operation == .sendMessage ? 45.0 : 10.0
        let deadline = min(deadline, try IMessageGatewayWire.utcDate(command.deadlineAt), Date().addingTimeInterval(budget))
        try installation.requireEnvironment(configuration.appPageURL, configuration: configuration)
        guard installation.installationID == saved.config.installationID else { throw IMessageHostedSetupError.scopeChanged }
        try await current(validateCurrent, deadline: deadline)
        let body = try JSONEncoder().encode(IMessageGatewayNativeCommandRequest(command: command))
        var request = try request(configuration: configuration, path: "/v1/desktop-control/imessage/actions/redeem", method: "POST", body: body, deadline: deadline)
        request.setValue("Bearer " + (try IMessageMachineSetupClient.canonicalProof(installation.machineCredential)), forHTTPHeaderField: "Authorization")
        let data = try await perform(request, maximum: 256 * 1024, deadline: deadline, validateCurrent: validateCurrent)
        let result = try decode(IMessageHumanActionResponse.self, data)
        try validateHuman(result, input: input, saved: saved, scope: scope, prepared: false)
        return result
    }
    private func validateHuman(_ value: IMessageHumanActionResponse, input: IMessageHumanActionRequest, saved: IMessageSavedReadback,
                               scope: IMessageHostedNativeScope, prepared: Bool) throws {
        if let command = value.command {
            guard prepared else { throw IMessageHostedSetupError.invalidResponse }
            try validateIssued(command, input: input, saved: saved, scope: scope)
        } else if let status = value.status {
            guard !prepared, input.action == .check, status.integrationID == saved.integrationConfigID else { throw IMessageHostedSetupError.invalidResponse }
        } else if let send = value.sendMessage {
            guard input.action == .testSend, send.clientRequestID == input.clientRequestID, send.conversationID == input.conversationID else { throw IMessageHostedSetupError.invalidResponse }
        } else if let failure = value.failure {
            try IMessageGatewayWire.validate(DesktopControlFrame(type: "imessage", requestID: "human-result", imessage: .failure(failure)))
            guard failure.clientRequestID == input.clientRequestID, input.action != .check || failure.retrySafe else { throw IMessageHostedSetupError.invalidResponse }
        }
    }
    private func validateIssued(_ command: IMessageGatewayCommand, input: IMessageHumanActionRequest,
                                saved: IMessageSavedReadback, scope: IMessageHostedNativeScope) throws {
        try IMessageGatewayWire.validate(command)
        guard command.caller.kind == .humanAction, let human = command.caller.humanAction,
              human.userID == scope.naturalUserID, human.action == input.action, command.target.workspaceID == scope.workspaceID,
              command.target.configID == saved.integrationConfigID, command.target.configVersion == saved.configVersion,
              command.target.installationID == saved.config.installationID else { throw IMessageHostedSetupError.invalidResponse }
        if input.action == .check { guard command.operation == .status else { throw IMessageHostedSetupError.invalidResponse }; return }
        guard case .configured(.sendMessage(let send)) = command.input, send.integrationID == saved.integrationConfigID,
              send.conversationID == input.conversationID, send.clientRequestID == input.clientRequestID, send.text == input.text,
              human.conversationID == send.conversationID,
              human.textSHA256 == SHA256.hash(data: Data(send.text.utf8)).map({ String(format: "%02x", $0) }).joined() else { throw IMessageHostedSetupError.invalidResponse }
    }
    private func validateInput(_ input: IMessageHumanActionRequest, saved: IMessageSavedReadback) throws {
        guard input.expectedConfigVersion == saved.configVersion else { throw IMessageHostedSetupError.scopeChanged }
        if input.action == .check {
            guard input.conversationID == nil, input.clientRequestID == nil, input.text == nil else { throw IMessageHostedSetupError.invalidRequest }
            return
        }
        guard let id = input.conversationID, saved.config.conversations.contains(where: { $0.conversationID == id && $0.available }),
              let key = input.clientRequestID, IMessageSavedPageCommand.validToken(key), key.unicodeScalars.count <= 128,
              let text = input.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384 else {
            throw IMessageHostedSetupError.invalidRequest
        }
    }
    private func humanRequest(id: String, suffix: String, method: String, body: Data?, configuration: DesktopEnvironmentConfiguration,
                              cookies: String, csrf: String?, scope: IMessageHostedNativeScope, deadline: Date,
                              validateCurrent: ValidateCurrent) async throws -> Data {
        let deadline = min(deadline, Date().addingTimeInterval(suffix == "/test-send" ? 45 : 10))
        guard IMessageSavedPageCommand.validToken(id), !cookies.isEmpty, cookies.utf8.count <= 16384, !hostedHasControls(cookies) else { throw IMessageHostedSetupError.invalidRequest }
        let fullSettings = method == "PATCH" || suffix == "/resume" || suffix == "/resume-from-now"
        let humanCommand = ["/check", "/test-send"].contains(suffix)
        let bodyMaximum = fullSettings ? Self.maximumConfigUpdateBytes : (humanCommand ? 256 * 1024 : 16384)
        guard (body?.count ?? 0) <= bodyMaximum else { throw IMessageHostedSetupError.invalidRequest }
        _ = try await hosted.currentScope(configuration, cookies: cookies, expected: scope, deadline: deadline, validateScope: validateCurrent)
        let escaped = id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"))!
        var request = try request(configuration: configuration, path: "/user/imessage/configs/" + escaped + suffix, method: method, body: body, deadline: deadline)
        request.setValue(cookies, forHTTPHeaderField: "Cookie"); request.setValue(scope.workspaceID, forHTTPHeaderField: "X-PersonaStack-Workspace-ID")
        if method != "GET" {
            guard let csrf, !csrf.isEmpty, csrf.utf8.count <= 512, !csrf.contains(where: \.isWhitespace), !hostedHasControls(csrf) else { throw IMessageHostedSetupError.invalidRequest }
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        let maximum = ["/check", "/test-send"].contains(suffix) ? 256 * 1024 : Self.maximumReadbackBytes
        let data = try await perform(request, maximum: maximum, deadline: deadline, validateCurrent: validateCurrent)
        _ = try await hosted.currentScope(configuration, cookies: cookies, expected: scope, deadline: deadline, validateScope: validateCurrent)
        try await current(validateCurrent, deadline: deadline)
        return data
    }
    private func request(configuration: DesktopEnvironmentConfiguration, path: String, method: String, body: Data?, deadline: Date) throws -> URLRequest {
        let commandBody = path.hasSuffix("/check") || path.hasSuffix("/test-send") || path == "/v1/desktop-control/imessage/actions/redeem"
        let updateBody = method == "PATCH" || path.hasSuffix("/resume") || path.hasSuffix("/resume-from-now")
        let maximum = updateBody ? Self.maximumConfigUpdateBytes : (commandBody ? 256 * 1024 : 16384)
        guard (body?.count ?? 0) <= maximum, deadline > Date() else { throw IMessageHostedSetupError.invalidRequest }
        var parts = URLComponents(url: configuration.appURL, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = path; parts.query = nil; parts.fragment = nil
        var value = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.001, deadline.timeIntervalSinceNow))
        value.httpMethod = method; value.httpBody = body; value.httpShouldHandleCookies = false
        value.setValue("application/json", forHTTPHeaderField: "Accept"); value.setValue("macos-imessage-v1", forHTTPHeaderField: "X-PersonaStack-Native-Client")
        if body != nil { value.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return value
    }
    private func perform(_ request: URLRequest, maximum: Int, deadline: Date, validateCurrent: ValidateCurrent) async throws -> Data {
        try await current(validateCurrent, deadline: deadline)
        let result: (Data, Int)
        do { result = try await transport.request(request) } catch is CancellationError { throw CancellationError() }
        catch { throw IMessageHostedSetupError.serviceUnavailable }
        try await current(validateCurrent, deadline: deadline)
        guard result.0.count <= maximum else { throw IMessageHostedSetupError.invalidResponse }
        guard result.1 == 200 else {
            if result.1 == 401 { throw IMessageHostedSetupError.authenticationRequired }
            if [403, 404, 409, 410].contains(result.1) { throw IMessageHostedSetupError.scopeChanged }
            throw IMessageHostedSetupError.serviceUnavailable
        }
        return result.0
    }
    private func current(_ validate: ValidateCurrent, deadline: Date) async throws {
        try Task.checkCancellation(); guard deadline > Date() else { throw IMessageHostedSetupError.serviceUnavailable }
        try await validate(); try Task.checkCancellation()
        guard deadline > Date() else { throw IMessageHostedSetupError.serviceUnavailable }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try IMessageConfiguredGatewayValidation.decode(type, from: data, maximumBytes: 256 * 1024)
    }
    private func correlatedReadback(_ data: Data, id: String, minimumVersion: Int64) throws -> IMessageSavedReadback {
        let result = try IMessageConfiguredGatewayValidation.decode(IMessageSavedReadback.self, from: data, maximumBytes: Self.maximumReadbackBytes)
        guard result.integrationConfigID == id, result.configVersion >= minimumVersion else { throw IMessageHostedSetupError.scopeChanged }
        return result
    }
}
private struct SavedVersionRequest: Encodable {
    let expectedConfigVersion: String
    enum CodingKeys: String, CodingKey { case expectedConfigVersion = "expected_config_version" }
}
struct IMessageSavedConfigUpdateRequest: Encodable {
    let expectedConfigVersion: String
    let name: String
    let conversationIDs: [String]
    let readEnabled: Bool
    let sendEnabled: Bool
    let nativeApprovalReceipt: String
    let resumeConversationIDs: [String]?
    func encodedBody() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= IMessageSavedConfigClient.maximumConfigUpdateBytes else { throw IMessageHostedSetupError.invalidRequest }
        return data
    }
    enum CodingKeys: String, CodingKey {
        case expectedConfigVersion = "expected_config_version", name, conversationIDs = "conversation_ids"
        case readEnabled = "read_enabled", sendEnabled = "send_enabled", nativeApprovalReceipt = "native_approval_receipt"
        case resumeConversationIDs = "resume_conversation_ids"
    }
}


private struct IMessageSavedURLTransport: AgentBridgeHostedTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = DesktopControlNetworkSession.makeWithoutRedirects(configuration: configuration)
    }
    func request(_ request: URLRequest) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw IMessageHostedSetupError.invalidResponse
        }
        let path = request.url?.path ?? ""
        let humanCommand = path.hasSuffix("/check") || path.hasSuffix("/test-send") || path == "/v1/desktop-control/imessage/actions/redeem"
        let maximum = humanCommand ? 256 * 1024 : IMessageSavedConfigClient.maximumReadbackBytes
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw IMessageHostedSetupError.invalidResponse }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}
